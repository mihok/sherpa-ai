/*
 * sherpa_jni.c - JNI shim between the :inference service (Kotlin) and the sherpa_engine C ABI.
 *
 * The engine is NOT linked: NativeEngine.open() dlopens libsherpa_engine.so (bare name inside the APK, or an
 * absolute path on a host JVM) and dlsyms the 39 ABI-1.0 se_* entry points, then checks se_abi_version() (the
 * major version; the 1.1 additions are not needed here: images travel as data URLs in the request JSON). So the
 * shim, and therefore `flutter build apk`, builds without the engine binaries; at runtime a missing or
 * incompatible engine is reported as "engine unavailable" instead of an UnsatisfiedLinkError.
 *
 * Plain C (no C++ STL), so the APK gets no second libc++_shared.so from this module.
 *
 * Conventions (mirroring lib/src/ffi/bindings.dart, read its header for the why):
 *  - Input params structs: the engine's *_init() fills an oversized scratch buffer (the engine may be newer
 *    and larger than the header we compiled against), and we declare struct_size = min(engine, ours).
 *  - Output structs: struct_size = sizeof(ours).
 *  - Events: the stride is each event's struct_size (the engine's sizeof), and only fields inside it are read.
 *  - Strings cross JNI as UTF-8 byte arrays, never jstring: modified UTF-8 cannot carry 4-byte sequences
 *    (emoji in generated text, JSON, error messages), and CheckJNI aborts on them.
 *  - Errors throw io.github.mihok.sherpa_inference.engine.EngineError(int code, byte[] utf8Message), with the
 *    message from se_last_error() read on the same thread right after the failing call.
 *  - Nothing here blocks except what the engine documents as blocking; the Kotlin side picks the thread.
 */
#include <jni.h>

#include <dlfcn.h>
#include <pthread.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "sherpa_engine.h"

#define SE_JNI_CLASS "io/github/mihok/sherpa_inference/engine/NativeEngine"
#define SE_JNI_ERROR "io/github/mihok/sherpa_inference/engine/EngineError"
#define SE_JNI_PROGRESS "io/github/mihok/sherpa_inference/engine/ProgressSink"

/* Upper bound the engine accepts for struct_size (se_internal.h). */
#define SE_MAX_STRUCT 65536

/* ---------------------------------------------------------------------------------------------------- */
/* Runtime-resolved API                                                                                   */

#define SE_FN(name) __typeof__(name) *name

typedef struct se_api {
  SE_FN(se_last_error);
  SE_FN(se_last_error_code);
  SE_FN(se_status_name);
  SE_FN(se_abi_version);
  SE_FN(se_version_string);
  SE_FN(se_init_params_init);
  SE_FN(se_backend_init);
  SE_FN(se_system_info_json);
  SE_FN(se_canceller_create);
  SE_FN(se_canceller_cancel);
  SE_FN(se_canceller_reset);
  SE_FN(se_canceller_free);
  SE_FN(se_model_params_init);
  SE_FN(se_model_load);
  SE_FN(se_model_free);
  SE_FN(se_model_info_json);
  SE_FN(se_tokenize);
  SE_FN(se_detokenize);
  SE_FN(se_count_chat_tokens);
  SE_FN(se_session_params_init);
  SE_FN(se_session_create);
  SE_FN(se_session_free);
  SE_FN(se_session_reset);
  SE_FN(se_session_set_threads);
  SE_FN(se_session_info_json);
  SE_FN(se_generate_start);
  SE_FN(se_poll_events);
  SE_FN(se_set_event_callback);
  SE_FN(se_cancel);
  SE_FN(se_wait);
  SE_FN(se_state_save);
  SE_FN(se_state_load);
  SE_FN(se_lora_load);
  SE_FN(se_lora_free);
  SE_FN(se_session_set_loras);
  SE_FN(se_estimate_memory);
  SE_FN(se_session_memory);
  SE_FN(se_bench_params_init);
  SE_FN(se_bench);
} se_api;

static se_api g_api;
static void *g_lib;
static int g_ready; /* 1 once every symbol resolved and the ABI matched (atomic, release/acquire) */
static pthread_mutex_t g_open_mu = PTHREAD_MUTEX_INITIALIZER;

static JavaVM *g_vm;
static jclass g_error_cls;
static jmethodID g_error_ctor;
static jmethodID g_progress_mid;

/* ---------------------------------------------------------------------------------------------------- */
/* Helpers                                                                                               */

static jbyteArray new_bytes(JNIEnv *env, const char *p, size_t n) {
  jbyteArray a = (*env)->NewByteArray(env, (jsize)n);
  if (a != NULL && n > 0) (*env)->SetByteArrayRegion(env, a, 0, (jsize)n, (const jbyte *)p);
  return a;
}

static void throw_engine(JNIEnv *env, int32_t code, const char *msg) {
  if ((*env)->ExceptionCheck(env)) return;
  if (msg == NULL) msg = "";
  jbyteArray m = new_bytes(env, msg, strlen(msg));
  if (m == NULL) return; /* OutOfMemoryError pending */
  jobject e = (*env)->NewObject(env, g_error_cls, g_error_ctor, (jint)code, m);
  if (e != NULL) (*env)->Throw(env, (jthrowable)e);
}

/* Throws for a failed se_* call; reads se_last_error() on this thread. */
static void throw_last(JNIEnv *env, int32_t status) { throw_engine(env, status, g_api.se_last_error()); }

static int is_ready(void) { return __atomic_load_n(&g_ready, __ATOMIC_ACQUIRE); }

static int ready_or_throw(JNIEnv *env) {
  if (is_ready()) return 1;
  throw_engine(env, SE_ERR_UNSUPPORTED, "the engine library is not loaded");
  return 0;
}

