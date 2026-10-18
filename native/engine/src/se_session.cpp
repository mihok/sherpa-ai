// Sessions: parameter resolution (with the GGML_ASSERT guards), context + threadpools + speculative
// setup, the event ring, the generation worker thread, LoRA sets and session introspection.
#include "se_internal.h"

#include SE_LLAMA_EXT_H
#include "ggml-backend.h"
#include "ggml-cpu.h"

#include <algorithm>
#include <cmath>

namespace se {

// =========================================================================================================
// Event ring
// =========================================================================================================

void Event::bind() {
  ev.struct_size = sizeof(se_event);
  ev.text        = text.c_str();
  ev.text_len    = (uint32_t) text.size();
  ev.id          = id.c_str();
  ev.name        = name.c_str();
}

EventRing::EventRing(uint32_t capacity) : slots_(capacity), cap_(capacity) {
  batch_.reserve(capacity);
}

bool EventRing::push(Event && e) {
  const uint64_t h = head_.load(std::memory_order_relaxed);
  if (h - released_.load(std::memory_order_acquire) >= cap_) {
    // Full: block the producer (backpressure). Only shutdown (session free) aborts the wait, so a slow
    // consumer never loses an event. Cancellation is handled by the caller after the event is queued.
    std::unique_lock<std::mutex> lk(mu_);
    cv_space_.wait(lk, [&] {
      return shutdown_.load(std::memory_order_acquire) || h - released_.load(std::memory_order_acquire) < cap_;
    });
  }
  if (shutdown_.load(std::memory_order_acquire)) return false;
  Event & slot = slots_[h % cap_];
  slot = std::move(e);
  slot.bind();  // pointers must refer to the slot's own strings (SSO buffers move with the object)
  head_.store(h + 1, std::memory_order_release);
  { std::lock_guard<std::mutex> lk(mu_); }  // a consumer between its predicate check and wait() sees head
  cv_data_.notify_one();
  return true;
}

int32_t EventRing::poll(int32_t timeout_ms, int32_t max_events, const se_event ** out) {
  const uint64_t t = tail_.load(std::memory_order_relaxed);
  // The batch handed out by the previous poll is released only now: that is the lifetime promised to
  // the caller ("valid until the next se_poll_events").
  if (released_.load(std::memory_order_relaxed) != t) {
    released_.store(t, std::memory_order_release);
    { std::lock_guard<std::mutex> lk(mu_); }
    cv_space_.notify_one();
  }
  if (head_.load(std::memory_order_acquire) == t && timeout_ms != 0) {
    std::unique_lock<std::mutex> lk(mu_);
    auto ready = [&] { return shutdown_.load() || head_.load(std::memory_order_acquire) != t; };
    if (timeout_ms < 0) {
      cv_data_.wait(lk, ready);
    } else {
      cv_data_.wait_for(lk, std::chrono::milliseconds(timeout_ms), ready);
    }
  }
  uint64_t n = head_.load(std::memory_order_acquire) - t;
  if (max_events > 0) n = std::min<uint64_t>(n, (uint64_t) max_events);
  batch_.clear();
  for (uint64_t i = 0; i < n; ++i) batch_.push_back(slots_[(t + i) % cap_].ev);
  tail_.store(t + n, std::memory_order_relaxed);
  *out = batch_.empty() ? nullptr : batch_.data();
  return (int32_t) n;
}

void EventRing::shutdown() {
  shutdown_.store(true, std::memory_order_release);
  { std::lock_guard<std::mutex> lk(mu_); }
  cv_space_.notify_all();
  cv_data_.notify_all();
}

size_t EventRing::pending() const {
  return (size_t) (head_.load(std::memory_order_acquire) - tail_.load(std::memory_order_relaxed));
}

// =========================================================================================================
// Parameter resolution
// =========================================================================================================

namespace {

bool kv_type_allowed(int32_t t) {
  switch (t) {
    case GGML_TYPE_F32: case GGML_TYPE_F16: case GGML_TYPE_BF16: case GGML_TYPE_Q8_0: case GGML_TYPE_Q4_0:
    case GGML_TYPE_Q4_1: case GGML_TYPE_Q5_0: case GGML_TYPE_Q5_1: case GGML_TYPE_IQ4_NL:
      return true;
    default:
      return false;
  }
}

int64_t head_dim(const llama_model * model, const char * which) {
  char arch[64] = {0};
  llama_model_meta_val_str(model, "general.architecture", arch, sizeof arch);
  char buf[32] = {0};
  const std::string key = std::string(arch) + ".attention." + which;
  if (llama_model_meta_val_str(model, key.c_str(), buf, sizeof buf) > 0) {
    try { return std::stoll(buf); } catch (...) {}
  }
  const int32_t nh = std::max(1, llama_model_n_head(model));
  return llama_model_n_embd(model) / nh;
}

}  // namespace

ResolvedSessionParams resolve_session_params(const llama_model * model, bool mtp_loaded, bool has_draft,
                                             const se_session_params & in) {
  ResolvedSessionParams r;
  se_session_params & p = r.p;
  p = in;
  const int32_t n_ctx_train = llama_model_n_ctx_train(model);
  if (p.n_ctx == 0) p.n_ctx = (uint32_t) std::min<int32_t>(4096, n_ctx_train > 0 ? n_ctx_train : 4096);
  if (p.n_ctx < 16 || p.n_ctx > (1u << 22)) fail(SE_ERR_INVALID_ARG, "n_ctx out of range");
  if (p.n_batch == 0) p.n_batch = 512;
  if (p.n_ubatch == 0) p.n_ubatch = 512;
  if (p.n_batch > (1u << 16) || p.n_ubatch > (1u << 16)) fail(SE_ERR_INVALID_ARG, "n_batch/n_ubatch out of range");
  p.n_batch  = std::min(p.n_batch, p.n_ctx);
  p.n_ubatch = std::min(p.n_ubatch, p.n_batch);
  if (p.n_threads <= 0) p.n_threads = default_thread_count();
  if (p.n_threads_batch <= 0) p.n_threads_batch = p.n_threads;
  p.n_threads       = std::min(p.n_threads, 256);
  p.n_threads_batch = std::min(p.n_threads_batch, 256);
  if (p.type_k == SE_KV_DEFAULT) p.type_k = GGML_TYPE_F16;
  if (p.type_v == SE_KV_DEFAULT) p.type_v = GGML_TYPE_F16;
  if (!kv_type_allowed(p.type_k) || !kv_type_allowed(p.type_v)) {
    fail(SE_ERR_INVALID_ARG, "unsupported KV cache type " + ggml_type_label(p.type_k) + "/" + ggml_type_label(p.type_v));
  }
  if (p.flash_attn < -1 || p.flash_attn > 1) fail(SE_ERR_INVALID_ARG, "flash_attn must be -1, 0 or 1");
  // R04 §5: a quantized V cache needs flash attention; llama_init_from_model returns NULL for DISABLED
  // (src/llama-context.cpp:3840-3848). Report it as a clear argument error instead.
  if (is_quantized_kv(p.type_v) && p.flash_attn == 0) {
    fail(SE_ERR_INVALID_ARG, "a quantized V cache (" + ggml_type_label(p.type_v) +
                                 ") requires flash attention; use flash_attn = -1 (auto) or 1");
  }
  // With flash attention the quant block must divide the head size (:3851-3870).
  if (p.flash_attn != 0) {
    const int64_t hk = head_dim(model, "key_length"), hv = head_dim(model, "value_length");
    if (is_quantized_kv(p.type_k) && hk % ggml_blck_size((ggml_type) p.type_k) != 0) {
      fail(SE_ERR_INVALID_ARG, "K cache type " + ggml_type_label(p.type_k) + " block size does not divide head_dim " + std::to_string(hk));
    }
    if (is_quantized_kv(p.type_v) && hv % ggml_blck_size((ggml_type) p.type_v) != 0) {
      fail(SE_ERR_INVALID_ARG, "V cache type " + ggml_type_label(p.type_v) + " block size does not divide head_dim " + std::to_string(hv));
    }
  }
  if (p.swa_full < 0) p.swa_full = 1;

  // ---- speculative decoding
  if (p.spec_type == SE_SPEC_AUTO) {
    p.spec_type = mtp_loaded ? SE_SPEC_MTP : has_draft ? SE_SPEC_DRAFT : SE_SPEC_NONE;
  }
  if (p.spec_type < SE_SPEC_NONE || p.spec_type > SE_SPEC_MTP) fail(SE_ERR_INVALID_ARG, "unknown spec_type");
  if (p.spec_type == SE_SPEC_MTP && !mtp_loaded) {
    fail(SE_ERR_UNSUPPORTED, "SE_SPEC_MTP needs NextN heads: the model has none or was loaded without load_mtp = 1");
  }
  if (p.spec_type == SE_SPEC_DRAFT && !has_draft) {
    fail(SE_ERR_UNSUPPORTED, "SE_SPEC_DRAFT needs se_model_params.draft_model_path");
  }
  if (p.spec_n_max == 0) p.spec_n_max = 16;
  if (p.spec_n_min == 0) p.spec_n_min = 4;
  if (p.spec_ngram_n_match == 0) p.spec_ngram_n_match = 12;
  if (p.spec_min_accept == 0.0f) p.spec_min_accept = 0.30f;
  if (p.spec_min_drafted <= 0) p.spec_min_drafted = 48;
  if (p.spec_n_max < 1 || p.spec_n_max > 64) fail(SE_ERR_INVALID_ARG, "spec_n_max must be in [1, 64]");
  if (p.spec_n_min < 0 || p.spec_n_min > p.spec_n_max) fail(SE_ERR_INVALID_ARG, "spec_n_min must be in [0, spec_n_max]");
  if (p.spec_ngram_n_match < 2 || p.spec_ngram_n_match > 64) fail(SE_ERR_INVALID_ARG, "spec_ngram_n_match must be in [2, 64]");
  r.spec_type   = p.spec_type;
  r.n_draft_max = p.spec_type == SE_SPEC_NONE ? 0 : p.spec_n_max;
  if (r.n_draft_max + 1 > (int32_t) p.n_batch) {
    fail(SE_ERR_INVALID_ARG, "n_batch must be > spec_n_max (the verification batch holds the drafts + 1)");
  }

  // ---- outputs: R04 §6/§7. The logits buffer is n_vocab * n_outputs_max floats (upstream default n_batch
  // => ~300 MB for a 152k vocab). We need 1 row per decode, n_draft + 1 rows when verifying drafts.
  // llama_context reserves max(n_outputs, n_seq_max) rows and GGML_ASSERTs that this is <= n_outputs_max
  // (src/llama-context.cpp:2120, 2273, via :377): n_outputs_max < n_seq_max kills the process.
  const uint32_t n_seq_max = 1;
  const uint32_t need = std::max<uint32_t>(n_seq_max, (uint32_t) r.n_draft_max + 1);
  if (p.n_outputs_max == 0) {
    p.n_outputs_max = need;
  } else if (p.n_outputs_max < need) {
    fail(SE_ERR_INVALID_ARG, "n_outputs_max " + std::to_string(p.n_outputs_max) + " is below the " + std::to_string(need) +
                                 " this session needs (n_seq_max = 1, spec_n_max + 1); llama.cpp would abort");
  } else if (p.n_outputs_max > p.n_batch) {
    p.n_outputs_max = p.n_batch;
  }
  if (p.event_capacity == 0) p.event_capacity = 256;
  if (p.event_capacity < 4 || p.event_capacity > 65536) fail(SE_ERR_INVALID_ARG, "event_capacity must be in [4, 65536]");

  llama_context_params cp = llama_context_default_params();
  cp.n_ctx                 = p.n_ctx;
  cp.n_batch               = p.n_batch;
  cp.n_ubatch              = p.n_ubatch;
  cp.n_seq_max             = n_seq_max;
  cp.n_outputs_max         = p.n_outputs_max;
  // Verification of n_draft tokens of one sequence needs that many outputs for that sequence
  // (common_speculative_get_output_limits, common/speculative.cpp:2586-2597).
  cp.n_outputs_max_per_seq = p.n_outputs_max;
  cp.n_threads             = p.n_threads;
  cp.n_threads_batch       = p.n_threads_batch;
  cp.flash_attn_type       = (llama_flash_attn_type) p.flash_attn;
  cp.type_k                = (ggml_type) p.type_k;
  cp.type_v                = (ggml_type) p.type_v;
  cp.swa_full              = p.swa_full != 0;
  cp.kv_unified            = true;  // n_seq_max = 1: identical, and keeps n_ctx_seq == n_ctx
  cp.no_perf               = true;  // we time decode ourselves (R04 §18: the counters merge buckets)
  // Recurrent/hybrid targets need rollback snapshots for MTP-style drafts (common.h need_n_rs_seq);
  // llama.cpp clamps this to 0 for architectures that cannot use it.
  cp.n_rs_seq              = p.spec_type == SE_SPEC_MTP ? (uint32_t) r.n_draft_max : 0;
  r.cp = cp;
  return r;
}

se_memory_estimate breakdown_to_estimate(llama_context * ctx, const llama_model * model, uint32_t n_outputs_max,
                                         bool mmap_expected, uint64_t * cpu_model_bytes) {
  se_memory_estimate e{};
  e.struct_size = sizeof(e);
  uint64_t cpu = 0;
  for (const auto & kv : llama_get_memory_breakdown(ctx)) {
    const std::string name = kv.first ? ggml_backend_buft_name(kv.first) : "";
    e.model_bytes   += kv.second.model;
    e.kv_bytes      += kv.second.context;
    e.compute_bytes += kv.second.compute;
    if (name == "CPU_Mapped" || (mmap_expected && name == "CPU")) e.model_mapped_bytes += kv.second.model;
    if (name == "CPU_Mapped" || name == "CPU") cpu += kv.second.model;
  }
  if (cpu_model_bytes) *cpu_model_bytes = cpu;
  // The logits buffer (buf_output) is allocated by llama_context but not part of the breakdown; it grows
  // to n_vocab * n_outputs rows on demand (llama-context.cpp:2116-2160).
  e.output_bytes = (uint64_t) llama_vocab_n_tokens(llama_model_get_vocab(model)) * n_outputs_max * sizeof(float);
  e.total_bytes  = e.model_bytes + e.kv_bytes + e.compute_bytes + e.output_bytes;
  e.n_ctx        = llama_n_ctx(ctx);
  e.n_ctx_seq    = llama_n_ctx_seq(ctx);
  e.kv_bytes_per_token = e.n_ctx ? e.kv_bytes / e.n_ctx : 0;
  e.flash_attn   = -1;
  return e;
}

// =========================================================================================================
// Session
// =========================================================================================================

namespace {

bool abort_trampoline(void * data) {
  // ggml polls this between graph nodes (CPU) / command buffers (Metal): a long prefill chunk stops early
  // and llama_decode returns 2 after removing the aborted ubatch's positions (llama-context.cpp:1885-1917).
  return static_cast<SessionImpl *>(data)->cancel.load(std::memory_order_relaxed);
}

}  // namespace

BusyScope::BusyScope(SessionImpl & s_) : s(s_) {
  std::lock_guard<std::mutex> lk(s.mu);
  if (s.busy.load()) fail(SE_ERR_BUSY, "a generation is running on this session");
  s.busy.store(true);
}

BusyScope::~BusyScope() {
  {
    std::lock_guard<std::mutex> lk(s.mu);
    s.busy.store(false);
  }
  s.cv.notify_all();
}

bool ThreadPools::reset(int32_t n_threads, int32_t n_threads_batch) {
  release();
  // ggml_threadpool_new lives in the CPU backend, which is a dlopen()ed module on Android, hence the
  // proc-address lookup (works for static builds too).
  ggml_backend_dev_t cpu = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU);
  if (!cpu) return false;
  ggml_backend_reg_t reg = ggml_backend_dev_backend_reg(cpu);
  auto * tp_new = (decltype(ggml_threadpool_new) *) ggml_backend_reg_get_proc_address(reg, "ggml_threadpool_new");
  free_fn       = (decltype(ggml_threadpool_free) *) ggml_backend_reg_get_proc_address(reg, "ggml_threadpool_free");
  if (!tp_new || !free_fn) return false;
  ggml_threadpool_params tpp, tpp_b;
  ggml_threadpool_params_init(&tpp, n_threads);
  ggml_threadpool_params_init(&tpp_b, n_threads_batch);
  if (!ggml_threadpool_params_match(&tpp, &tpp_b)) {
    tp_batch = tp_new(&tpp_b);
    tpp.paused = true;  // only one of the two pools spins at a time
  }
  tp = tp_new(&tpp);
  if (!tp) {
    release();
    return false;
  }
  return true;
}

