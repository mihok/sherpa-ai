// Models: loading (progress + cancel), model info incl. tool-call classification, tokenization, LoRA
// adapters and the no_alloc memory estimator.
#include "se_internal.h"

#include SE_LLAMA_EXT_H
#include "gguf.h"

#include <fstream>

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

namespace se {

ModelImpl::~ModelImpl() {
#if SE_HAVE_MTMD
  if (mtmd) mtmd_free(mtmd);
#endif
  tmpls.reset();
  if (draft) llama_model_free(draft);
  if (model) llama_model_free(model);
}

LoraImpl::~LoraImpl() {
  // Must run before the model is freed (llama_model_free also frees adapters); `model` keeps it alive.
  if (adapter) llama_adapter_lora_free(adapter);
}

common_chat_params apply_template(const ModelImpl & m, const common_chat_templates_inputs & in) {
  if (!m.tmpls) {
    fail(SE_ERR_TEMPLATE, "model has no usable chat template: " + m.tmpl_error);
  }
  std::lock_guard<std::mutex> lk(m.tmpl_mu);
  try {
    return common_chat_templates_apply(m.tmpls.get(), in);
  } catch (const Error &) {
    throw;
  } catch (const std::exception & e) {
    fail(SE_ERR_TEMPLATE, std::string("chat template: ") + e.what());
  }
}

uint64_t gguf_tensor_data_span(const std::string & path) {
  gguf_init_params gp;
  gp.no_alloc = true;
  gp.ctx      = nullptr;
  gguf_context * g = gguf_init_from_file(path.c_str(), gp);
  if (!g) return 0;
  const size_t off = gguf_get_data_offset(g);
  gguf_free(g);
  const uint64_t size = file_size_or_zero(path);
  return size > off ? size - off : 0;
}

namespace {

std::string meta_str(const llama_model * model, const std::string & key) {
  // llama_model_meta_val_str returns the full length even when truncated, -1 when missing or array-valued
  // (R04 §4), so size the buffer from the first call.
  char small[256];
  const int32_t n = llama_model_meta_val_str(model, key.c_str(), small, sizeof small);
  if (n < 0) return "";
  if ((size_t) n < sizeof small) return std::string(small, (size_t) n);
  std::string big((size_t) n + 1, '\0');
  llama_model_meta_val_str(model, key.c_str(), &big[0], big.size());
  big.resize((size_t) n);
  return big;
}

int64_t meta_int(const llama_model * model, const std::string & key, int64_t def) {
  const std::string v = meta_str(model, key);
  if (v.empty()) return def;
  try {
    return std::stoll(v);
  } catch (...) {
    return def;
  }
}

uint64_t kv_row_bytes(ggml_type t, int64_t n) {
  return (uint64_t) ggml_row_size(t, n);
}

common_json classify_tools(ModelImpl & m, common_json & thinking) {
  common_json out = common_json::object();
  out["support"] = "none";
  if (!m.tmpls) {
    out["error"] = m.tmpl_error;
    return out;
  }
  common_chat_templates_inputs in;
  common_chat_msg usr;
  usr.role    = "user";
  usr.content = "What is the weather in Paris?";
  in.messages = {usr};
  common_chat_tool tool;
  tool.name        = "get_weather";
  tool.description = "Get the current weather for a city";
  tool.parameters  = R"({"type":"object","properties":{"city":{"type":"string"}},"required":["city"]})";
  in.tools            = {tool};
  in.tool_choice      = COMMON_CHAT_TOOL_CHOICE_AUTO;
  in.reasoning_format = COMMON_REASONING_FORMAT_DEEPSEEK;
  try {
    const common_chat_params p = apply_template(m, in);
    out["format"]       = common_chat_format_name(p.format);
    out["grammar_lazy"] = p.grammar_lazy;
    common_json trig = common_json::array();
    for (const auto & t : p.grammar_triggers) {
      common_json o = common_json::object();
      o["type"]  = t.type == COMMON_GRAMMAR_TRIGGER_TYPE_TOKEN ? "token"
                 : t.type == COMMON_GRAMMAR_TRIGGER_TYPE_WORD  ? "word"
                 : t.type == COMMON_GRAMMAR_TRIGGER_TYPE_PATTERN ? "pattern" : "pattern_full";
      o["value"] = t.value;
      trig.push_back(o);
    }
    out["triggers"] = trig;
    const auto caps = common_chat_templates_get_caps(m.tmpls.get());
    const auto cap  = [&](const char * k) { auto it = caps.find(k); return it != caps.end() && it->second; };
    // R04 §12.3: Qwen3/Hermes/Granite 4/Mistral/... get a lazy grammar; Llama 3.x, Phi-3.5, Gemma 2,
    // SmolLM3 render tools and are parsed afterwards, but generation is unconstrained.
    if (!p.grammar.empty()) {
      out["support"] = "native_grammar";
    } else if (cap("supports_tool_calls") && p.format != COMMON_CHAT_FORMAT_CONTENT_ONLY) {
      out["support"] = "parsed_without_grammar";
    }
    out["parallel"] = cap("supports_parallel_tool_calls");
    thinking["supported"] = p.supports_thinking || common_chat_templates_support_enable_thinking(m.tmpls.get());
    thinking["start_tag"] = p.thinking_start_tag;
    common_json ends = common_json::array();
    for (const auto & e : p.thinking_end_tags) ends.push_back(e);
    thinking["end_tags"] = ends;

    in.tool_choice = COMMON_CHAT_TOOL_CHOICE_REQUIRED;
    const common_chat_params pr = apply_template(m, in);
    out["required_grammar"] = !pr.grammar.empty();
  } catch (const std::exception & e) {
    out["support"] = "none";
    out["error"]   = e.what();
  }
  return out;
}

}  // namespace

std::string build_model_info(ModelImpl & m) {
  const llama_model * model = m.model;
  common_json j = common_json::object();
  const std::string arch = meta_str(model, "general.architecture");
  char desc[256] = {0};
  llama_model_desc(model, desc, sizeof desc);
  j["path"]         = m.path;
  j["model_id"]     = m.model_id;
  j["fingerprint"]  = m.fingerprint;
  j["file_bytes"]   = m.file_bytes;
  j["arch"]         = arch;
  j["name"]         = meta_str(model, "general.name");
  j["description"]  = std::string(desc);
  j["ftype"]        = llama_ftype_name(llama_model_ftype(model));
  j["vocab_only"]   = m.vocab_only;
  j["n_params"]     = (uint64_t) llama_model_n_params(model);
  j["size_bytes"]   = (uint64_t) llama_model_size(model);
  j["n_ctx_train"]  = llama_model_n_ctx_train(model);
  j["n_vocab"]      = llama_vocab_n_tokens(m.vocab);
  j["add_bos"]      = llama_vocab_get_add_bos(m.vocab);
  // A vocab-only model has no layers: llama_model_n_head()/n_head_kv() index per-layer arrays and
  // GGML_ABORT for il >= n_layer (src/llama-hparams.cpp:50-56), killing the process. Skip the shape.
  if (!m.vocab_only) {
    j["n_embd"]       = llama_model_n_embd(model);
    j["n_layer"]      = llama_model_n_layer(model);
    j["n_head"]       = llama_model_n_head(model);
    const int32_t n_head_kv = llama_model_n_head_kv(model);
    j["n_head_kv"]    = n_head_kv;
    // head_dim must come from <arch>.attention.key_length: n_embd/n_head is wrong for Qwen3 (64 vs 128,
    // R04 §6).
    const int64_t n_head = std::max<int32_t>(1, llama_model_n_head(model));
    const int64_t key_len = meta_int(model, arch + ".attention.key_length", llama_model_n_embd(model) / n_head);
    const int64_t val_len = meta_int(model, arch + ".attention.value_length", key_len);
    j["key_length"]     = key_len;
    j["value_length"]   = val_len;
    j["sliding_window"] = llama_model_n_swa(model);
    j["n_layer_nextn"]  = llama_model_n_layer_nextn(model);
    j["mtp_loaded"]     = m.mtp_loaded;
    j["is_recurrent"]   = llama_model_is_recurrent(model);
    j["is_hybrid"]      = llama_model_is_hybrid(model);
    j["has_encoder"]    = llama_model_has_encoder(model);

    // KV bytes per token, plain formula (UI hint only: SWA/MLA/recurrent/per-layer head counts differ;
    // se_estimate_memory runs the real dry run).
    {
      common_json kv = common_json::object();
      const int64_t n_layer = llama_model_n_layer(model);
      for (ggml_type t : {GGML_TYPE_F16, GGML_TYPE_Q8_0, GGML_TYPE_Q4_0}) {
        const uint64_t per = (uint64_t) n_layer * (kv_row_bytes(t, n_head_kv * key_len) + kv_row_bytes(t, n_head_kv * val_len));
        kv[ggml_type_name(t)] = per;
      }
      j["kv_bytes_per_token"] = kv;
    }
  }

  // End-of-generation tokens.
  {
    common_json eog = common_json::array();
    const int32_t nv = llama_vocab_n_tokens(m.vocab);
    for (llama_token t = 0; t < nv; ++t) {
      if (llama_vocab_is_eog(m.vocab, t)) {
        common_json o = common_json::object();
        o["id"]   = t;
        o["text"] = common_token_to_piece(m.vocab, t, true);
        eog.push_back(o);
      }
    }
    j["eog_tokens"] = eog;
  }

  // Chat template + tool/thinking classification.
  {
    common_json ct = common_json::object();
    const char * tmpl = llama_model_chat_template(model, nullptr);
    ct["present"]            = tmpl != nullptr;
    ct["tool_use_variant"]   = llama_model_chat_template(model, "tool_use") != nullptr;
    ct["usable"]             = (bool) m.tmpls;
    if (!m.tmpl_error.empty()) ct["error"] = m.tmpl_error;
    if (m.tmpls) {
      ct["explicit"] = common_chat_templates_was_explicit(m.tmpls.get());
      common_json caps = common_json::object();
      for (const auto & kv : common_chat_templates_get_caps(m.tmpls.get())) caps[kv.first] = kv.second;
      ct["caps"] = caps;
    }
    j["chat_template"] = ct;
    common_json thinking = common_json::object();
    thinking["supported"] = false;
    j["tool_calls"] = classify_tools(m, thinking);
    j["thinking"]   = thinking;
  }

  // Author-recommended sampling (general.sampling.*).
  {
    common_json rs = common_json::object();
    for (int k = LLAMA_MODEL_META_KEY_SAMPLING_SEQUENCE; k <= LLAMA_MODEL_META_KEY_SAMPLING_MIROSTAT_ETA; ++k) {
      const char * key = llama_model_meta_key_str((llama_model_meta_key) k);
      if (!key) continue;
      const std::string v = meta_str(model, key);
      if (!v.empty()) rs[key] = v;
    }
    j["recommended_sampling"] = rs;
  }

  {
    common_json d = common_json::object();
    d["present"] = m.draft != nullptr;
    if (m.draft) {
      d["path"]     = m.draft_path;
      d["n_params"] = (uint64_t) llama_model_n_params(m.draft);
    }
    j["draft_model"] = d;
  }
  {
    common_json mm = common_json::object();
#if SE_HAVE_MTMD
    mm["loaded"] = m.mtmd != nullptr;
    mm["vision"] = m.mtmd ? mtmd_support_vision(m.mtmd) : false;
    mm["audio"]  = m.mtmd ? mtmd_support_audio(m.mtmd) : false;
#else
    mm["loaded"] = false;
    mm["compiled"] = false;
#endif
    j["mmproj"] = mm;
  }
  return j.dump_safe();  // GGUF metadata strings are untrusted: replace bad UTF-8 instead of throwing
}

namespace {

struct ProgressCtx {
  se_progress_cb cb = nullptr;
  void *         user = nullptr;
  se_canceller * cancel = nullptr;
  bool           cancelled = false;
};

bool progress_trampoline(float progress, void * ud) {
  auto * pc = static_cast<ProgressCtx *>(ud);
  if (pc->cancel && pc->cancel->flag.load(std::memory_order_acquire)) {
    pc->cancelled = true;
    return false;  // llama_model_load_from_file then returns NULL
  }
  if (pc->cb && pc->cb(progress, pc->user) == 0) {
    pc->cancelled = true;
    return false;
  }
  return true;
}

llama_model_params to_llama_params(const se_model_params & mp) {
  if (mp.load_mode < SE_LOAD_MODE_AUTO || mp.load_mode > SE_LOAD_MODE_DIRECT_IO) {
    fail(SE_ERR_INVALID_ARG, "load_mode " + std::to_string(mp.load_mode) + " out of range");
  }
  llama_model_params lp = llama_model_default_params();
  lp.n_gpu_layers    = mp.n_gpu_layers;
  lp.load_mode       = (llama_load_mode) mp.load_mode;
  lp.use_extra_bufts = mp.use_extra_bufts != 0;
  lp.check_tensors   = mp.check_tensors != 0;
  lp.vocab_only      = mp.vocab_only != 0;
  lp.load_mtp        = mp.load_mtp != 0;
#if defined(TARGET_OS_SIMULATOR) && TARGET_OS_SIMULATOR
  // The iOS simulator's Metal is not a usable inference GPU; upstream's llama.swiftui forces n_gpu_layers
  // = 0 there too (examples/llama.swiftui LibLlama.swift:66-69, R05 §5.1).
  lp.n_gpu_layers = 0;
#endif
  return lp;
}

void require_file(const char * path, const char * what) {
  if (path == nullptr || *path == '\0') fail(SE_ERR_INVALID_ARG, std::string(what) + " path is empty");
  std::ifstream f(path, std::ios::binary);
  if (!f) fail(SE_ERR_IO, std::string("cannot open ") + what + " '" + path + "'");
}

}  // namespace

}  // namespace se