static int handle_or_throw(JNIEnv *env, jlong h, const char *what) {
  if (h != 0) return 1;
  char msg[96];
  snprintf(msg, sizeof msg, "null %s handle", what);
  throw_engine(env, SE_ERR_INVALID_ARG, msg);
  return 0;
}

/* NUL-terminated malloc copy of a byte array (NULL array -> NULL, *ok stays 1). */
static char *dup_bytes(JNIEnv *env, jbyteArray a, int32_t *len_out, int *ok) {
  if (len_out != NULL) *len_out = 0;
  if (a == NULL) return NULL;
  jsize n = (*env)->GetArrayLength(env, a);
  char *s = (char *)malloc((size_t)n + 1);
  if (s == NULL) {
    *ok = 0;
    throw_engine(env, SE_ERR_OOM, "out of memory copying a string");
    return NULL;
  }
  if (n > 0) (*env)->GetByteArrayRegion(env, a, 0, n, (jbyte *)s);
  s[n] = 0;
  if (len_out != NULL) *len_out = (int32_t)n;
  return s;
}

/* Fills `out` (our sizeof) with the engine's defaults via its *_init into scratch; struct_size = min. */
#define INIT_PARAMS(type, init_fn, out)                                                         \
  do {                                                                                          \
    uint8_t *scratch_ = (uint8_t *)calloc(1, SE_MAX_STRUCT);                                    \
    memset((out), 0, sizeof(type));                                                             \
    if (scratch_ == NULL) {                                                                     \
      (out)->struct_size = (uint32_t)sizeof(type);                                              \
      break;                                                                                    \
    }                                                                                           \
    g_api.init_fn((type *)(void *)scratch_);                                                    \
    uint32_t engine_ = *(uint32_t *)(void *)scratch_;                                           \
    uint32_t declared_ = engine_ < (uint32_t)sizeof(type) ? engine_ : (uint32_t)sizeof(type);   \
    memcpy((out), scratch_, declared_);                                                         \
    (out)->struct_size = declared_;                                                             \
    free(scratch_);                                                                             \
  } while (0)

/* *_json(…, buf, cap) with the size-then-fill protocol. kind: 0 system, 1 model, 2 session. */
static jbyteArray read_json(JNIEnv *env, int kind, void *h) {
  int32_t cap = 8192;
  for (int attempt = 0; attempt < 4; attempt++) {
    char *buf = (char *)malloc((size_t)cap);
    if (buf == NULL) {
      throw_engine(env, SE_ERR_OOM, "out of memory reading JSON");
      return NULL;
    }
    int32_t n;
    switch (kind) {
      case 0: n = g_api.se_system_info_json(buf, cap); break;
      case 1: n = g_api.se_model_info_json((const se_model *)h, buf, cap); break;
      default: n = g_api.se_session_info_json((se_session *)h, buf, cap); break;
    }
    if (n < 0) {
      free(buf);
      throw_last(env, n);
      return NULL;
    }
    if (n < cap) {
      jbyteArray r = new_bytes(env, buf, (size_t)n);
      free(buf);
      return r;
    }
    free(buf);
    cap = n + 1;
  }
  throw_engine(env, SE_ERR_BUFFER_TOO_SMALL, "JSON kept growing between calls");
  return NULL;
}

/* ---------------------------------------------------------------------------------------------------- */
/* Library                                                                                               */