void ThreadPools::attach(llama_context * ctx) const {
  if (ctx && tp) llama_attach_threadpool(ctx, tp, tp_batch);
}

void ThreadPools::release() {
  if (free_fn) {
    if (tp) free_fn(tp);
    if (tp_batch) free_fn(tp_batch);
  }
  tp = tp_batch = nullptr;
}

void SessionImpl::setup_threadpools() {
  llama_detach_threadpool(ctx);
  if (ctx_dft) llama_detach_threadpool(ctx_dft);
  if (!pools.reset(n_threads, n_threads_batch)) {
    log(SE_LOG_WARN, "threadpool creation failed; ggml will create pools per graph\n");
    return;
  }
  pools.attach(ctx);
  pools.attach(ctx_dft);
}

void SessionImpl::clear_kv() {
  llama_memory_clear(llama_get_memory(ctx), true);
  history.clear();
  if (ctx_dft) llama_memory_clear(llama_get_memory(ctx_dft), true);
  n_dft_synced = 0;
}

SessionImpl::~SessionImpl() {
  {
    std::lock_guard<std::mutex> lk(mu);
    stopping = true;
  }
  cancel.store(true);
  ring.shutdown();
  cv.notify_all();
  if (worker.joinable()) worker.join();
  if (spec) common_speculative_free(spec);
  if (ctx_dft) llama_free(ctx_dft);
  if (ctx) llama_free(ctx);
  pools.release();  // after the contexts that used them
}

