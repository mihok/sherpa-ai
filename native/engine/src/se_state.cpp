// Prompt-cache persistence: per-sequence KV state + token history behind a Sherpa header.
//
// llama.cpp's own state validation is weak: it checks layer count, cell count, K/V types and the V layout
// (src/llama-kv-cache.cpp:2549-2577) and the arch name for whole-context state, but nothing about the
// weights, the LoRA set or rope parameters (R04 §13, §22). A stale snapshot loaded into another fine-tune
// of the same shape would "work" and produce garbage, so every file carries an identity header that is
// checked before llama.cpp sees a byte.
//
// File layout (little-endian):
//   "SHRPKV01" | u32 header_len | header JSON | u32 n_tokens | i32 tokens[n] | u64 state_len | state bytes
// The state bytes are exactly llama_state_seq_get_data(ctx, seq 0). They are written into and read from a
// memory-mapped file, so saving/loading a few hundred MB of KV does not need the same amount of heap.
#include "se_internal.h"

#include <cstdio>
#include <fstream>

#if defined(_WIN32)
#  define SE_NO_MMAP 1
#else
#  include <fcntl.h>
#  include <sys/mman.h>
#  include <sys/stat.h>
#  include <unistd.h>
#endif

namespace se {

namespace {

constexpr char     k_magic[8]       = {'S', 'H', 'R', 'P', 'K', 'V', '0', '1'};
constexpr uint32_t k_max_header_len = 1u << 20;

common_json state_identity(const SessionImpl & s) {
  const llama_model * m = s.model->model;
  common_json h = common_json::object();
  h["format"]       = 1;
  h["engine_abi"]   = (int) SE_ABI_VERSION;
  h["engine"]       = SE_ENGINE_VERSION;
  h["llama_commit"] = SE_LLAMA_COMMIT;
  h["model_id"]     = s.model->model_id;
  h["fingerprint"]  = s.model->fingerprint;
  h["n_params"]     = (uint64_t) llama_model_n_params(m);
  h["n_layer"]      = llama_model_n_layer(m);
  h["n_embd"]       = llama_model_n_embd(m);
  h["n_vocab"]      = llama_vocab_n_tokens(s.model->vocab);
  h["type_k"]       = ggml_type_label(s.params.type_k);
  h["type_v"]       = ggml_type_label(s.params.type_v);
  h["flash_attn"]   = s.flash_attn_resolved;  // decides the V layout (transposed without FA)
  h["swa_full"]     = s.params.swa_full != 0;
  common_json loras = common_json::array();
  for (size_t i = 0; i < s.loras.size(); ++i) {
    common_json o = common_json::object();
    o["fingerprint"] = s.loras[i]->fingerprint;
    o["scale"]       = s.lora_scales[i];
    loras.push_back(o);
  }
  h["loras"] = loras;
  return h;
}

// Every key of the identity must match exactly; n_ctx may differ as long as the tokens fit.
void check_identity(const common_json & want, const common_json & got) {
  for (const auto & item : want.items()) {
    const std::string & k = item.key();
    if (k == "engine") continue;  // informational
    if (!got.contains(k)) fail(SE_ERR_STATE_MISMATCH, "state file lacks '" + k + "'");
    const common_json & a = item.value();
    const common_json & b = got.at(k);
    if (k == "flash_attn" && (a.get<int>() < 0 || b.get<int>() < 0)) continue;  // unknown: llama checks v_trans
    if (a.dump() != b.dump()) {
      fail(SE_ERR_STATE_MISMATCH, "state file was saved with " + k + "=" + b.dump() + ", this session has " + a.dump());
    }
  }
}

template <class T>
void put(std::string & buf, const T & v) {
  buf.append(reinterpret_cast<const char *>(&v), sizeof v);
}

struct Fd {
  int fd = -1;
  ~Fd() { if (fd >= 0) ::close(fd); }
};

}  // namespace

}  // namespace se

