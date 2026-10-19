// ABI plumbing: versioning, thread-local errors, defaults for params structs, cancellation tokens.
#include "se_internal.h"

#include "ggml.h"

#include <cstdio>

namespace se {

namespace {
// Per-thread error state is the only mutable state outside handles besides the backend-init once flag.
thread_local se_status   t_last_code = SE_OK;
thread_local std::string t_last_msg;
}  // namespace

void set_last_error(se_status code, const std::string & msg) {
  t_last_code = code;
  t_last_msg  = msg;
}

void clear_last_error() {
  t_last_code = SE_OK;
  t_last_msg.clear();
}

[[noreturn]] void fail(se_status code, const std::string & msg) {
  throw Error(code, msg);
}

int32_t copy_out(const std::string & s, char * buf, int32_t cap) {
  if (s.size() > (size_t) INT32_MAX - 1) {
    fail(SE_ERR_BUFFER_TOO_SMALL, "result too large");
  }
  const int32_t n = (int32_t) s.size();
  if (buf != nullptr && cap > n) {
    std::memcpy(buf, s.data(), s.size());
    buf[n] = '\0';
  }
  return n;
}

}  // namespace se

extern "C" {

SE_API const char * se_last_error(void) {
  return se::t_last_msg.c_str();
}

SE_API se_status se_last_error_code(void) {
  return se::t_last_code;
}

SE_API const char * se_status_name(se_status status) {
  switch (status) {
    case SE_OK:                   return "SE_OK";
    case SE_ERR_INVALID_ARG:      return "SE_ERR_INVALID_ARG";
    case SE_ERR_OOM:              return "SE_ERR_OOM";
    case SE_ERR_IO:               return "SE_ERR_IO";
    case SE_ERR_MODEL_LOAD:       return "SE_ERR_MODEL_LOAD";
    case SE_ERR_CONTEXT_CREATE:   return "SE_ERR_CONTEXT_CREATE";
    case SE_ERR_CONTEXT_FULL:     return "SE_ERR_CONTEXT_FULL";
    case SE_ERR_CANCELLED:        return "SE_ERR_CANCELLED";
    case SE_ERR_DECODE:           return "SE_ERR_DECODE";
    case SE_ERR_TEMPLATE:         return "SE_ERR_TEMPLATE";
    case SE_ERR_GRAMMAR:          return "SE_ERR_GRAMMAR";
    case SE_ERR_PARSE:            return "SE_ERR_PARSE";
    case SE_ERR_STATE_MISMATCH:   return "SE_ERR_STATE_MISMATCH";
    case SE_ERR_BUSY:             return "SE_ERR_BUSY";
    case SE_ERR_UNSUPPORTED:      return "SE_ERR_UNSUPPORTED";
    case SE_ERR_BUFFER_TOO_SMALL: return "SE_ERR_BUFFER_TOO_SMALL";
    case SE_ERR_TIMEOUT:          return "SE_ERR_TIMEOUT";
    case SE_ERR_ABI:              return "SE_ERR_ABI";
    case SE_ERR_INTERNAL:         return "SE_ERR_INTERNAL";
    default:                      return "SE_ERR_UNKNOWN";
  }
}

SE_API uint32_t se_abi_version(void) {
  return SE_ABI_VERSION;
}

SE_API uint32_t se_abi_minor(void) {
  return SE_ABI_MINOR;
}

SE_API const char * se_version_string(void) {
  // Built once; a function-local static is initialised thread-safely and never mutated afterwards.
  static const std::string s = std::string("sherpa_engine ") + SE_ENGINE_VERSION + " (abi " +
                               std::to_string(SE_ABI_VERSION) + "." + std::to_string(SE_ABI_MINOR) + ", llama.cpp " +
                               std::string(SE_LLAMA_COMMIT).substr(0, 7) + " " + SE_LLAMA_VERSION +
                               ", ggml " + ggml_version() + ")";
  return s.c_str();
}

SE_API void se_init_params_init(se_init_params * p) {
  if (!p) return;
  std::memset(p, 0, sizeof(*p));
  p->struct_size = sizeof(*p);
  p->log_level   = SE_LOG_WARN;
}

SE_API void se_model_params_init(se_model_params * p) {
  if (!p) return;
  std::memset(p, 0, sizeof(*p));
  p->struct_size        = sizeof(*p);
  p->n_gpu_layers       = -1;
  p->load_mode          = SE_LOAD_MODE_AUTO;
  p->use_extra_bufts    = 1;
  p->mmproj_use_gpu     = 1;
  p->draft_n_gpu_layers = -1;
}

SE_API void se_session_params_init(se_session_params * p) {
  if (!p) return;
  std::memset(p, 0, sizeof(*p));
  p->struct_size     = sizeof(*p);
  p->type_k          = SE_KV_DEFAULT;
  p->type_v          = SE_KV_DEFAULT;
  p->flash_attn      = -1;
  p->swa_full        = -1;
  p->seed            = SE_SEED_RANDOM;
  p->spec_type       = SE_SPEC_NONE;
  p->spec_min_accept = 0.0f;  // 0 = engine default (0.30)
}

SE_API void se_generate_params_init(se_generate_params * p) {
  if (!p) return;
  std::memset(p, 0, sizeof(*p));
  p->struct_size = sizeof(*p);
}

SE_API void se_bench_params_init(se_bench_params * p) {
  if (!p) return;
  std::memset(p, 0, sizeof(*p));
  p->struct_size = sizeof(*p);
  p->type_k      = SE_KV_DEFAULT;
  p->type_v      = SE_KV_DEFAULT;
  p->flash_attn  = -1;
}

SE_API se_canceller * se_canceller_create(void) {
  try {
    return new se_canceller();
  } catch (...) {
    se::set_last_error(SE_ERR_OOM, "se_canceller_create: out of memory");
    return nullptr;
  }
}

SE_API void se_canceller_cancel(se_canceller * c) {
  if (c) c->flag.store(true, std::memory_order_release);
}

SE_API void se_canceller_reset(se_canceller * c) {
  if (c) c->flag.store(false, std::memory_order_release);
}

SE_API void se_canceller_free(se_canceller * c) {
  delete c;
}

}  // extern "C"