#define RESOLVE(name)                                                       \
  do {                                                                      \
    *(void **)(&api.name) = dlsym(lib, #name);                              \
    if (api.name == NULL) {                                                 \
      missing = #name;                                                      \
      goto fail;                                                            \
    }                                                                       \
  } while (0)

/* Returns NULL on success, else a UTF-8 reason. Idempotent. */
static jbyteArray jni_open(JNIEnv *env, jclass cls, jbyteArray path) {
  (void)cls;
  char reason[512];
  pthread_mutex_lock(&g_open_mu);
  if (is_ready()) {
    pthread_mutex_unlock(&g_open_mu);
    return NULL;
  }
  int ok = 1;
  char *p = dup_bytes(env, path, NULL, &ok);
  if (!ok) {
    pthread_mutex_unlock(&g_open_mu);
    return NULL;
  }
  const char *missing = NULL;
  se_api api;
  memset(&api, 0, sizeof api);
  void *lib = dlopen(p != NULL ? p : "libsherpa_engine.so", RTLD_NOW | RTLD_LOCAL);
  if (lib == NULL) {
    const char *e = dlerror();
    snprintf(reason, sizeof reason, "dlopen(%s) failed: %s", p != NULL ? p : "libsherpa_engine.so",
             e != NULL ? e : "unknown error");
    free(p);
    pthread_mutex_unlock(&g_open_mu);
    return new_bytes(env, reason, strlen(reason));
  }
  RESOLVE(se_last_error);
  RESOLVE(se_last_error_code);
  RESOLVE(se_status_name);
  RESOLVE(se_abi_version);
  RESOLVE(se_version_string);
  RESOLVE(se_init_params_init);
  RESOLVE(se_backend_init);
  RESOLVE(se_system_info_json);
  RESOLVE(se_canceller_create);
  RESOLVE(se_canceller_cancel);
  RESOLVE(se_canceller_reset);
  RESOLVE(se_canceller_free);
  RESOLVE(se_model_params_init);
  RESOLVE(se_model_load);
  RESOLVE(se_model_free);
  RESOLVE(se_model_info_json);
  RESOLVE(se_tokenize);
  RESOLVE(se_detokenize);
  RESOLVE(se_count_chat_tokens);
  RESOLVE(se_session_params_init);
  RESOLVE(se_session_create);
  RESOLVE(se_session_free);
  RESOLVE(se_session_reset);
  RESOLVE(se_session_set_threads);
  RESOLVE(se_session_info_json);
  RESOLVE(se_generate_start);
  RESOLVE(se_poll_events);
  RESOLVE(se_set_event_callback);
  RESOLVE(se_cancel);
  RESOLVE(se_wait);
  RESOLVE(se_state_save);
  RESOLVE(se_state_load);
  RESOLVE(se_lora_load);
  RESOLVE(se_lora_free);
  RESOLVE(se_session_set_loras);
  RESOLVE(se_estimate_memory);
  RESOLVE(se_session_memory);
  RESOLVE(se_bench_params_init);
  RESOLVE(se_bench);
  {
    uint32_t abi = api.se_abi_version();
    if (abi != SE_ABI_VERSION) {
      snprintf(reason, sizeof reason, "engine ABI %u is not supported (this app speaks ABI %u); update the app or engine",
               (unsigned)abi, (unsigned)SE_ABI_VERSION);
      dlclose(lib);
      free(p);
      pthread_mutex_unlock(&g_open_mu);
      return new_bytes(env, reason, strlen(reason));
    }
  }
  g_api = api;
  g_lib = lib;
  __atomic_store_n(&g_ready, 1, __ATOMIC_RELEASE);
  free(p);
  pthread_mutex_unlock(&g_open_mu);
  return NULL;
fail:
  snprintf(reason, sizeof reason, "the engine library is missing %s", missing);
  dlclose(lib);
  free(p);
  pthread_mutex_unlock(&g_open_mu);
  return new_bytes(env, reason, strlen(reason));
}

static jint jni_abi_version(JNIEnv *env, jclass cls) {
  (void)cls;
  if (!ready_or_throw(env)) return 0;
  return (jint)g_api.se_abi_version();
}

static jbyteArray jni_version_string(JNIEnv *env, jclass cls) {
  (void)cls;
  if (!ready_or_throw(env)) return NULL;
  const char *v = g_api.se_version_string();
  return new_bytes(env, v, strlen(v));
}

static void jni_backend_init(JNIEnv *env, jclass cls, jbyteArray breadcrumb, jbyteArray backend_dir, jint log_level) {
  (void)cls;
  if (!ready_or_throw(env)) return;
  int ok = 1;
  char *bc = dup_bytes(env, breadcrumb, NULL, &ok);
  char *bd = ok ? dup_bytes(env, backend_dir, NULL, &ok) : NULL;
  if (ok) {
    se_init_params p;
    INIT_PARAMS(se_init_params, se_init_params_init, &p);
    /* log_cb stays NULL: errors go to logcat "sherpa_engine" (Android) / stderr. */
    if (log_level > 0) p.log_level = log_level;
    p.crash_breadcrumb_path = bc;
    p.backend_dir = bd;
    se_status rc = g_api.se_backend_init(&p);
    if (rc < 0) throw_last(env, rc);
  }
  free(bc);
  free(bd);
}

static jbyteArray jni_system_info_json(JNIEnv *env, jclass cls) {
  (void)cls;
  if (!ready_or_throw(env)) return NULL;
  return read_json(env, 0, NULL);
}

/* ---------------------------------------------------------------------------------------------------- */
/* Cancellers                                                                                            */

static jlong jni_canceller_create(JNIEnv *env, jclass cls) {
  (void)cls;
  if (!ready_or_throw(env)) return 0;
  se_canceller *c = g_api.se_canceller_create();
  if (c == NULL) throw_engine(env, SE_ERR_OOM, "se_canceller_create failed");
  return (jlong)(intptr_t)c;
}

static void jni_canceller_cancel(JNIEnv *env, jclass cls, jlong c) {
  (void)cls;
  if (!ready_or_throw(env) || c == 0) return;
  g_api.se_canceller_cancel((se_canceller *)(intptr_t)c);
}

static void jni_canceller_free(JNIEnv *env, jclass cls, jlong c) {
  (void)cls;
  if (!ready_or_throw(env) || c == 0) return;
  g_api.se_canceller_free((se_canceller *)(intptr_t)c);
}

/* ---------------------------------------------------------------------------------------------------- */
/* Models                                                                                                */

/* ints: n_gpu_layers, load_mode, use_extra_bufts, vocab_only, load_mtp.
 * strs: chat_template_override, model_id, mmproj_path, draft_model_path (entries may be null). */
#define MODEL_INTS 5
#define MODEL_STRS 4

typedef struct model_args {
  se_model_params p;
  char *strs[MODEL_STRS];
} model_args;

static int model_args_read(JNIEnv *env, jintArray ints, jobjectArray strs, model_args *a) {
  memset(a, 0, sizeof *a);
  INIT_PARAMS(se_model_params, se_model_params_init, &a->p);
  if (ints == NULL || (*env)->GetArrayLength(env, ints) < MODEL_INTS ||
      (strs != NULL && (*env)->GetArrayLength(env, strs) < MODEL_STRS)) {
    throw_engine(env, SE_ERR_INVALID_ARG, "malformed model options");
    return 0;
  }
  jint v[MODEL_INTS];
  (*env)->GetIntArrayRegion(env, ints, 0, MODEL_INTS, v);
  a->p.n_gpu_layers = v[0];
  a->p.load_mode = v[1];
  a->p.use_extra_bufts = v[2];
  a->p.vocab_only = v[3];
  a->p.load_mtp = v[4];
  int ok = 1;
  for (int i = 0; strs != NULL && i < MODEL_STRS && ok; i++) {
    jbyteArray s = (jbyteArray)(*env)->GetObjectArrayElement(env, strs, i);
    a->strs[i] = dup_bytes(env, s, NULL, &ok);
    if (s != NULL) (*env)->DeleteLocalRef(env, s);
  }
  a->p.chat_template_override = a->strs[0];
  a->p.model_id = a->strs[1];
  a->p.mmproj_path = a->strs[2];
  a->p.draft_model_path = a->strs[3];
  return ok;
}

static void model_args_free(model_args *a) {
  for (int i = 0; i < MODEL_STRS; i++) free(a->strs[i]);
}

typedef struct progress_ctx {
  jobject sink;
} progress_ctx;

/* Called on the loading thread (llama.cpp reports from the thread that called se_model_load). */
static int32_t progress_cb(float progress, void *user) {
  progress_ctx *c = (progress_ctx *)user;
  JNIEnv *env = NULL;
  if (g_vm == NULL || (*g_vm)->GetEnv(g_vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK || env == NULL) return 1;
  jboolean keep = (*env)->CallBooleanMethod(env, c->sink, g_progress_mid, (jfloat)progress);
  if ((*env)->ExceptionCheck(env)) {
    (*env)->ExceptionClear(env);
    return 1;
  }
  return keep ? 1 : 0;
}

static jlong jni_model_load(JNIEnv *env, jclass cls, jbyteArray path, jintArray ints, jobjectArray strs, jlong canceller,
                            jobject progress) {
  (void)cls;
  if (!ready_or_throw(env)) return 0;
  model_args a;
  int ok = model_args_read(env, ints, strs, &a);
  char *p = ok ? dup_bytes(env, path, NULL, &ok) : NULL;
  se_model *m = NULL;
  if (ok && p == NULL) {
    ok = 0;
    throw_engine(env, SE_ERR_INVALID_ARG, "model path is required");
  }
  if (ok) {
    progress_ctx ctx = {progress};
    if (progress != NULL) {
      a.p.progress_cb = progress_cb;
      a.p.progress_user = &ctx;
    }
    a.p.cancel = (se_canceller *)(intptr_t)canceller;
    se_status rc = g_api.se_model_load(p, &a.p, &m);
    if (rc < 0) {
      m = NULL;
      throw_last(env, rc);
    }
  }
  free(p);
  model_args_free(&a);
  return (jlong)(intptr_t)m;
}

static void jni_model_free(JNIEnv *env, jclass cls, jlong m) {
  (void)cls;
  if (!ready_or_throw(env) || m == 0) return;
  g_api.se_model_free((se_model *)(intptr_t)m);
}

static jbyteArray jni_model_info_json(JNIEnv *env, jclass cls, jlong m) {
  (void)cls;
  if (!ready_or_throw(env) || !handle_or_throw(env, m, "model")) return NULL;
  return read_json(env, 1, (void *)(intptr_t)m);
}

static jintArray jni_tokenize(JNIEnv *env, jclass cls, jlong m, jbyteArray text, jboolean add_special,
                              jboolean parse_special) {
  (void)cls;
  if (!ready_or_throw(env) || !handle_or_throw(env, m, "model")) return NULL;
  int ok = 1;
  int32_t len = 0;
  char *t = dup_bytes(env, text, &len, &ok);
  if (!ok) return NULL;
  const se_model *model = (const se_model *)(intptr_t)m;
  const char *src = t != NULL ? t : "";
  int32_t n = g_api.se_tokenize(model, src, len, add_special ? 1 : 0, parse_special ? 1 : 0, NULL, 0);
  jintArray out = NULL;
  if (n < 0) {
    throw_last(env, n);
  } else {
    int32_t *toks = (int32_t *)malloc(sizeof(int32_t) * (size_t)(n > 0 ? n : 1));
    if (toks == NULL) {
      throw_engine(env, SE_ERR_OOM, "out of memory tokenizing");
    } else {
      int32_t n2 = g_api.se_tokenize(model, src, len, add_special ? 1 : 0, parse_special ? 1 : 0, toks, n);
      if (n2 < 0) {
        throw_last(env, n2);
      } else {
        int32_t count = n2 < n ? n2 : n;
        out = (*env)->NewIntArray(env, count);
        if (out != NULL && count > 0) (*env)->SetIntArrayRegion(env, out, 0, count, (const jint *)toks);
      }
      free(toks);
    }
  }
  free(t);
  return out;
}

/* Count or negative se_status (no throw): the batch counter reports per item. */
static jint jni_count_text(JNIEnv *env, jclass cls, jlong m, jbyteArray text) {
  (void)cls;
  if (!ready_or_throw(env) || !handle_or_throw(env, m, "model")) return SE_ERR_INVALID_ARG;
  int ok = 1;
  int32_t len = 0;
  char *t = dup_bytes(env, text, &len, &ok);
  if (!ok) return SE_ERR_OOM;
  int32_t n = g_api.se_tokenize((const se_model *)(intptr_t)m, t != NULL ? t : "", len, 0, 0, NULL, 0);
  free(t);
  return n;
}

static jbyteArray jni_detokenize(JNIEnv *env, jclass cls, jlong m, jintArray tokens, jboolean render_special) {
  (void)cls;
  if (!ready_or_throw(env) || !handle_or_throw(env, m, "model")) return NULL;
  jsize nt = tokens != NULL ? (*env)->GetArrayLength(env, tokens) : 0;
  int32_t *toks = (int32_t *)malloc(sizeof(int32_t) * (size_t)(nt > 0 ? nt : 1));
  if (toks == NULL) {
    throw_engine(env, SE_ERR_OOM, "out of memory detokenizing");
    return NULL;
  }
  if (nt > 0) (*env)->GetIntArrayRegion(env, tokens, 0, nt, (jint *)toks);
  const se_model *model = (const se_model *)(intptr_t)m;
  jbyteArray out = NULL;
  int32_t n = g_api.se_detokenize(model, toks, nt, render_special ? 1 : 0, NULL, 0);
  if (n < 0) {
    throw_last(env, n);
  } else {
    char *buf = (char *)malloc((size_t)n + 1);
    if (buf == NULL) {
      throw_engine(env, SE_ERR_OOM, "out of memory detokenizing");
    } else {
      int32_t n2 = g_api.se_detokenize(model, toks, nt, render_special ? 1 : 0, buf, n + 1);
      if (n2 < 0) {
        throw_last(env, n2);
      } else {
        out = new_bytes(env, buf, (size_t)(n2 < n ? n2 : n));
      }
      free(buf);
    }
  }
  free(toks);
  return out;
}

static jint jni_count_chat(JNIEnv *env, jclass cls, jlong m, jbyteArray json, jboolean throw_on_error) {
  (void)cls;
  if (!ready_or_throw(env) || !handle_or_throw(env, m, "model")) return SE_ERR_INVALID_ARG;
  int ok = 1;
  char *j = dup_bytes(env, json, NULL, &ok);
  if (!ok) return SE_ERR_OOM;
  int32_t n = g_api.se_count_chat_tokens((const se_model *)(intptr_t)m, j != NULL ? j : "");
  if (n < 0 && throw_on_error) throw_last(env, n);
  free(j);
  return n;
}

/* ---------------------------------------------------------------------------------------------------- */
/* Sessions                                                                                              */

/* n_ctx, n_batch, n_ubatch, n_threads, n_threads_batch, type_k, type_v, flash_attn, n_outputs_max, swa_full,
 * seed, spec_type, spec_n_max, event_capacity. */
#define SESSION_INTS 14

static int session_params_read(JNIEnv *env, jintArray ints, se_session_params *p) {
  INIT_PARAMS(se_session_params, se_session_params_init, p);
  if (ints == NULL || (*env)->GetArrayLength(env, ints) < SESSION_INTS) {
    throw_engine(env, SE_ERR_INVALID_ARG, "malformed session config");
    return 0;
  }
  jint v[SESSION_INTS];
  (*env)->GetIntArrayRegion(env, ints, 0, SESSION_INTS, v);
  p->n_ctx = (uint32_t)v[0];
  p->n_batch = (uint32_t)v[1];
  p->n_ubatch = (uint32_t)v[2];
  p->n_threads = v[3];
  p->n_threads_batch = v[4];
  p->type_k = v[5];
  p->type_v = v[6];
  p->flash_attn = v[7];
  p->n_outputs_max = (uint32_t)v[8];
  p->swa_full = v[9];
  p->seed = (uint32_t)v[10];
  p->spec_type = v[11];
  p->spec_n_max = v[12];
  p->event_capacity = (uint32_t)v[13];
  return 1;
}

static jlong jni_session_create(JNIEnv *env, jclass cls, jlong m, jintArray ints) {
  (void)cls;
  if (!ready_or_throw(env) || !handle_or_throw(env, m, "model")) return 0;
  se_session_params p;
  if (!session_params_read(env, ints, &p)) return 0;
  se_session *s = NULL;
  se_status rc = g_api.se_session_create((se_model *)(intptr_t)m, &p, &s);
  if (rc < 0) {
    throw_last(env, rc);
    return 0;
  }
  return (jlong)(intptr_t)s;
}

static void jni_session_free(JNIEnv *env, jclass cls, jlong s) {
  (void)cls;
  if (!ready_or_throw(env) || s == 0) return;
  g_api.se_session_free((se_session *)(intptr_t)s);
}

static void jni_session_reset(JNIEnv *env, jclass cls, jlong s) {
  (void)cls;
  if (!ready_or_throw(env) || !handle_or_throw(env, s, "session")) return;
  se_status rc = g_api.se_session_reset((se_session *)(intptr_t)s);
  if (rc < 0) throw_last(env, rc);
}

static void jni_session_set_threads(JNIEnv *env, jclass cls, jlong s, jint n, jint nb) {
  (void)cls;
  if (!ready_or_throw(env) || !handle_or_throw(env, s, "session")) return;
  se_status rc = g_api.se_session_set_threads((se_session *)(intptr_t)s, n, nb);
  if (rc < 0) throw_last(env, rc);
}

static jbyteArray jni_session_info_json(JNIEnv *env, jclass cls, jlong s) {
  (void)cls;
  if (!ready_or_throw(env) || !handle_or_throw(env, s, "session")) return NULL;
  return read_json(env, 2, (void *)(intptr_t)s);
}

static jlongArray estimate_array(JNIEnv *env, const se_memory_estimate *e) {
  jlong v[11] = {
      (jlong)e->n_ctx,         (jlong)e->n_ctx_seq,    (jlong)e->flash_attn,         (jlong)e->model_bytes,
      (jlong)e->model_mapped_bytes, (jlong)e->kv_bytes, (jlong)e->compute_bytes,     (jlong)e->output_bytes,
      (jlong)e->total_bytes,   (jlong)e->kv_bytes_per_token, (jlong)e->file_bytes,
  };
  jlongArray out = (*env)->NewLongArray(env, 11);
  if (out != NULL) (*env)->SetLongArrayRegion(env, out, 0, 11, v);
  return out;
}

static jlongArray jni_session_memory(JNIEnv *env, jclass cls, jlong s) {
  (void)cls;
  if (!ready_or_throw(env) || !handle_or_throw(env, s, "session")) return NULL;
  se_memory_estimate e;
  memset(&e, 0, sizeof e);
  e.struct_size = (uint32_t)sizeof e;
  se_status rc = g_api.se_session_memory((se_session *)(intptr_t)s, &e);
  if (rc < 0) {
    throw_last(env, rc);
    return NULL;
  }
  return estimate_array(env, &e);
}

static jlongArray jni_estimate_memory(JNIEnv *env, jclass cls, jbyteArray path, jintArray model_ints,
                                      jobjectArray model_strs, jintArray session_ints) {
  (void)cls;
  if (!ready_or_throw(env)) return NULL;
  model_args a;
  int ok = model_args_read(env, model_ints, model_strs, &a);
  se_session_params sp;
  if (ok) ok = session_params_read(env, session_ints, &sp);
  char *p = ok ? dup_bytes(env, path, NULL, &ok) : NULL;
  jlongArray out = NULL;
  if (ok && p == NULL) {
    ok = 0;
    throw_engine(env, SE_ERR_INVALID_ARG, "model path is required");
  }
  if (ok) {
    se_memory_estimate e;
    memset(&e, 0, sizeof e);
    e.struct_size = (uint32_t)sizeof e;
    se_status rc = g_api.se_estimate_memory(p, &a.p, &sp, &e);
    if (rc < 0) {
      throw_last(env, rc);
    } else {
      out = estimate_array(env, &e);
    }
  }
  free(p);
  model_args_free(&a);
  return out;
}

/* ---------------------------------------------------------------------------------------------------- */
/* Generation                                                                                            */

static jlong jni_generate_start(JNIEnv *env, jclass cls, jlong s, jbyteArray json) {
  (void)cls;
  if (!ready_or_throw(env) || !handle_or_throw(env, s, "session")) return -1;
  int ok = 1;
  char *j = dup_bytes(env, json, NULL, &ok);
  if (!ok) return -1;
  uint32_t id = 0;
  se_status rc = g_api.se_generate_start((se_session *)(intptr_t)s, j != NULL ? j : "", &id);
  free(j);
  if (rc < 0) {
    throw_last(env, rc);
    return -1;
  }
  return (jlong)id;
}

typedef struct packbuf {
  uint8_t *p;
  size_t n;
  size_t cap;
  int oom;
} packbuf;

static void pb_put(packbuf *b, const void *d, size_t n) {
  if (b->oom) return;
  if (b->n + n > b->cap) {
    size_t cap = b->cap == 0 ? 1024 : b->cap;
    while (cap < b->n + n) cap *= 2;
    uint8_t *np = (uint8_t *)realloc(b->p, cap);
    if (np == NULL) {
      b->oom = 1;
      return;
    }
    b->p = np;
    b->cap = cap;
  }
  memcpy(b->p + b->n, d, n);
  b->n += n;
}

static void pb_i32(packbuf *b, int32_t v) { pb_put(b, &v, sizeof v); }
static void pb_f64(packbuf *b, double v) { pb_put(b, &v, sizeof v); }

static void pb_str(packbuf *b, const char *s, size_t n) {
  if (s == NULL) n = 0;
  pb_i32(b, (int32_t)n);
  if (n > 0) pb_put(b, s, n);
}

/* True when `field` lies inside the engine's se_event (its struct_size). */
#define EV_HAS(ev, field) (offsetof(se_event, field) + sizeof(((se_event *)0)->field) <= (ev)->struct_size)
#define EV_I32(ev, field) (EV_HAS(ev, field) ? (int32_t)(ev)->field : 0)
#define EV_F64(ev, field) (EV_HAS(ev, field) ? (ev)->field : 0.0)

/* Packs a batch for PackedEvents.decode (Kotlin), all little-endian (native on every Android ABI):
 *   i32 count, then per event: i32 type, generation_id, index, code, prompt_tokens, cached_tokens,
 *   completion_tokens, n_drafted, n_accepted, progress_done, progress_total; f64 ttft_ms, prefill_tps,
 *   decode_tps, draft_accept_rate, prefill_ms, decode_ms; then text, id, name as (i32 length, bytes).
 * Returns NULL when nothing was queued within the timeout. */
static jbyteArray jni_poll_events(JNIEnv *env, jclass cls, jlong s, jint timeout_ms, jint max_events) {
  (void)cls;
  if (!ready_or_throw(env) || !handle_or_throw(env, s, "session")) return NULL;
  const se_event *events = NULL;
  int32_t n = 0;
  se_status rc = g_api.se_poll_events((se_session *)(intptr_t)s, timeout_ms, max_events, &events, &n);
  if (rc < 0) {
    throw_last(env, rc);
    return NULL;
  }
  if (n <= 0 || events == NULL) return NULL;
  packbuf b = {NULL, 0, 0, 0};
  pb_i32(&b, n);
  const uint8_t *base = (const uint8_t *)events;
  uint32_t stride = events[0].struct_size;
  for (int32_t i = 0; i < n; i++) {
    const se_event *e = (const se_event *)(const void *)(base + (size_t)i * stride);
    pb_i32(&b, EV_I32(e, type));
    pb_i32(&b, (int32_t)(EV_HAS(e, generation_id) ? e->generation_id : 0));
    pb_i32(&b, EV_HAS(e, index) ? e->index : -1);
    pb_i32(&b, EV_I32(e, code));
    pb_i32(&b, EV_I32(e, prompt_tokens));
    pb_i32(&b, EV_I32(e, cached_tokens));
    pb_i32(&b, EV_I32(e, completion_tokens));
    pb_i32(&b, EV_I32(e, n_drafted));
    pb_i32(&b, EV_I32(e, n_accepted));
    pb_i32(&b, EV_I32(e, progress_done));
    pb_i32(&b, EV_I32(e, progress_total));
    pb_f64(&b, EV_F64(e, ttft_ms));
    pb_f64(&b, EV_F64(e, prefill_tps));
    pb_f64(&b, EV_F64(e, decode_tps));
    pb_f64(&b, EV_F64(e, draft_accept_rate));
    pb_f64(&b, EV_F64(e, prefill_ms));
    pb_f64(&b, EV_F64(e, decode_ms));
    pb_str(&b, EV_HAS(e, text) ? e->text : NULL, EV_HAS(e, text_len) && EV_HAS(e, text) ? e->text_len : 0);
    const char *id = EV_HAS(e, id) ? e->id : NULL;
    pb_str(&b, id, id != NULL ? strlen(id) : 0);
    const char *name = EV_HAS(e, name) ? e->name : NULL;
    pb_str(&b, name, name != NULL ? strlen(name) : 0);
  }
  jbyteArray out = NULL;
  if (b.oom) {
    throw_engine(env, SE_ERR_OOM, "out of memory packing events");
  } else {
    out = new_bytes(env, (const char *)b.p, b.n);
  }
  free(b.p);
  return out;
}

static void jni_cancel(JNIEnv *env, jclass cls, jlong s) {
  (void)cls;
  if (!ready_or_throw(env) || s == 0) return;
  g_api.se_cancel((se_session *)(intptr_t)s);
}

static jint jni_wait_idle(JNIEnv *env, jclass cls, jlong s, jint timeout_ms) {
  (void)cls;
  if (!ready_or_throw(env) || !handle_or_throw(env, s, "session")) return SE_ERR_INVALID_ARG;
  return g_api.se_wait((se_session *)(intptr_t)s, timeout_ms);
}

/* ---------------------------------------------------------------------------------------------------- */
/* State, LoRA, bench                                                                                    */

static void jni_state_save(JNIEnv *env, jclass cls, jlong s, jbyteArray path) {
  (void)cls;
  if (!ready_or_throw(env) || !handle_or_throw(env, s, "session")) return;
  int ok = 1;
  char *p = dup_bytes(env, path, NULL, &ok);
  if (!ok) return;
  se_status rc = g_api.se_state_save((se_session *)(intptr_t)s, p != NULL ? p : "");
  if (rc < 0) throw_last(env, rc);
  free(p);
}

static jint jni_state_load(JNIEnv *env, jclass cls, jlong s, jbyteArray path) {
  (void)cls;
  if (!ready_or_throw(env) || !handle_or_throw(env, s, "session")) return 0;
  int ok = 1;
  char *p = dup_bytes(env, path, NULL, &ok);
  if (!ok) return 0;
  int32_t n = 0;
  se_status rc = g_api.se_state_load((se_session *)(intptr_t)s, p != NULL ? p : "", &n);
  if (rc < 0) throw_last(env, rc);
  free(p);
  return n;
}

static jlong jni_lora_load(JNIEnv *env, jclass cls, jlong m, jbyteArray path) {
  (void)cls;
  if (!ready_or_throw(env) || !handle_or_throw(env, m, "model")) return 0;
  int ok = 1;
  char *p = dup_bytes(env, path, NULL, &ok);
  if (!ok) return 0;
  se_lora *l = NULL;
  se_status rc = g_api.se_lora_load((se_model *)(intptr_t)m, p != NULL ? p : "", &l);
  free(p);
  if (rc < 0) {
    throw_last(env, rc);
    return 0;
  }
  return (jlong)(intptr_t)l;
}

static void jni_lora_free(JNIEnv *env, jclass cls, jlong l) {
  (void)cls;
  if (!ready_or_throw(env) || l == 0) return;
  g_api.se_lora_free((se_lora *)(intptr_t)l);
}

static void jni_set_loras(JNIEnv *env, jclass cls, jlong s, jlongArray loras, jfloatArray scales) {
  (void)cls;
  if (!ready_or_throw(env) || !handle_or_throw(env, s, "session")) return;
  jsize n = loras != NULL ? (*env)->GetArrayLength(env, loras) : 0;
  if (scales == NULL ? n != 0 : (*env)->GetArrayLength(env, scales) != n) {
    throw_engine(env, SE_ERR_INVALID_ARG, "loras and scales differ in length");
    return;
  }
  se_lora **lp = (se_lora **)malloc(sizeof(se_lora *) * (size_t)(n > 0 ? n : 1));
  float *sc = (float *)malloc(sizeof(float) * (size_t)(n > 0 ? n : 1));
  jlong *ids = (jlong *)malloc(sizeof(jlong) * (size_t)(n > 0 ? n : 1));
  if (lp == NULL || sc == NULL || ids == NULL) {
    throw_engine(env, SE_ERR_OOM, "out of memory setting adapters");
  } else {
    if (n > 0) {
      (*env)->GetLongArrayRegion(env, loras, 0, n, ids);
      (*env)->GetFloatArrayRegion(env, scales, 0, n, sc);
    }
    for (jsize i = 0; i < n; i++) lp[i] = (se_lora *)(intptr_t)ids[i];
    se_status rc = g_api.se_session_set_loras((se_session *)(intptr_t)s, lp, sc, n);
    if (rc < 0) throw_last(env, rc);
  }
  free(lp);
  free(sc);
  free(ids);
}

/* ints: n_threads, n_threads_batch, n_batch, n_ubatch, n_ctx, n_prompt, n_gen, n_reps, type_k, type_v,
 * flash_attn. Result: n_prompt, n_gen, n_threads, pp_tps, tg_tps, pp_ms, tg_ms. */
#define BENCH_INTS 11

static jdoubleArray jni_bench(JNIEnv *env, jclass cls, jlong m, jintArray ints, jlong canceller) {
  (void)cls;
  if (!ready_or_throw(env) || !handle_or_throw(env, m, "model")) return NULL;
  if (ints == NULL || (*env)->GetArrayLength(env, ints) < BENCH_INTS) {
    throw_engine(env, SE_ERR_INVALID_ARG, "malformed bench config");
    return NULL;
  }
  jint v[BENCH_INTS];
  (*env)->GetIntArrayRegion(env, ints, 0, BENCH_INTS, v);
  se_bench_params p;
  INIT_PARAMS(se_bench_params, se_bench_params_init, &p);
  p.n_threads = v[0];
  p.n_threads_batch = v[1];
  p.n_batch = (uint32_t)v[2];
  p.n_ubatch = (uint32_t)v[3];
  p.n_ctx = (uint32_t)v[4];
  p.n_prompt = v[5];
  p.n_gen = v[6];
  p.n_reps = v[7];
  p.type_k = v[8];
  p.type_v = v[9];
  p.flash_attn = v[10];
  p.cancel = (se_canceller *)(intptr_t)canceller;
  se_bench_result r;
  memset(&r, 0, sizeof r);
  r.struct_size = (uint32_t)sizeof r;
  se_status rc = g_api.se_bench((se_model *)(intptr_t)m, &p, &r);
  if (rc < 0) {
    throw_last(env, rc);
    return NULL;
  }
  jdouble out[7] = {r.n_prompt, r.n_gen, r.n_threads, r.pp_tps, r.tg_tps, r.pp_ms, r.tg_ms};
  jdoubleArray a = (*env)->NewDoubleArray(env, 7);
  if (a != NULL) (*env)->SetDoubleArrayRegion(env, a, 0, 7, out);
  return a;
}

/* Debuggable builds only (checked in Kotlin): 0 abort (SIGABRT, like GGML_ABORT), 1 SIGSEGV, 2 _exit(3). */
static void jni_debug_crash(JNIEnv *env, jclass cls, jint mode) {
  (void)env;
  (void)cls;
  switch (mode) {
    case 0: abort();
    case 1: raise(SIGSEGV); break;
    default: _exit(3);
  }
}

/* ---------------------------------------------------------------------------------------------------- */
/* Registration                                                                                          */

#define PROGRESS_SIG "Lio/github/mihok/sherpa_inference/engine/ProgressSink;"

static const JNINativeMethod k_methods[] = {
    {"open", "([B)[B", (void *)jni_open},
    {"abiVersion", "()I", (void *)jni_abi_version},
    {"versionString", "()[B", (void *)jni_version_string},
    {"backendInit", "([B[BI)V", (void *)jni_backend_init},
    {"systemInfoJson", "()[B", (void *)jni_system_info_json},
    {"cancellerCreate", "()J", (void *)jni_canceller_create},
    {"cancellerCancel", "(J)V", (void *)jni_canceller_cancel},
    {"cancellerFree", "(J)V", (void *)jni_canceller_free},
    {"modelLoad", "([B[I[[BJ" PROGRESS_SIG ")J", (void *)jni_model_load},
    {"modelFree", "(J)V", (void *)jni_model_free},
    {"modelInfoJson", "(J)[B", (void *)jni_model_info_json},
    {"tokenize", "(J[BZZ)[I", (void *)jni_tokenize},
    {"countText", "(J[B)I", (void *)jni_count_text},
    {"detokenize", "(J[IZ)[B", (void *)jni_detokenize},
    {"countChat", "(J[BZ)I", (void *)jni_count_chat},
    {"estimateMemory", "([B[I[[B[I)[J", (void *)jni_estimate_memory},
    {"sessionCreate", "(J[I)J", (void *)jni_session_create},
    {"sessionFree", "(J)V", (void *)jni_session_free},
    {"sessionReset", "(J)V", (void *)jni_session_reset},
    {"sessionSetThreads", "(JII)V", (void *)jni_session_set_threads},
    {"sessionInfoJson", "(J)[B", (void *)jni_session_info_json},
    {"sessionMemory", "(J)[J", (void *)jni_session_memory},
    {"generateStart", "(J[B)J", (void *)jni_generate_start},
    {"pollEvents", "(JII)[B", (void *)jni_poll_events},
    {"cancel", "(J)V", (void *)jni_cancel},
    {"waitIdle", "(JI)I", (void *)jni_wait_idle},
    {"stateSave", "(J[B)V", (void *)jni_state_save},
    {"stateLoad", "(J[B)I", (void *)jni_state_load},
    {"loraLoad", "(J[B)J", (void *)jni_lora_load},
    {"loraFree", "(J)V", (void *)jni_lora_free},
    {"setLoras", "(J[J[F)V", (void *)jni_set_loras},
    {"bench", "(J[IJ)[D", (void *)jni_bench},
    {"debugCrash", "(I)V", (void *)jni_debug_crash},
};

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
  (void)reserved;
  JNIEnv *env = NULL;
  if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK || env == NULL) return JNI_ERR;
  g_vm = vm;
  jclass err = (*env)->FindClass(env, SE_JNI_ERROR);
  if (err == NULL) return JNI_ERR;
  g_error_cls = (jclass)(*env)->NewGlobalRef(env, err);
  g_error_ctor = (*env)->GetMethodID(env, err, "<init>", "(I[B)V");
  (*env)->DeleteLocalRef(env, err);
  if (g_error_ctor == NULL) return JNI_ERR;
  jclass prog = (*env)->FindClass(env, SE_JNI_PROGRESS);
  if (prog == NULL) return JNI_ERR;
  g_progress_mid = (*env)->GetMethodID(env, prog, "onProgress", "(F)Z");
  (*env)->DeleteLocalRef(env, prog);
  if (g_progress_mid == NULL) return JNI_ERR;
  jclass cls = (*env)->FindClass(env, SE_JNI_CLASS);
  if (cls == NULL) return JNI_ERR;
  jint rc = (*env)->RegisterNatives(env, cls, k_methods, (jint)(sizeof k_methods / sizeof k_methods[0]));
  (*env)->DeleteLocalRef(env, cls);
  return rc == JNI_OK ? JNI_VERSION_1_6 : JNI_ERR;
}