extern "C" {

SE_API se_status se_state_save(se_session * s, const char * path) {
  return se::guard(__func__, [&]() -> se_status {
    if (!s || !path || !*path) se::fail(SE_ERR_INVALID_ARG, "session/path is NULL");
    auto & S = *s->impl;
    se::BusyScope busy(S);

    common_json h = se::state_identity(S);
    h["n_ctx"]    = S.n_ctx_seq;
    h["n_tokens"] = (uint64_t) S.history.size();
    const std::string hj = h.dump_safe();

    std::string prefix(se::k_magic, sizeof se::k_magic);
    se::put(prefix, (uint32_t) hj.size());
    prefix += hj;
    se::put(prefix, (uint32_t) S.history.size());
    prefix.append(reinterpret_cast<const char *>(S.history.data()), S.history.size() * sizeof(llama_token));
    const uint64_t state_len = S.history.empty() ? 0 : (uint64_t) llama_state_seq_get_size(S.ctx, 0);
    se::put(prefix, state_len);

    const std::string tmp = std::string(path) + ".tmp";
#if SE_NO_MMAP
    std::vector<uint8_t> state(state_len);
    if (state_len && llama_state_seq_get_data(S.ctx, state.data(), state.size(), 0) != state_len) {
      se::fail(SE_ERR_INTERNAL, "llama_state_seq_get_data returned a short read");
    }
    {
      std::ofstream f(tmp, std::ios::binary | std::ios::trunc);
      f.write(prefix.data(), (std::streamsize) prefix.size());
      f.write(reinterpret_cast<const char *>(state.data()), (std::streamsize) state.size());
      if (!f) se::fail(SE_ERR_IO, "cannot write " + tmp);
    }
#else
    {
      se::Fd fd;
      fd.fd = ::open(tmp.c_str(), O_RDWR | O_CREAT | O_TRUNC, 0600);
      if (fd.fd < 0) se::fail(SE_ERR_IO, "cannot create " + tmp);
      const uint64_t total = prefix.size() + state_len;
      if (::ftruncate(fd.fd, (off_t) total) != 0) se::fail(SE_ERR_IO, "cannot size " + tmp + " (disk full?)");
      void * map = ::mmap(nullptr, (size_t) total, PROT_READ | PROT_WRITE, MAP_SHARED, fd.fd, 0);
      if (map == MAP_FAILED) se::fail(SE_ERR_IO, "cannot map " + tmp);
      auto * base = static_cast<uint8_t *>(map);
      std::memcpy(base, prefix.data(), prefix.size());
      size_t wr = state_len;
      if (state_len) wr = llama_state_seq_get_data(S.ctx, base + prefix.size(), (size_t) state_len, 0);
      const int sync_rc = ::msync(map, (size_t) total, MS_SYNC);
      ::munmap(map, (size_t) total);
      if (wr != state_len) {
        ::unlink(tmp.c_str());
        se::fail(SE_ERR_INTERNAL, "llama_state_seq_get_data wrote " + std::to_string(wr) + " of " + std::to_string(state_len) + " bytes");
      }
      if (sync_rc != 0) {
        ::unlink(tmp.c_str());
        se::fail(SE_ERR_IO, "cannot flush " + tmp);
      }
    }
#endif
    if (std::rename(tmp.c_str(), path) != 0) {
      std::remove(tmp.c_str());
      se::fail(SE_ERR_IO, std::string("cannot rename state file to ") + path);
    }
    return SE_OK;
  });
}

SE_API se_status se_state_load(se_session * s, const char * path, int32_t * n_tokens_out) {
  return se::guard(__func__, [&]() -> se_status {
    if (!s || !path || !*path) se::fail(SE_ERR_INVALID_ARG, "session/path is NULL");
    auto & S = *s->impl;
    se::BusyScope busy(S);

    std::ifstream f(path, std::ios::binary | std::ios::ate);
    if (!f) se::fail(SE_ERR_IO, std::string("cannot open ") + path);
    const uint64_t file_len = (uint64_t) f.tellg();
    f.seekg(0);
    auto read_exact = [&](void * dst, size_t n) {
      f.read(static_cast<char *>(dst), (std::streamsize) n);
      if ((size_t) f.gcount() != n) se::fail(SE_ERR_STATE_MISMATCH, "truncated state file");
    };
    char magic[8];
    read_exact(magic, sizeof magic);
    if (std::memcmp(magic, se::k_magic, sizeof magic) != 0) se::fail(SE_ERR_STATE_MISMATCH, "not a Sherpa state file");
    uint32_t hlen = 0;
    read_exact(&hlen, sizeof hlen);
    if (hlen == 0 || hlen > se::k_max_header_len) se::fail(SE_ERR_STATE_MISMATCH, "corrupt state header");
    std::string hj(hlen, '\0');
    read_exact(&hj[0], hlen);
    const common_json got = common_json::parse_no_throw(hj);
    if (got.is_discarded() || !got.is_object()) se::fail(SE_ERR_STATE_MISMATCH, "corrupt state header");
    se::check_identity(se::state_identity(S), got);

    uint32_t n_tokens = 0;
    read_exact(&n_tokens, sizeof n_tokens);
    if (n_tokens > S.n_ctx_seq) {
      se::fail(SE_ERR_STATE_MISMATCH, "state holds " + std::to_string(n_tokens) + " tokens, this session's context is " +
                                          std::to_string(S.n_ctx_seq));
    }
    std::vector<llama_token> tokens(n_tokens);
    if (n_tokens) read_exact(tokens.data(), n_tokens * sizeof(llama_token));
    const int32_t n_vocab = llama_vocab_n_tokens(S.model->vocab);
    for (const llama_token t : tokens) {
      if (t < 0 || t >= n_vocab) se::fail(SE_ERR_STATE_MISMATCH, "state file contains invalid token ids");
    }
    uint64_t state_len = 0;
    read_exact(&state_len, sizeof state_len);
    const uint64_t state_off = (uint64_t) f.tellg();
    if (state_off + state_len != file_len) se::fail(SE_ERR_STATE_MISMATCH, "state length does not match the file size");
    if ((n_tokens == 0) != (state_len == 0)) se::fail(SE_ERR_STATE_MISMATCH, "inconsistent state file");
    f.close();

    // From here on the session's cache is replaced; if llama.cpp rejects the bytes it stays empty.
    S.clear_kv();
    if (n_tokens) {
      size_t rd = 0;
#if SE_NO_MMAP
      std::vector<uint8_t> data(state_len);
      std::ifstream g(path, std::ios::binary);
      g.seekg((std::streamoff) state_off);
      g.read(reinterpret_cast<char *>(data.data()), (std::streamsize) state_len);
      rd = llama_state_seq_set_data(S.ctx, data.data(), data.size(), 0);
#else
      se::Fd fd;
      fd.fd = ::open(path, O_RDONLY);
      if (fd.fd < 0) se::fail(SE_ERR_IO, std::string("cannot open ") + path);
      void * map = ::mmap(nullptr, (size_t) file_len, PROT_READ, MAP_PRIVATE, fd.fd, 0);
      if (map == MAP_FAILED) se::fail(SE_ERR_IO, std::string("cannot map ") + path);
      rd = llama_state_seq_set_data(S.ctx, static_cast<const uint8_t *>(map) + state_off, (size_t) state_len, 0);
      ::munmap(map, (size_t) file_len);
#endif
      if (rd == 0) {
        S.clear_kv();
        se::fail(SE_ERR_STATE_MISMATCH, "llama.cpp rejected the KV state (layer/cell/type/layout check, see log)");
      }
      const llama_pos pmax = llama_memory_seq_pos_max(llama_get_memory(S.ctx), 0);
      if (pmax + 1 != (llama_pos) n_tokens) {
        S.clear_kv();
        se::fail(SE_ERR_STATE_MISMATCH, "restored KV covers " + std::to_string(pmax + 1) + " positions, header says " +
                                            std::to_string(n_tokens));
      }
      // No logits are restored (llama-context.cpp:3397-3440). The next generation re-decodes at least
      // the last prompt token before sampling (see run_generation), which is the "replay last token" step.
      S.history = std::move(tokens);
    }
    if (n_tokens_out) *n_tokens_out = (int32_t) n_tokens;
    return SE_OK;
  });
}

}  // extern "C"
