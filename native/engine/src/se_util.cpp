// Small helpers: UTF-8, fingerprints, token text, JSON.
#include "se_internal.h"

#include "ggml.h"
#include "hash/hash.h"

#include <cstdio>
#include <fstream>

namespace se {

size_t utf8_complete_prefix(const std::string & s) {
  // Token pieces can end in the middle of a multi-byte sequence (R04 §7: a 7-byte emoji arrived as 4+3
  // byte pieces). Find the start of the last (possibly partial) sequence and check whether it is complete.
  const size_t n = s.size();
  size_t i = n;
  int back = 0;
  while (i > 0 && back < 4) {
    const unsigned char c = (unsigned char) s[i - 1];
    if ((c & 0xC0) != 0x80) {  // lead byte or ASCII
      size_t need = 1;
      if ((c & 0x80) == 0) need = 1;
      else if ((c & 0xE0) == 0xC0) need = 2;
      else if ((c & 0xF0) == 0xE0) need = 3;
      else if ((c & 0xF8) == 0xF0) need = 4;
      else return n;  // invalid lead byte: let it through, the parser treats it as bytes
      return (n - (i - 1) >= need) ? n : i - 1;
    }
    --i;
    ++back;
  }
  return n;  // 4+ continuation bytes in a row: invalid UTF-8, do not hold it back forever
}

uint64_t file_size_or_zero(const std::string & path) {
  std::ifstream f(path, std::ios::binary | std::ios::ate);
  if (!f) return 0;
  const auto pos = f.tellg();
  return pos < 0 ? 0 : (uint64_t) pos;
}

std::string quick_fingerprint(const std::string & path, uint64_t * size_out) {
  // sha256(size || first MiB || last MiB): cheap (2 MiB of I/O on a phone) and enough to tell different
  // files apart. Callers that know the real sha256 (the download manager verifies it) pass model_id.
  std::ifstream f(path, std::ios::binary | std::ios::ate);
  if (!f) fail(SE_ERR_IO, "cannot open " + path);
  const auto end = f.tellg();
  const uint64_t size = end < 0 ? 0 : (uint64_t) end;
  if (size_out) *size_out = size;
  const uint64_t chunk = 1u << 20;
  std::string buf(8, '\0');
  for (int i = 0; i < 8; ++i) buf[i] = (char) ((size >> (8 * i)) & 0xFF);
  auto read_at = [&](uint64_t off, uint64_t len) {
    std::string tmp(len, '\0');
    f.seekg((std::streamoff) off);
    f.read(&tmp[0], (std::streamsize) len);
    tmp.resize((size_t) f.gcount());
    f.clear();
    buf += tmp;
  };
  read_at(0, std::min(chunk, size));
  if (size > chunk) read_at(size - std::min(chunk, size - chunk), std::min(chunk, size - chunk));
  return "qfp1:" + hash_sha256_hex(buf.data(), buf.size());
}

std::string ggml_type_label(int32_t t) {
  if (t < 0 || t >= GGML_TYPE_COUNT) return "invalid";
  const char * n = ggml_type_name((ggml_type) t);
  return n ? n : "invalid";
}

bool is_quantized_kv(int32_t t) {
  return t >= 0 && t < GGML_TYPE_COUNT && ggml_is_quantized((ggml_type) t);
}

std::string random_id(uint64_t & state, size_t n) {
  static const char k_alpha[] = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
  std::string out;
  out.reserve(n);
  for (size_t i = 0; i < n; ++i) {
    // splitmix64: deterministic per session/seed, so greedy test runs produce stable tool-call ids.
    uint64_t z = (state += 0x9E3779B97F4A7C15ull);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
    z ^= z >> 31;
    out += k_alpha[z % (sizeof(k_alpha) - 1)];
  }
  return out;
}

std::vector<llama_token> tokenize_prompt(const llama_vocab * vocab, const std::string & text, bool add_bos) {
  // Templated prompts: common_chat_templates_apply strips a leading BOS *text* when the vocab adds BOS
  // itself (common/chat.cpp:959) and a trailing EOS when it adds EOS. The server then tokenizes with
  // add_special=true (tools/server/server-context.cpp:4280), which would also append EOS for add_eos
  // vocabs; we tokenize without specials and prepend BOS ourselves. parse_special=true maps the
  // template's control-token text (<|im_start|>, <tool_call>, ...) to single ids (R04 §7).
  std::vector<llama_token> toks = common_tokenize(vocab, text, /*add_special*/ false, /*parse_special*/ true);
  if (add_bos && llama_vocab_get_add_bos(vocab)) {
    const llama_token bos = llama_vocab_bos(vocab);
    if (bos != LLAMA_TOKEN_NULL && (toks.empty() || toks.front() != bos)) {
      toks.insert(toks.begin(), bos);
    }
  }
  return toks;
}

std::string token_piece(const llama_vocab * vocab, llama_token tok, bool special) {
  // llama_token_to_piece throws std::out_of_range for ids outside the vocab (llama-vocab.cpp:3688-3692).
  if (tok < 0 || tok >= llama_vocab_n_tokens(vocab)) {
    fail(SE_ERR_INVALID_ARG, "token id " + std::to_string(tok) + " out of range");
  }
  return common_token_to_piece(vocab, tok, special);
}

common_json parse_json_object(const char * text, const char * what) {
  if (text == nullptr) fail(SE_ERR_INVALID_ARG, std::string(what) + " is NULL");
  common_json j = common_json::parse_no_throw(text);
  if (j.is_discarded() || !j.is_object()) {
    fail(SE_ERR_INVALID_ARG, std::string(what) + " is not a JSON object");
  }
  return j;
}

}  // namespace se