void SessionImpl::worker_main() {
  for (;;) {
    ChatRequest req;
    uint32_t    id = 0;
    {
      std::unique_lock<std::mutex> lk(mu);
      cv.wait(lk, [&] { return has_job || stopping; });
      if (stopping) {
        has_job = false;
        busy.store(false);
        cv.notify_all();
        return;
      }
      req     = std::move(job);
      id      = job_id;
      has_job = false;
    }
    run_generation(id, req);  // never throws: errors become ERROR + FINISH events
    {
      std::lock_guard<std::mutex> lk(mu);
      busy.store(false);
    }
    cv.notify_all();
  }
}

void SessionImpl::emit(Event && e) {
  e.ev.struct_size   = sizeof(se_event);
  e.ev.generation_id = cur_gen;
  if (cb) {
    e.bind();
    cb(&e.ev, cb_user);  // synchronous on the worker; a slow callback is backpressure too
    if (!cb_queue_too) return;
  }
  ring.push(std::move(e));
}

se_memory_estimate SessionImpl::memory() {
  // A live context reports its mmap'd weights as "CPU_Mapped" itself.
  se_memory_estimate e = breakdown_to_estimate(ctx, model->model, n_outputs_max, /*mmap_expected*/ false);
  if (ctx_dft) {
    const llama_model * dm = llama_get_model(ctx_dft);
    const se_memory_estimate d = breakdown_to_estimate(ctx_dft, dm, 1, false);
    // An MTP context shares the target's weights; only count a separate draft model's weights.
    if (dm != model->model) {
      e.model_bytes        += d.model_bytes;
      e.model_mapped_bytes += d.model_mapped_bytes;
    }
    e.kv_bytes      += d.kv_bytes;
    e.compute_bytes += d.compute_bytes;
    e.output_bytes  += d.output_bytes;
    e.total_bytes    = e.model_bytes + e.kv_bytes + e.compute_bytes + e.output_bytes;
  }
  e.flash_attn = flash_attn_resolved;
  e.file_bytes = model->file_bytes;
  return e;
}

