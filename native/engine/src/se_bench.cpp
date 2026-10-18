// Quick llama-bench-style measurement for first-run autotune: prompt processing (pp) from an empty KV and
// token generation (tg) one token per decode, on a throwaway context with the requested shape.
#include "se_internal.h"

namespace se {
namespace {

bool bench_abort(void * data) {
  auto * c = static_cast<se_canceller *>(data);
  return c && c->flag.load(std::memory_order_relaxed);
}

}  // namespace
}  // namespace se

extern "C" {

SE_API se_status se_bench(se_model * m, const se_bench_params * p, se_bench_result * out) {
  return se::guard(__func__, [&]() -> se_status {
    if (!m || !out) se::fail(SE_ERR_INVALID_ARG, "model/out is NULL");
    if (m->impl->vocab_only) se::fail(SE_ERR_UNSUPPORTED, "vocab-only model");
    se_bench_params bp = se::read_params(p, se_bench_params_init);
    if (bp.n_prompt == 0) bp.n_prompt = 128;
    if (bp.n_gen == 0) bp.n_gen = 32;
    if (bp.n_reps == 0) bp.n_reps = 2;
    if (bp.n_prompt < 1 || bp.n_gen < 1 || bp.n_reps < 1 || bp.n_reps > 100) se::fail(SE_ERR_INVALID_ARG, "invalid bench sizes");

    se_session_params sp;
    se_session_params_init(&sp);
    sp.n_ctx           = bp.n_ctx ? bp.n_ctx : (uint32_t) (bp.n_prompt + bp.n_gen + 16);
    sp.n_batch         = bp.n_batch;
    sp.n_ubatch        = bp.n_ubatch;
    sp.n_threads       = bp.n_threads;
    sp.n_threads_batch = bp.n_threads_batch;
    sp.type_k          = bp.type_k;
    sp.type_v          = bp.type_v;
    sp.flash_attn      = bp.flash_attn;
    const se::ResolvedSessionParams rp = se::resolve_session_params(m->impl->model, false, false, sp);
    llama_context_params cp = rp.cp;
    cp.abort_callback      = se::bench_abort;
    cp.abort_callback_data = bp.cancel;

    se::ThreadPools pools;  // declared first: destroyed after the context that uses it
    struct CtxDel { void operator()(llama_context * c) const { llama_free(c); } };
    std::unique_ptr<llama_context, CtxDel> ctx(llama_init_from_model(m->impl->model, cp));
    if (!ctx) se::fail(SE_ERR_CONTEXT_CREATE, "bench context creation failed (see log)");
    if ((uint32_t) (bp.n_prompt + bp.n_gen) > llama_n_ctx_seq(ctx.get())) se::fail(SE_ERR_INVALID_ARG, "n_ctx too small for n_prompt + n_gen");
    if (pools.reset(rp.p.n_threads, rp.p.n_threads_batch)) pools.attach(ctx.get());

    const uint32_t n_batch = llama_n_batch(ctx.get());
    const int32_t  n_vocab = llama_vocab_n_tokens(m->impl->vocab);
    uint64_t rng = 42;
    std::vector<llama_token> toks((size_t) bp.n_prompt);
    for (auto & t : toks) {
      rng = rng * 6364136223846793005ull + 1442695040888963407ull;
      t = (llama_token) ((rng >> 33) % (uint64_t) n_vocab);
    }
    llama_memory_t mem = llama_get_memory(ctx.get());
    auto cancelled = [&] { return bp.cancel && bp.cancel->flag.load(); };
    auto decode = [&](common_batch & b) {
      const int32_t rc = llama_process(ctx.get(), LLAMA_PROCESS_TYPE_DECODE, b.get());
      if (rc == 2 || cancelled()) se::fail(SE_ERR_CANCELLED, "bench cancelled");
      if (rc != 0) se::fail(SE_ERR_DECODE, "bench decode failed (" + std::to_string(rc) + ")");
    };

    double pp_ms = 0, tg_ms = 0;
    int    measured = 0;
    common_batch batch(ctx.get());
    for (int rep = 0; rep < bp.n_reps; ++rep) {
      const bool warmup = bp.n_reps > 1 && rep == 0;
      // pp
      llama_memory_clear(mem, true);
      auto t0 = se::Clock::now();
      for (int32_t i = 0; i < bp.n_prompt; i += (int32_t) n_batch) {
        const int32_t e = std::min<int32_t>(bp.n_prompt, i + (int32_t) n_batch);
        batch.clear();
        for (int32_t k = i; k < e; ++k) batch.add(toks[(size_t) k], k, 0, k == bp.n_prompt - 1);
        decode(batch);
      }
      llama_synchronize(ctx.get());
      const double pp = se::ms_since(t0);
      // tg (after the prompt, like a real reply)
      t0 = se::Clock::now();
      for (int32_t i = 0; i < bp.n_gen; ++i) {
        batch.clear();
        batch.add(toks[(size_t) i % toks.size()], bp.n_prompt + i, 0, true);
        decode(batch);
        llama_synchronize(ctx.get());
      }
      const double tg = se::ms_since(t0);
      if (!warmup) {
        pp_ms += pp;
        tg_ms += tg;
        ++measured;
      }
    }
    se_bench_result r{};
    r.struct_size = sizeof r;
    r.n_prompt    = bp.n_prompt;
    r.n_gen       = bp.n_gen;
    r.n_threads   = rp.p.n_threads;
    r.pp_ms       = pp_ms / measured;
    r.tg_ms       = tg_ms / measured;
    r.pp_tps      = r.pp_ms > 0 ? bp.n_prompt * 1000.0 / r.pp_ms : 0;
    r.tg_tps      = r.tg_ms > 0 ? bp.n_gen * 1000.0 / r.tg_ms : 0;
    se::write_out(out, r);
    return SE_OK;
  });
}

}  // extern "C"
