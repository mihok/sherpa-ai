// Media input (ABI 1.1): image content parts in chat requests -> media markers in the rendered prompt ->
// mtmd chunks -> a PromptPlan whose image positions carry pseudo tokens (see sherpa_engine.h "Media input").
#include "se_internal.h"

#include <cctype>

namespace se {

namespace {

int base64_value(unsigned char c) {
  if (c >= 'A' && c <= 'Z') return c - 'A';
  if (c >= 'a' && c <= 'z') return c - 'a' + 26;
  if (c >= '0' && c <= '9') return c - '0' + 52;
  if (c == '+' || c == '-') return 62;  // standard and URL-safe alphabets
  if (c == '/' || c == '_') return 63;
  return -1;
}

// Strict enough to reject garbage, lenient about padding and whitespace (line-wrapped base64).
bool base64_decode(const std::string & in, size_t from, std::string & out) {
  out.clear();
  out.reserve((in.size() - from) / 4 * 3 + 3);
  uint32_t acc = 0;
  int      bits = 0;
  bool     padding = false;
  for (size_t i = from; i < in.size(); ++i) {
    const unsigned char c = (unsigned char) in[i];
    if (c == '=') {
      padding = true;
      continue;
    }
    if (std::isspace(c)) continue;
    const int v = base64_value(c);
    if (v < 0 || padding) return false;
    acc = (acc << 6) | (uint32_t) v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.push_back((char) ((acc >> bits) & 0xFF));
    }
  }
  return !out.empty();
}

// "data:image/png;base64,...." -> bytes. Remote URLs are refused: the engine never touches the network.
std::string decode_data_url(const std::string & url) {
  if (url.rfind("data:", 0) != 0) {
    fail(SE_ERR_INVALID_ARG, "image_url must be a data: URL with base64 image bytes (the engine does not fetch URLs)");
  }
  const size_t comma = url.find(',');
  if (comma == std::string::npos) fail(SE_ERR_INVALID_ARG, "malformed data: URL in image_url");
  const std::string meta = url.substr(5, comma - 5);
  if (meta.size() < 7 || meta.compare(meta.size() - 7, 7, ";base64") != 0) {
    fail(SE_ERR_INVALID_ARG, "image_url data: URL must be base64 encoded");
  }
  if (meta.rfind("image/", 0) != 0) fail(SE_ERR_INVALID_ARG, "image_url data: URL is not an image (" + meta + ")");
  std::string bytes;
  if (!base64_decode(url, comma + 1, bytes)) fail(SE_ERR_INVALID_ARG, "image_url data: URL has invalid base64");
  return bytes;
}

// Why this model cannot take images, or "" when it can.
std::string media_refusal(const ModelImpl & m) {
#if SE_HAVE_MTMD
  if (m.mtmd == nullptr) return "this model has no vision projector loaded (se_model_params.mmproj_path)";
  if (!m.image_input) return "the loaded projector has no vision encoder";
  return "";
#else
  (void) m;
  return "this engine was built without multimodal support (SHERPA_ENGINE_MTMD)";
#endif
}

// SHA-256 hex (mtmd's bitmap id) -> a pseudo token <= k_media_token_max. 28 bits of the hash: equal images
// map to equal tokens; a collision only costs a wrong cache hit between two different images at the same
// position in the same conversation (2^-28).
llama_token media_token(const std::string & id) {
  uint32_t h = 0;
  size_t   used = 0;
  for (char c : id) {
    int v = -1;
    if (c >= '0' && c <= '9') v = c - '0';
    else if (c >= 'a' && c <= 'f') v = c - 'a' + 10;
    else if (c >= 'A' && c <= 'F') v = c - 'A' + 10;
    if (v < 0) continue;
    h = (h << 4) | (uint32_t) v;
    if (++used == 7) break;
  }
  if (used == 0) {  // no id: FNV-1a over whatever we have
    h = 2166136261u;
    for (char c : id) h = (h ^ (uint8_t) c) * 16777619u;
    h &= 0x0FFFFFFFu;
  }
  return k_media_token_max - (llama_token) h;
}

}  // namespace

// Replaces every image content part in `messages` with a media-marker part and collects the image bytes in
// marker order. Called on the request JSON before common_chat_msgs_parse_oaicompat (which only knows text
// and media_marker parts).
void extract_media(const ModelImpl & m, common_json & messages, const std::vector<MediaRef> * ext,
                   std::vector<std::string> & out) {
  if (!messages.is_array()) return;
  for (auto & msg : messages) {
    if (!msg.is_object() || !msg.contains("content")) continue;
    common_json & content = msg["content"];
    if (!content.is_array()) continue;
    for (auto & part : content) {
      if (!part.is_object() || !part.contains("type") || !part.at("type").is_string()) continue;
      const std::string type = part.at("type").get<std::string>();
      if (type != "image_url" && type != "media") continue;
      const std::string why = media_refusal(m);
      if (!why.empty()) fail(SE_ERR_UNSUPPORTED, "the request contains an image but " + why);
      if (type == "image_url") {
        const common_json iu = part.value("image_url", common_json::object());
        if (!iu.is_object() || !iu.contains("url") || !iu.at("url").is_string()) {
          fail(SE_ERR_INVALID_ARG, "image_url part needs image_url.url");
        }
        out.push_back(decode_data_url(iu.at("url").get<std::string>()));
      } else {
        if (!part.contains("index") || !part.at("index").is_number_integer()) {
          fail(SE_ERR_INVALID_ARG, "media part needs an integer 'index'");
        }
        const long long idx = part.at("index").get<long long>();
        if (!ext || idx < 0 || idx >= (long long) ext->size()) {
          fail(SE_ERR_INVALID_ARG, "media index " + std::to_string(idx) + " is out of range (" +
                                       std::to_string(ext ? ext->size() : 0) + " media given)");
        }
        const MediaRef & r = (*ext)[(size_t) idx];
        if (r.type != SE_MEDIA_IMAGE) fail(SE_ERR_INVALID_ARG, "media " + std::to_string(idx) + " is not an image");
        out.emplace_back(reinterpret_cast<const char *>(r.data), r.size);
      }
      part = common_json{{"type", "media_marker"}, {"text", m.media_marker}};
    }
  }
}