std::string SessionImpl::info_json(bool idle) {
  common_json j = common_json::object();
  j["busy"]            = !idle;
  j["n_ctx"]           = n_ctx;
  j["n_ctx_seq"]       = n_ctx_seq;
  j["n_batch"]         = n_batch;
  j["n_ubatch"]        = n_ubatch;
  j["n_outputs_max"]   = n_outputs_max;
  j["n_threads"]       = n_threads;
  j["n_threads_batch"] = n_threads_batch;
  j["type_k"]          = ggml_type_label(params.type_k);
  j["type_v"]          = ggml_type_label(params.type_v);
  j["flash_attn"]      = flash_attn_resolved;
  j["swa_full"]        = params.swa_full != 0;
  // "prefix": LCP reuse of the KV cache; "full_only": recurrent/hybrid memory cannot drop a suffix, so a
  // changed prompt is re-prefilled (no PARTIAL_ONLY checkpoints yet, R04 §17).
  j["prompt_cache"]    = can_partial_rm ? "prefix" : "full_only";
  j["backend"]         = backend_label();
  common_json sp = common_json::object();
  sp["type"] = spec_type == SE_SPEC_NGRAM_MOD ? "ngram-mod" : spec_type == SE_SPEC_DRAFT ? "draft"
             : spec_type == SE_SPEC_MTP ? "mtp" : "none";
  sp["n_max"]          = n_draft_max;
  sp["n_drafted"]      = spec_stats.n_drafted.load();
  sp["n_accepted"]     = spec_stats.n_accepted.load();
  sp["auto_disabled"]  = spec_stats.n_auto_disabled.load();
  j["speculative"] = sp;
  common_json lo = common_json::array();
  for (size_t i = 0; i < loras.size(); ++i) {
    common_json o = common_json::object();
    o["path"]  = loras[i]->path;
    o["scale"] = lora_scales[i];
    lo.push_back(o);
  }
  j["loras"] = lo;
  if (idle) {
    // Worker-owned state is only read while the caller holds a BusyScope.
    j["history_tokens"] = (uint64_t) history.size();
    const se_memory_estimate m = memory();
    common_json mj = common_json::object();
    mj["model_bytes"]   = m.model_bytes;
    mj["model_mapped_bytes"] = m.model_mapped_bytes;
    mj["kv_bytes"]      = m.kv_bytes;
    mj["compute_bytes"] = m.compute_bytes;
    mj["output_bytes"]  = m.output_bytes;
    mj["total_bytes"]   = m.total_bytes;
    j["memory"] = mj;
  }
  return j.dump_safe();
}

}  // namespace se

