/* Compiles sherpa_engine.h as C11 (what Dart ffigen, JNI and Swift's clang importer see) and checks the
 * ABI basics that need no model: version, struct_size defaults, error paths that must not abort. */
#include "sherpa_engine.h"

#include <stdio.h>
#include <string.h>

static int failures = 0;
#define CHECK(cond)                                                       \
  do {                                                                    \
    if (!(cond)) {                                                        \
      fprintf(stderr, "c_abi_test: FAILED %s (line %d)\n", #cond, __LINE__); \
      failures++;                                                         \
    }                                                                     \
  } while (0)

int main(void) {
  CHECK(se_abi_version() == SE_ABI_VERSION);
  CHECK(se_abi_minor() == SE_ABI_MINOR && SE_ABI_MINOR >= 1);
  CHECK(strstr(se_version_string(), "sherpa_engine") != NULL);

  /* Media input (1.1): the params helper and the NULL paths. */
  se_generate_params gp;
  se_generate_params_init(&gp);
  CHECK(gp.struct_size == sizeof(se_generate_params));
  CHECK(gp.request_json == NULL && gp.media == NULL && gp.n_media == 0);
  CHECK(se_generate_start_ex(NULL, &gp, NULL) == SE_ERR_INVALID_ARG);
  se_media media = {sizeof(se_media), SE_MEDIA_IMAGE, NULL, 0};
  CHECK(media.struct_size == sizeof(se_media) && media.type == SE_MEDIA_IMAGE);

  se_model_params mp;
  se_model_params_init(&mp);
  CHECK(mp.struct_size == sizeof(se_model_params));
  CHECK(mp.n_gpu_layers == -1 && mp.load_mode == SE_LOAD_MODE_AUTO && mp.use_extra_bufts == 1);

  se_session_params sp;
  se_session_params_init(&sp);
  CHECK(sp.struct_size == sizeof(se_session_params));
  CHECK(sp.type_k == SE_KV_DEFAULT && sp.flash_attn == -1 && sp.seed == SE_SEED_RANDOM);

  /* NULL / bogus arguments return errors instead of crashing. */
  se_model * m = (se_model *) 0x1;
  CHECK(se_model_load(NULL, NULL, &m) == SE_ERR_INVALID_ARG);
  CHECK(m == NULL);
  CHECK(strlen(se_last_error()) > 0);
  CHECK(se_last_error_code() == SE_ERR_INVALID_ARG);
  CHECK(se_model_load("/nonexistent/model.gguf", NULL, &m) == SE_ERR_IO);
  CHECK(se_model_load("/nonexistent/model.gguf", NULL, NULL) == SE_ERR_INVALID_ARG);

  /* A struct_size of 0 is an ABI error, not a crash. */
  se_model_params bad;
  memset(&bad, 0, sizeof bad);
  CHECK(se_model_load("/nonexistent/model.gguf", &bad, &m) == SE_ERR_ABI);

  CHECK(se_cancel(NULL) == SE_ERR_INVALID_ARG);
  CHECK(se_wait(NULL, 0) == SE_ERR_INVALID_ARG);
  CHECK(se_model_info_json(NULL, NULL, 0) == SE_ERR_INVALID_ARG);
  CHECK(strcmp(se_status_name(SE_ERR_BUSY), "SE_ERR_BUSY") == 0);

  /* System info works without a model and reports its size first. */
  int32_t need = se_system_info_json(NULL, 0);
  CHECK(need > 0);
  char buf[16];
  CHECK(se_system_info_json(buf, sizeof buf) == need); /* too small: nothing written, size returned */

  se_canceller * c = se_canceller_create();
  CHECK(c != NULL);
  se_canceller_cancel(c);
  se_canceller_free(c);

  /* Freeing NULL handles is a no-op. */
  se_model_free(NULL);
  se_session_free(NULL);
  se_lora_free(NULL);

  if (failures == 0) printf("c_abi_test: OK\n");
  return failures == 0 ? 0 : 1;
}