size_t PromptPlan::cells_before(size_t pos) const {
  size_t cells = pos;
  for (const auto & s : spans) {
    if (s.end > pos) break;
    cells = cells - (s.end - s.begin) + s.n_tokens;
  }
  return cells;
}

PromptPlan build_prompt(const ModelImpl & m, const std::string & prompt, const std::vector<std::string> & media) {
  PromptPlan plan;
  if (media.empty()) {
    plan.tokens  = tokenize_prompt(m.vocab, prompt, true);
    plan.n_cells = plan.tokens.size();
    return plan;
  }
#if SE_HAVE_MTMD
  const std::string why = media_refusal(m);
  if (!why.empty()) fail(SE_ERR_UNSUPPORTED, "the request contains an image but " + why);
  mtmd::bitmaps bitmaps;
  for (size_t i = 0; i < media.size(); ++i) {
    const auto & b = media[i];
    mtmd_helper_bitmap_wrapper w = mtmd_helper_bitmap_init_from_buf(
        m.mtmd, reinterpret_cast<const unsigned char *>(b.data()), b.size(), false, mtmd_helper_init_opt_default());
    if (w.video_ctx) mtmd_helper_video_free(w.video_ctx);
    if (w.bitmap == nullptr) {
      fail(SE_ERR_INVALID_ARG, "image " + std::to_string(i) + " could not be decoded (" + std::to_string(b.size()) +
                                   " bytes; JPEG, PNG, BMP and GIF are supported)");
    }
    mtmd::bitmap bm(w.bitmap);
    if (mtmd_bitmap_is_audio(w.bitmap)) fail(SE_ERR_INVALID_ARG, "media " + std::to_string(i) + " is audio, not an image");
    bitmaps.entries.push_back(std::move(bm));
  }
  // Like tokenize_prompt: no add_special (that would append EOS for add_eos vocabs), BOS prepended below.
  mtmd_input_text text{prompt.c_str(), prompt.size(), /*add_special*/ false, /*parse_special*/ true};
  plan.chunks.reset(mtmd_input_chunks_init());
  auto ptrs = bitmaps.c_ptr();
  const int32_t rc = mtmd_tokenize(m.mtmd, plan.chunks.get(), &text, ptrs.data(), ptrs.size());
  if (rc == 1) fail(SE_ERR_TEMPLATE, "the chat template dropped or duplicated an image marker");
  if (rc != 0) fail(SE_ERR_INVALID_ARG, "image preprocessing failed (mtmd_tokenize returned " + std::to_string(rc) + ")");

  if (llama_vocab_get_add_bos(m.vocab)) {
    const llama_token bos = llama_vocab_bos(m.vocab);
    bool has_bos = false;
    const size_t n_chunks = mtmd_input_chunks_size(plan.chunks.get());
    if (n_chunks > 0 && mtmd_input_chunk_get_type(plan.chunk(0)) == MTMD_INPUT_CHUNK_TYPE_TEXT) {
      size_t n = 0;
      const llama_token * t = mtmd_input_chunk_get_tokens_text(plan.chunk(0), &n);
      has_bos = n > 0 && t[0] == bos;
    }
    if (bos != LLAMA_TOKEN_NULL && !has_bos) {
      plan.tokens.push_back(bos);
      plan.n_cells++;
    }
  }
  const size_t n_chunks = mtmd_input_chunks_size(plan.chunks.get());
  for (size_t i = 0; i < n_chunks; ++i) {
    const mtmd_input_chunk * c = plan.chunk(i);
    if (mtmd_input_chunk_get_type(c) == MTMD_INPUT_CHUNK_TYPE_TEXT) {
      size_t n = 0;
      const llama_token * t = mtmd_input_chunk_get_tokens_text(c, &n);
      plan.tokens.insert(plan.tokens.end(), t, t + n);
      plan.n_cells += n;
      continue;
    }
    if (mtmd_input_chunk_get_type(c) != MTMD_INPUT_CHUNK_TYPE_IMAGE) {
      fail(SE_ERR_UNSUPPORTED, "only image media chunks are supported");
    }
    const llama_pos n_pos = mtmd_input_chunk_get_n_pos(c);
    const char *    id    = mtmd_input_chunk_get_id(c);
    PromptPlan::Span s;
    s.begin    = plan.tokens.size();
    s.end      = s.begin + (size_t) std::max<llama_pos>(n_pos, 1);
    s.n_tokens = mtmd_input_chunk_get_n_tokens(c);
    s.chunk    = i;
    plan.tokens.resize(s.end, media_token(id ? id : ""));
    plan.n_cells += s.n_tokens;
    plan.spans.push_back(s);
  }
  return plan;
#else
  (void) prompt;
  fail(SE_ERR_UNSUPPORTED, "the request contains an image but " + media_refusal(m));
#endif
}

}  // namespace se