extern "C" {

SE_API se_status se_session_create(se_model * m, const se_session_params * p, se_session ** out) {
  return se::guard(__func__, [&]() -> se_status {
    if (!m || !out) se::fail(SE_ERR_INVALID_ARG, "model/out is NULL");
    *out = nullptr;
    se::ensure_backend();
    auto & model = m->impl;
    if (model->vocab_only) se::fail(SE_ERR_UNSUPPORTED, "the model was loaded with vocab_only");
    const se_session_params in = se::read_params(p, se_session_params_init);
    const se::ResolvedSessionParams rp = se::resolve_session_params(model->model, model->mtp_loaded, model->draft != nullptr, in);

    auto s = std::make_unique<se::SessionImpl>(rp.p.event_capacity);
    s->model           = model;
    s->params          = rp.p;
    s->spec_type       = rp.spec_type;
    s->n_draft_max     = rp.n_draft_max;
    s->n_threads       = rp.p.n_threads;
    s->n_threads_batch = rp.p.n_threads_batch;
    s->rng            ^= (uint64_t) rp.p.seed * 0x2545F4914F6CDD1Dull;

    llama_context_params cp = rp.cp;
    cp.abort_callback      = se::abort_trampoline;
    cp.abort_callback_data = s.get();
    std::string log_text;
    {
      se::LogTap tap(&log_text);
      s->ctx = llama_init_from_model(model->model, cp);
    }
    if (!s->ctx) se::fail(SE_ERR_CONTEXT_CREATE, "llama_init_from_model failed (memory or unsupported KV/flash-attention combination; see log)");
    s->flash_attn_resolved = se::resolved_flash_attn(rp.p.flash_attn, log_text);
    // llama.cpp pads n_ctx to a multiple of 256 and clamps n_batch (R04 §5): use what it actually built.
    s->n_ctx         = llama_n_ctx(s->ctx);
    s->n_ctx_seq     = llama_n_ctx_seq(s->ctx);
    s->n_batch       = llama_n_batch(s->ctx);
    s->n_ubatch      = llama_n_ubatch(s->ctx);
    s->n_outputs_max = rp.p.n_outputs_max;
    // Recurrent / hybrid memories cannot remove a partial sequence (llama_memory_seq_rm returns false),
    // so the prompt cache falls back to a full re-prefill for them.
    s->can_partial_rm = !llama_model_is_recurrent(model->model) && !llama_model_is_hybrid(model->model);

    // ---- speculative decoding (common/speculative.h, R04 §15)
    if (rp.spec_type != SE_SPEC_NONE) {
      common_params_speculative sp;
      if (rp.spec_type == SE_SPEC_NGRAM_MOD) {
        sp.types             = {COMMON_SPECULATIVE_TYPE_NGRAM_MOD};
        sp.ngram_mod.n_match = rp.p.spec_ngram_n_match;
        sp.ngram_mod.n_max   = rp.p.spec_n_max;
        sp.ngram_mod.n_min   = rp.p.spec_n_min;
      } else {
        // Draft contexts mirror common_speculative_init_result (common/speculative.cpp:2512-2580): same
        // n_ctx as the target, ctx_other = target, one output per decode.
        llama_context_params dcp = rp.cp;
        dcp.n_ctx                 = s->n_ctx;
        dcp.n_outputs_max         = 1;
        dcp.n_outputs_max_per_seq = 1;
        dcp.n_rs_seq              = 0;
        dcp.ctx_other             = s->ctx;
        dcp.abort_callback        = se::abort_trampoline;
        dcp.abort_callback_data   = s.get();
        llama_model * dm = model->model;
        if (rp.spec_type == SE_SPEC_MTP) {
          dcp.ctx_type = LLAMA_CONTEXT_TYPE_MTP;
          sp.types     = {COMMON_SPECULATIVE_TYPE_DRAFT_MTP};
        } else {
          dm       = model->draft;
          sp.types = {COMMON_SPECULATIVE_TYPE_DRAFT_SIMPLE};
        }
        s->ctx_dft = llama_init_from_model(dm, dcp);
        if (!s->ctx_dft) se::fail(SE_ERR_CONTEXT_CREATE, "draft/MTP context creation failed (see log)");
        sp.draft.n_max   = rp.p.spec_n_max;
        sp.draft.n_min   = 0;
        sp.draft.ctx_tgt = s->ctx;
        sp.draft.ctx_dft = s->ctx_dft;
        sp.draft.cache_type_k = (ggml_type) rp.p.type_k;
        sp.draft.cache_type_v = (ggml_type) rp.p.type_v;
      }
      try {
        // draft-simple throws if the vocabularies are incompatible (speculative.cpp:250-262).
        s->spec = common_speculative_init(sp, /*n_seq*/ 1);
      } catch (const std::exception & e) {
        se::fail(SE_ERR_UNSUPPORTED, std::string("speculative decoding unavailable: ") + e.what());
      }
      if (!s->spec) se::fail(SE_ERR_UNSUPPORTED, "no usable speculative implementation");
    }

    s->setup_threadpools();
    s->worker = std::thread([raw = s.get()] { raw->worker_main(); });
    *out = new se_session{std::move(s)};
    return SE_OK;
  });
}

SE_API void se_session_free(se_session * s) {
  try {
    delete s;  // ~SessionImpl cancels, wakes and joins the worker before freeing llama state
  } catch (...) {
  }
}

SE_API se_status se_session_reset(se_session * s) {
  return se::guard(__func__, [&]() -> se_status {
    if (!s) se::fail(SE_ERR_INVALID_ARG, "session is NULL");
    se::BusyScope busy(*s->impl);
    s->impl->clear_kv();
    return SE_OK;
  });
}

SE_API se_status se_session_set_threads(se_session * s, int32_t n_threads, int32_t n_threads_batch) {
  return se::guard(__func__, [&]() -> se_status {
    if (!s) se::fail(SE_ERR_INVALID_ARG, "session is NULL");
    if (n_threads <= 0) n_threads = se::default_thread_count();
    if (n_threads_batch <= 0) n_threads_batch = n_threads;
    if (n_threads > 256 || n_threads_batch > 256) se::fail(SE_ERR_INVALID_ARG, "too many threads");
    se::BusyScope busy(*s->impl);
    auto & S = *s->impl;
    S.n_threads       = n_threads;
    S.n_threads_batch = n_threads_batch;
    llama_set_n_threads(S.ctx, n_threads, n_threads_batch);
    if (S.ctx_dft) llama_set_n_threads(S.ctx_dft, n_threads, n_threads_batch);
    S.setup_threadpools();  // pools must match n_threads exactly
    return SE_OK;
  });
}

SE_API int32_t se_session_info_json(se_session * s, char * buf, int32_t cap) {
  return se::guard(__func__, [&]() -> int32_t {
    if (!s) se::fail(SE_ERR_INVALID_ARG, "session is NULL");
    auto & S = *s->impl;
    std::unique_ptr<se::BusyScope> scope;
    try {
      scope.reset(new se::BusyScope(S));
    } catch (const se::Error &) {
      // generating: report the static part only
    }
    return se::copy_out(S.info_json(scope != nullptr), buf, cap);
  });
}

SE_API se_status se_session_memory(se_session * s, se_memory_estimate * out) {
  return se::guard(__func__, [&]() -> se_status {
    if (!s) se::fail(SE_ERR_INVALID_ARG, "session is NULL");
    se::BusyScope busy(*s->impl);
    se::write_out(out, s->impl->memory());
    return SE_OK;
  });
}

SE_API se_status se_generate_start(se_session * s, const char * request_json, uint32_t * generation_id_out) {
  return se::guard(__func__, [&]() -> se_status {
    if (!s) se::fail(SE_ERR_INVALID_ARG, "session is NULL");
    auto & S = *s->impl;
    se::ChatRequest req = se::parse_chat_request(*S.model, request_json);
    uint32_t id = 0;
    {
      std::lock_guard<std::mutex> lk(S.mu);
      if (S.busy.load()) se::fail(SE_ERR_BUSY, "a generation is already running on this session");
      S.busy.store(true);
      S.cancel.store(false);
      S.job     = std::move(req);
      id        = S.next_gen_id++;
      S.job_id  = id;
      S.has_job = true;
    }
    S.cv.notify_all();
    if (generation_id_out) *generation_id_out = id;
    return SE_OK;
  });
}

SE_API se_status se_poll_events(se_session * s, int32_t timeout_ms, int32_t max_events, const se_event ** events,
                                int32_t * n_events) {
  return se::guard(__func__, [&]() -> se_status {
    if (!s || !events || !n_events) se::fail(SE_ERR_INVALID_ARG, "NULL argument");
    *events   = nullptr;
    *n_events = s->impl->ring.poll(timeout_ms, max_events, events);
    return SE_OK;
  });
}

SE_API se_status se_set_event_callback(se_session * s, se_event_cb cb, void * user, int32_t queue_too) {
  return se::guard(__func__, [&]() -> se_status {
    if (!s) se::fail(SE_ERR_INVALID_ARG, "session is NULL");
    se::BusyScope busy(*s->impl);
    s->impl->cb           = cb;
    s->impl->cb_user      = user;
    s->impl->cb_queue_too = cb == nullptr || queue_too != 0;
    return SE_OK;
  });
}

SE_API se_status se_cancel(se_session * s) {
  if (!s) return SE_ERR_INVALID_ARG;
  s->impl->cancel.store(true, std::memory_order_release);
  return SE_OK;
}

SE_API se_status se_wait(se_session * s, int32_t timeout_ms) {
  return se::guard(__func__, [&]() -> se_status {
    if (!s) se::fail(SE_ERR_INVALID_ARG, "session is NULL");
    auto & S = *s->impl;
    std::unique_lock<std::mutex> lk(S.mu);
    auto idle = [&] { return !S.busy.load(); };
    if (timeout_ms < 0) {
      S.cv.wait(lk, idle);
      return SE_OK;
    }
    if (S.cv.wait_for(lk, std::chrono::milliseconds(timeout_ms), idle)) return SE_OK;
    return SE_ERR_TIMEOUT;
  });
}

SE_API se_status se_session_set_loras(se_session * s, se_lora * const * loras, const float * scales, int32_t n) {
  return se::guard(__func__, [&]() -> se_status {
    if (!s) se::fail(SE_ERR_INVALID_ARG, "session is NULL");
    if (n < 0 || (n > 0 && (!loras || !scales))) se::fail(SE_ERR_INVALID_ARG, "invalid adapter arrays");
    auto & S = *s->impl;
    std::vector<std::shared_ptr<se::LoraImpl>> set;
    std::vector<float>                          sc;
    std::vector<llama_adapter_lora *>           ptrs;
    for (int32_t i = 0; i < n; ++i) {
      if (!loras[i]) se::fail(SE_ERR_INVALID_ARG, "adapter " + std::to_string(i) + " is NULL");
      if (loras[i]->impl->model != S.model) se::fail(SE_ERR_INVALID_ARG, "adapter belongs to another model");
      if (!std::isfinite(scales[i])) se::fail(SE_ERR_INVALID_ARG, "adapter scale must be finite");
      set.push_back(loras[i]->impl);
      sc.push_back(scales[i]);
      ptrs.push_back(loras[i]->impl->adapter);
    }
    se::BusyScope busy(S);
    const bool changed = set != S.loras || sc != S.lora_scales;
    // Replace-only API: no-op if unchanged, scale-0 adapters are dropped, the graph is re-reserved on the
    // next decode and the base model is not reloaded (src/llama-context.cpp:1339-1381).
    const int32_t rc = llama_set_adapters_lora(S.ctx, ptrs.data(), ptrs.size(), sc.data());
    if (rc != 0) se::fail(SE_ERR_INVALID_ARG, "llama_set_adapters_lora failed (" + std::to_string(rc) + ")");
    if (changed) {
      // KV computed under adapter set A is wrong under set B (the server clears its slots too,
      // tools/server/server-context.cpp:1689-1703).
      S.clear_kv();
    }
    S.loras       = std::move(set);
    S.lora_scales = std::move(sc);
    return SE_OK;
  });
}

}  // extern "C"