extern "C" {

SE_API se_status se_model_load(const char * path, const se_model_params * p, se_model ** out) {
  return se::guard(__func__, [&]() -> se_status {
    if (out == nullptr) se::fail(SE_ERR_INVALID_ARG, "out is NULL");
    *out = nullptr;
    se::ensure_backend();
    const se_model_params mp = se::read_params(p, se_model_params_init);
    se::require_file(path, "model");

    auto m = std::make_shared<se::ModelImpl>();
    m->path       = path;
    m->vocab_only = mp.vocab_only != 0;
    m->fingerprint = se::quick_fingerprint(path, &m->file_bytes);
    m->model_id   = (mp.model_id && *mp.model_id) ? mp.model_id : m->fingerprint;

    se::ProgressCtx pc{mp.progress_cb, mp.progress_user, mp.cancel, false};
    llama_model_params lp = se::to_llama_params(mp);
    lp.progress_callback           = se::progress_trampoline;
    lp.progress_callback_user_data = &pc;
    m->model = llama_model_load_from_file(path, lp);
    if (m->model == nullptr) {
      if (pc.cancelled) se::fail(SE_ERR_CANCELLED, "model load cancelled");
      se::fail(SE_ERR_MODEL_LOAD, std::string("llama.cpp failed to load '") + path + "' (see log)");
    }
    m->vocab      = llama_model_get_vocab(m->model);
    m->mtp_loaded = mp.load_mtp != 0 && llama_model_n_layer_nextn(m->model) > 0;

    try {
      // Throws on Jinja compile errors (common/chat.cpp:839-846); keep the model usable for raw tokens.
      m->tmpls = common_chat_templates_init(m->model, mp.chat_template_override ? mp.chat_template_override : "");
    } catch (const std::exception & e) {
      m->tmpl_error = e.what();
      se::log(SE_LOG_WARN, "chat template unusable: %s\n", e.what());
    }

    if (mp.draft_model_path && *mp.draft_model_path) {
      se::require_file(mp.draft_model_path, "draft model");
      llama_model_params dp = se::to_llama_params(mp);
      dp.n_gpu_layers = mp.draft_n_gpu_layers;
      dp.vocab_only   = false;
      dp.load_mtp     = false;
      dp.progress_callback           = se::progress_trampoline;
      dp.progress_callback_user_data = &pc;
      m->draft = llama_model_load_from_file(mp.draft_model_path, dp);
      if (m->draft == nullptr) {
        if (pc.cancelled) se::fail(SE_ERR_CANCELLED, "model load cancelled");
        se::fail(SE_ERR_MODEL_LOAD, std::string("failed to load draft model '") + mp.draft_model_path + "'");
      }
      m->draft_path = mp.draft_model_path;
    }

    if (mp.mmproj_path && *mp.mmproj_path) {
#if SE_HAVE_MTMD
      se::require_file(mp.mmproj_path, "mmproj");
      mtmd_context_params mcp = mtmd_context_params_default();
      mcp.use_gpu       = mp.mmproj_use_gpu != 0;
      mcp.print_timings = false;
      mcp.n_threads     = se::default_thread_count();
      m->mtmd = mtmd_init_from_file(mp.mmproj_path, m->model, mcp);
      if (m->mtmd == nullptr) se::fail(SE_ERR_MODEL_LOAD, std::string("failed to load mmproj '") + mp.mmproj_path + "'");
#else
      se::fail(SE_ERR_UNSUPPORTED, "this build has no multimodal (mtmd) support");
#endif
    }

    m->info_json = se::build_model_info(*m);
    *out = new se_model{std::move(m)};
    return SE_OK;
  });
}

SE_API void se_model_free(se_model * m) {
  try {
    delete m;  // drops this handle's reference; sessions/adapters keep the weights alive until they go
  } catch (...) {
  }
}

SE_API int32_t se_model_info_json(const se_model * m, char * buf, int32_t cap) {
  return se::guard(__func__, [&]() -> int32_t {
    if (!m) se::fail(SE_ERR_INVALID_ARG, "model is NULL");
    return se::copy_out(m->impl->info_json, buf, cap);
  });
}

SE_API int32_t se_tokenize(const se_model * m, const char * text, int32_t text_len, int32_t add_special,
                           int32_t parse_special, int32_t * tokens, int32_t cap) {
  return se::guard(__func__, [&]() -> int32_t {
    if (!m) se::fail(SE_ERR_INVALID_ARG, "model is NULL");
    if (!text && text_len != 0) se::fail(SE_ERR_INVALID_ARG, "text is NULL");
    const size_t len = text_len < 0 ? std::strlen(text) : (size_t) text_len;
    const std::string s(text ? text : "", len);
    // "The API is thread-safe" (llama.h:1262).
    const auto toks = common_tokenize(m->impl->vocab, s, add_special != 0, parse_special != 0);
    if (toks.size() > (size_t) INT32_MAX) se::fail(SE_ERR_INVALID_ARG, "too many tokens");
    if (tokens && cap >= (int32_t) toks.size()) {
      std::copy(toks.begin(), toks.end(), tokens);
    }
    return (int32_t) toks.size();
  });
}

SE_API int32_t se_detokenize(const se_model * m, const int32_t * tokens, int32_t n_tokens, int32_t render_special,
                             char * buf, int32_t cap) {
  return se::guard(__func__, [&]() -> int32_t {
    if (!m) se::fail(SE_ERR_INVALID_ARG, "model is NULL");
    if (n_tokens < 0 || (n_tokens > 0 && !tokens)) se::fail(SE_ERR_INVALID_ARG, "invalid token array");
    std::string out;
    for (int32_t i = 0; i < n_tokens; ++i) {
      out += se::token_piece(m->impl->vocab, tokens[i], render_special != 0);  // validates the id
    }
    return se::copy_out(out, buf, cap);
  });
}

SE_API int32_t se_count_chat_tokens(const se_model * m, const char * request_json) {
  return se::guard(__func__, [&]() -> int32_t {
    if (!m) se::fail(SE_ERR_INVALID_ARG, "model is NULL");
    se::ChatRequest req = se::parse_chat_request(*m->impl, request_json);
    const common_chat_params chat = se::apply_template(*m->impl, req.inputs);
    return (int32_t) se::tokenize_prompt(m->impl->vocab, chat.prompt, true).size();
  });
}

SE_API se_status se_lora_load(se_model * m, const char * path, se_lora ** out) {
  return se::guard(__func__, [&]() -> se_status {
    if (!m || !out) se::fail(SE_ERR_INVALID_ARG, "model/out is NULL");
    *out = nullptr;
    se::require_file(path, "LoRA adapter");
    if (m->impl->vocab_only) se::fail(SE_ERR_UNSUPPORTED, "vocab-only model");
    auto l = std::make_shared<se::LoraImpl>();
    l->model       = m->impl;
    l->path        = path;
    l->fingerprint = se::quick_fingerprint(path, nullptr);
    l->adapter     = llama_adapter_lora_init(m->impl->model, path);
    if (!l->adapter) se::fail(SE_ERR_MODEL_LOAD, std::string("failed to load LoRA adapter '") + path + "'");
    *out = new se_lora{std::move(l)};
    return SE_OK;
  });
}

SE_API void se_lora_free(se_lora * l) {
  try {
    delete l;
  } catch (...) {
  }
}

SE_API se_status se_estimate_memory(const char * path, const se_model_params * mp_in, const se_session_params * sp_in,
                                    se_memory_estimate * out) {
  return se::guard(__func__, [&]() -> se_status {
    if (!out) se::fail(SE_ERR_INVALID_ARG, "out is NULL");
    se::ensure_backend();
    se::require_file(path, "model");
    se_model_params mp = se::read_params(mp_in, se_model_params_init);
    const se_session_params sp = se::read_params(sp_in, se_session_params_init);

    llama_model_params lp = se::to_llama_params(mp);
    // no_alloc with any load mode but NONE hits GGML_ASSERT(!ml.no_alloc) and kills the process
    // (src/llama-model.cpp:1855, R04 §3); common/fit.cpp:56-58 forces NONE for the same reason.
    lp.no_alloc   = true;
    lp.load_mode  = LLAMA_LOAD_MODE_NONE;
    lp.vocab_only = false;
    struct ModelDel { void operator()(llama_model * p) const { llama_model_free(p); } };
    std::unique_ptr<llama_model, ModelDel> model(llama_model_load_from_file(path, lp));
    if (!model) se::fail(SE_ERR_MODEL_LOAD, std::string("dry-run load failed for '") + path + "'");

    const bool has_draft = mp.draft_model_path && *mp.draft_model_path;
    const bool mtp       = mp.load_mtp != 0 && llama_model_n_layer_nextn(model.get()) > 0;
    // Same validation as se_session_create (V-quant needs FA, n_outputs_max >= n_seq_max, ...).
    const se::ResolvedSessionParams rp = se::resolve_session_params(model.get(), mtp, has_draft, sp);
    const bool mmap_expected = llama_supports_mmap() &&
        (mp.load_mode == SE_LOAD_MODE_AUTO || mp.load_mode == SE_LOAD_MODE_MMAP || mp.load_mode == SE_LOAD_MODE_MMAP_MLOCK);

    struct CtxDel { void operator()(llama_context * c) const { llama_free(c); } };
    std::string log_text;
    std::unique_ptr<llama_context, CtxDel> ctx;
    {
      se::LogTap tap(&log_text);
      ctx.reset(llama_init_from_model(model.get(), rp.cp));
    }
    if (!ctx) se::fail(SE_ERR_CONTEXT_CREATE, "dry-run context creation failed (see log)");
    uint64_t cpu_weights = 0;
    se_memory_estimate est = se::breakdown_to_estimate(ctx.get(), model.get(), rp.cp.n_outputs_max, false, &cpu_weights);
    est.flash_attn = se::resolved_flash_attn(rp.p.flash_attn, log_text);
    est.file_bytes = se::file_size_or_zero(path);
    if (mmap_expected && cpu_weights > 0) {
      // The dry run uses LOAD_MODE_NONE, so it only sees the host tensors that stay un-repacked. A real
      // mmap load maps one buffer spanning from the first to the last host tensor, which in practice is
      // the whole tensor-data section, and the repacked copies (CPU_REPACK / KleidiAI / AMX) are extra.
      // Measured on Qwen3-0.6B with AMX repack: dry run 122 MiB "CPU", real load 371 MiB "CPU_Mapped" +
      // 378 MiB "AMX" (R04 §3 use_extra_bufts). The mapped part is file-backed (reclaimable), the rest anon.
      const uint64_t span = se::gguf_tensor_data_span(path);
      if (span > 0) {
        est.model_bytes        = est.model_bytes - cpu_weights + span;
        est.model_mapped_bytes = span;
        est.total_bytes        = est.model_bytes + est.kv_bytes + est.compute_bytes + est.output_bytes;
      }
    }

    // A draft model (SE_SPEC_DRAFT) costs its own weights + KV + compute at the same n_ctx.
    if (has_draft && rp.spec_type == SE_SPEC_DRAFT) {
      // (The draft model's weights are counted as the dry run reports them; small drafts rarely repack.)
      llama_model_params dlp = lp;
      dlp.n_gpu_layers = mp.draft_n_gpu_layers;
      dlp.load_mtp     = false;
      std::unique_ptr<llama_model, ModelDel> dm(llama_model_load_from_file(mp.draft_model_path, dlp));
      if (!dm) se::fail(SE_ERR_MODEL_LOAD, std::string("dry-run load failed for draft '") + mp.draft_model_path + "'");
      llama_context_params dcp = rp.cp;
      dcp.n_outputs_max         = 1;
      dcp.n_outputs_max_per_seq = 1;
      dcp.n_rs_seq              = 0;
      dcp.abort_callback        = nullptr;
      std::unique_ptr<llama_context, CtxDel> dctx(llama_init_from_model(dm.get(), dcp));
      if (!dctx) se::fail(SE_ERR_CONTEXT_CREATE, "dry-run draft context creation failed");
      const se_memory_estimate d = se::breakdown_to_estimate(dctx.get(), dm.get(), 1, mmap_expected);
      est.model_bytes        += d.model_bytes;
      est.model_mapped_bytes += d.model_mapped_bytes;
      est.kv_bytes           += d.kv_bytes;
      est.compute_bytes      += d.compute_bytes;
      est.output_bytes       += d.output_bytes;
      est.total_bytes        += d.total_bytes;
      est.file_bytes         += se::file_size_or_zero(mp.draft_model_path);
    }
    se::write_out(out, est);
    return SE_OK;
  });
}

}  // extern "C"
