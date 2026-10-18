# 10 — Remote model APIs: wire formats, streaming, tools, discovery

Research date: **2026-10-18**. Audience: implementers of `sherpa_core` remote providers (pure Dart, streaming,
tool calling). Everything below was checked against official docs or source fetched on the research date unless it
is marked **UNVERIFIED**. "Fixture" JSON in §9 is assembled from the documented schemas and from server source code.
IDs and token counts in fixtures are made up, so treat them as golden test inputs, not as captured traffic.

Sources used, all fetched 2026-10-18:

* Anthropic: `platform.claude.com/docs/en/**.md` (streaming, thinking, preserved-thinking, handling-stop-reasons,
  refusals-and-fallback, errors, rate-limits, api/messages/create, api/models/list, api/messages/count_tokens,
  context-editing, compaction, prompt-caching, vision, fine-grained-tool-streaming, parallel-tool-use, beta-headers,
  versioning, models/overview, openai-sdk), plus the bundled `claude-api` skill (cache date 2026-10-06).
* OpenAI: `developers.openai.com/api/**.md` (chat streaming-events reference, chat resource/create reference,
  function-calling, reasoning, latest-model, migrate-to-responses, error-codes, rate-limits, reference overview,
  models, responses create and streaming-events); `raw.githubusercontent.com/openai/openai-python` (stream
  accumulator `_deltas.py`, `_completions.py`). `platform.openai.com` returned 403, and the docs now live on
  developers.openai.com.
* llama.cpp: local source `/opt/vendor-src/llama-py/llama_cpp_python-0.3.36/vendor/llama.cpp/tools/server/*.cpp`,
  cross-checked against upstream `raw.githubusercontent.com/ggml-org/llama.cpp/master/tools/server/{README.md,
  server-chat.cpp,server-context.cpp,server-common.cpp}`, `common/{arg.cpp,chat.cpp}`.
* Ollama: `docs.ollama.com/{api/openai-compatibility,context-length,api-reference/show-model-details}.md`,
  `raw.githubusercontent.com/ollama/ollama/main/{docs/api.md,openai/openai.go,api/types.go}`.
* LM Studio: `lmstudio.ai/docs/developer/**.md`, `lmstudio.ai/llms-full.txt`.
* vLLM: `raw.githubusercontent.com/vllm-project/vllm/main/docs/features/{reasoning_outputs,tool_calling}.md`,
  `vllm/entrypoints/openai/chat_completion/protocol.py`, `vllm/entrypoints/serve/{engine/protocol.py,
  instrumentator/basic.py}`.
* OpenRouter: `openrouter.ai/docs/{guides/best-practices/reasoning-tokens,api/reference/streaming,
  api/reference/errors-and-debugging,guides/overview/models}.md`.
* DeepSeek: `api-docs.deepseek.com/guides/thinking_mode`. HF: `huggingface.co/docs/inference-providers/index.md`
  and a live `GET https://router.huggingface.co/v1/models`.

---

## 0. TL;DR: the facts that change the design

1. **OpenAI first-party has moved tool calling to the Responses API.** "GPT-6 Astra and GPT-6.1 Sol support Chat
   Completions, but tool calling requires Responses. GPT-6 Sol and GPT-6 Luna support function calling in Chat
   Completions only with `reasoning_effort: "none"`." Also: "Starting with GPT-5.4, Chat Completions does not
   support tool calling with `reasoning_effort` values other than `none`." For an agent harness, Chat Completions on
   `api.openai.com` is effectively no-reasoning-only. If OpenAI first-party is in v1 scope, a Responses adapter is
   required. Chat Completions stays the lingua franca for every *compatible* server.
2. **Anthropic "preserved thinking" makes the transcript append-only.** On Fable 5.1, Opus 5.5, Sonnet 5.5 and
   Haiku 5.5, **accounts created on or after 2026-08-31 get a 400** if `system`, `tools` or any earlier message changes
   before a replayed thinking block. That covers editing or truncating earlier tool results, adding or removing a
   tool, or re-rendering the system prompt. Sherpa's `ContextOverlay`/`PartRewrite`-style rewriting must not touch
   Anthropic history. See §7.9.
3. **Current Anthropic models reject several "classic" knobs with a 400.** Opus 5.5, Sonnet 5.5 and Fable 5.1 reject
   forced `tool_choice` (`any`/`tool`). All current 5.x and 4.7+ models reject non-default `temperature`/`top_p`/
   `top_k`. Opus 5.5 rejects `thinking: {type:"disabled"}` and `budget_tokens`, and thinking is always on. Sherpa's
   `ReasoningEffort` comment ("Anthropic budget_tokens") is stale. Use `output_config.effort` instead.
4. **The reasoning field name differs by server:** `reasoning_content` on DeepSeek and llama.cpp; `reasoning` on vLLM
   (renamed from `reasoning_content`; vLLM still accepts the old name on input), Ollama `/v1`, OpenRouter (plus
   `reasoning_details[]`) and LM Studio for gpt-oss. Parse both. On replay, write back the field you received.
   DeepSeek **400s** if `reasoning_content` is not passed back while `tools` are present.
5. **Context-window discovery is server-specific.** OpenAI's `/v1/models` has no context field. Anthropic
   `/v1/models` has `max_input_tokens`/`max_tokens`/`capabilities`. llama.cpp has `/props` →
   `default_generation_settings.n_ctx`. Ollama has `/api/show` `model_info["<arch>.context_length"]` (trained max) and
   `/api/ps` `context_length` (allocated). LM Studio has `/api/v1/models` `max_context_length` plus
   `loaded_instances[].config.context_length`. vLLM has `max_model_len`. OpenRouter has `context_length`. HF router
   has `providers[].context_length`.
6. **Tool-call merge must be defensive.** OpenAI streams `tool_calls[{index,id?,type?,function:{name?,arguments?}}]`
   fragments, and one chunk can hold several fragments for the same index (openai-python comment). Ollama and vLLM's
   `hf` parser emit each call **whole** in one chunk. LM Studio once appended an empty `name` after the first packet.
   llama.cpp ignores an object-form `tool_choice` and falls back to `auto`.

---

## 1. SSE framing: one parser for every provider

Rules that every target needs (WHATWG SSE plus observed server behavior):

* Decode bytes with a **streaming UTF-8 decoder** (multi-byte characters split across TCP chunks). Split lines on
  `\n`, `\r\n` or `\r` (Dart `LineSplitter` does all three).
* Field lines: `event:<v>`, `data:<v>`, `id:`, `retry:`. Strip **one** optional space after the colon. Some servers
  send `data:{...}` with no space.
* **Lines starting with `:` are comments. Ignore them.** Seen in practice: llama.cpp keep-alive `":\n\n"` (when
  `sse_ping_interval` > 0); OpenRouter `: OPENROUTER PROCESSING`.
* Multiple `data:` lines in one event are joined with `\n`. A blank line dispatches the event.
* **Terminators:** OpenAI-style Chat Completions ends with `data: [DONE]`. Anthropic ends with `event: message_stop`
  and sends **no** `[DONE]` (removed in `2023-06-01`). llama.cpp sends **no** `[DONE]` on its Responses or Anthropic
  endpoints. Whether OpenAI's own Responses sends `[DONE]` is **UNVERIFIED**, so terminate on
  `response.completed|failed|incomplete`.
* A socket that closes **without** the terminator, and without a finish_reason/stop_reason, is a truncated stream.
  Treat it as a retryable network error, but only auto-retry if nothing was emitted yet (§3.7).
* **Check status and content-type first.** With `stream: true`, errors detected before streaming starts come back as
  a normal JSON error body with a 4xx/5xx status, not SSE (OpenRouter documents this; Anthropic and OpenAI behave the
  same).
* **Mid-stream errors** (HTTP 200 already sent):
  * Anthropic: `event: error` / `data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}`
  * llama.cpp: `data: {"error":{"code":500,"message":"...","type":"server_error"}}`, then the stream ends with no
    `[DONE]`.
  * OpenRouter: a chunk with top-level `"error":{"code":...,"message":...,"metadata":{"error_type":...}}` and
    `choices[0].finish_reason:"error"`.
  * OpenAI Responses: `{"type":"error","code":..,"message":..,"param":..,"sequence_number":n}`, plus
    `response.failed`.
  * OpenAI Chat Completions mid-stream error shape: **UNVERIFIED**. Handle any data object that has a top-level
    `error` key.

---

## 2. Cross-server matrix (OpenAI-compatible Chat Completions)

| Server (default base) | Reasoning out (stream delta / message) | Reasoning back in history | Max tokens param | `tool_choice` | Usage chunk | Models + context |
|---|---|---|---|---|---|---|
| **OpenAI** `https://api.openai.com/v1` | not exposed in Chat (only `usage.completion_tokens_details.reasoning_tokens`) | n/a (use Responses for reasoning state) | `max_completion_tokens` (`max_tokens` deprecated, "not compatible with o-series") | `none`/`auto`/`required`/`{type:function,function:{name}}`/`{type:allowed_tools,...}`/custom | `stream_options.include_usage` → final chunk `choices: []` | `/v1/models`: `id, created, object, owned_by, shutdown_date`, **no context** |
| **llama.cpp** `http://host:8080/v1` | `delta.reasoning_content` (when `--reasoning-format` resolves to deepseek; default `auto`) | assistant `reasoning_content` (template-dependent) | `max_tokens` **or** `max_completion_tokens` (aliases of `n_predict`) | **string only**: `auto`/`none`/`required`. The object form is ignored (warning logged) → `auto` | yes, `choices: []` + `usage` + `timings` | `/v1/models` `owned_by:"llamacpp"`, `meta.n_ctx` (slot), `meta.n_ctx_train`; `/props` |
| **Ollama** `http://host:11434/v1` | `delta.reasoning` | assistant `reasoning` | `max_tokens` only (`max_completion_tokens` not parsed) | **not supported** | `stream_options` supported | `/v1/models` (`owned_by` = ollama user or `"library"`); context via `/api/show`, `/api/ps` |
| **LM Studio** `http://host:1234/v1` | `delta.reasoning` for gpt-oss (0.3.23+); `reasoning_content` for DeepSeek-R1 if the "separate reasoning_content" setting is on (0.3.9). Current default: **UNVERIFIED**, so parse both | **UNVERIFIED** | `max_tokens` (documented list) | `auto`/`none`/`required` (`required` "llama.cpp only", i.e. not MLX engine) | `stream_options.include_usage` (0.3.18+) | `/api/v1/models` (0.4+), `/api/v0/models` |
| **vLLM** `http://host:8000/v1` | `delta.reasoning` (renamed from `reasoning_content`) when `--reasoning-parser` set | accepts `reasoning` or `reasoning_content` (normalized) | both (`max_tokens` deprecated) | `auto` (needs `--enable-auto-tool-choice` + `--tool-call-parser`), `required`, named, `none` | yes (UNVERIFIED shape details) | `/v1/models` `owned_by:"vllm"`, `max_model_len` |
| **OpenRouter** `https://openrouter.ai/api/v1` | `delta.reasoning` + `delta.reasoning_details[]` | `reasoning_details` (preferred, unmodified) or `reasoning` (alias `reasoning_content`) | `max_tokens` / `max_completion_tokens` (shared budget) | provider-dependent (UNVERIFIED) | **always**; the usage chunk has a **non-empty** `choices` with a repeated `finish_reason` | `/api/v1/models`: `context_length`, `top_provider.max_completion_tokens`, `supported_parameters`, `reasoning{supported_efforts,...}` |
| **HF router** `https://router.huggingface.co/v1` | provider-dependent (UNVERIFIED) | UNVERIFIED | UNVERIFIED | UNVERIFIED | UNVERIFIED | `/v1/models`: `data[].providers[]{provider,status,context_length,supports_tools,supports_structured_output,...}`; model suffix `:fastest`/`:cheapest`/`:preferred`/`:<provider>` |
| **DeepSeek** `https://api.deepseek.com` | `delta.reasoning_content` | **must** pass back `reasoning_content` on all prior assistant turns when `tools` present, **else 400** | UNVERIFIED | UNVERIFIED | UNVERIFIED | UNVERIFIED |
| **Anthropic compat** `https://api.anthropic.com/v1/` (OpenAI SDK layer) | thinking via `thinking` extra param | — | `max_tokens`/`max_completion_tokens` | — | `stream_options` supported | Anthropic says the layer is for *testing*: `strict` ignored, `response_format` ignored, **no prompt caching**, system/developer messages hoisted and concatenated. **Use native Messages instead.** |

Notes:

* **Error code types differ.** OpenAI's `error.code` is a string or null. vLLM and llama.cpp send an **int** `code`
  (the HTTP status). OpenRouter sends either. Parse `code` as `Object?`.
* **`developer` vs `system` role:** OpenAI accepts both. llama.cpp maps `developer`→`system` (workaround in
  `common/chat.cpp`). Ollama and LM Studio handling of `developer` is **UNVERIFIED**. Send `system` to every compat
  server.
* **Tool results with images:** OpenAI Chat `role:"tool"` content is **text only** (`string | text parts`). Send tool
  images as a follow-up `user` message with `image_url` parts. Anthropic `tool_result.content` accepts image and
  document blocks. Responses `function_call_output.output` accepts `input_text|input_image|input_file`.
* **Parallel tool calls on local servers** depend on the model and template. llama.cpp defaults
  `parallel_tool_calls` from the template capability (`caps["supports_parallel_tool_calls"]`). vLLM: "Parallel tool
  calls are not supported for Llama 3", and Mistral 7B "struggles".

---

## 3. OpenAI Chat Completions (`POST {base}/chat/completions`)

### 3.1 Request (fields Sherpa needs)

```json
{
  "model": "gpt-6-luna",
  "messages": [
    {"role": "system", "content": "You are Sherpa."},
    {"role": "user", "content": [
      {"type": "text", "text": "What's in this photo?"},
      {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,/9j/4AAQ...", "detail": "auto"}}
    ]},
    {"role": "assistant", "content": null, "tool_calls": [
      {"id": "call_1", "type": "function", "function": {"name": "get_weather", "arguments": "{\"city\":\"Paris\"}"}}
    ]},
    {"role": "tool", "tool_call_id": "call_1", "content": "18°C, cloudy"}
  ],
  "tools": [{"type": "function", "function": {
    "name": "get_weather", "description": "Current weather for a city.",
    "parameters": {"type": "object", "properties": {"city": {"type": "string"}},
                   "required": ["city"], "additionalProperties": false},
    "strict": true}}],
  "tool_choice": "auto",
  "parallel_tool_calls": true,
  "max_completion_tokens": 4096,
  "reasoning_effort": "none",
  "response_format": {"type": "json_schema", "json_schema": {"name": "answer", "schema": {}, "strict": true}},
  "stream": true,
  "stream_options": {"include_usage": true, "include_obfuscation": false},
  "prompt_cache_key": "sherpa-session-<id>"
}
```

* **Content parts (user):** `text`; `image_url {url, detail: auto|low|high|original}`. `url` may be an https URL or
  a `data:image/...;base64,` URL. Also `input_audio {data, format: wav|mp3}` and
  `file {file_data|file_id, filename}`. Assistant content: `text` or `refusal` parts. Tool message: text only.
* **`tool_choice` forms:** `"none"`, `"auto"`, `"required"`, `{"type":"function","function":{"name":"x"}}`,
  `{"type":"allowed_tools","allowed_tools":{"mode":"auto"|"required","tools":[{"type":"function","function":{"name":"x"}}]}}`,
  `{"type":"custom","custom":{"name":"x"}}`. The default is `none` without tools and `auto` with tools.
* **`parallel_tool_calls: false`** means "exactly zero or one tool is called" (function-calling guide).
* **`reasoning_effort`:** `none|minimal|low|medium|high|xhigh|max`, model-dependent. GPT-6 Astra returns 400 on
  `none`. GPT-6.1 Sol rejects `none` and `minimal` and defaults to `medium`. When effort ≠ `none`, remove
  `temperature`, `top_p`, `top_logprobs`, `logprobs` (latest-model guide).
* **`max_tokens`** is deprecated in favor of `max_completion_tokens` (which includes reasoning tokens) and is not
  compatible with reasoning models. Which servers accept which: §2.
* **Caching (new, gpt-5.6+):** `prompt_cache_options {mode: implicit|explicit, ttl: "30m"}` plus per-part
  `prompt_cache_breakpoint: {"mode":"explicit"}` (up to 4 per request). `prompt_cache_retention` is deprecated.
  Optional for v1; `prompt_cache_key` is the cheap win.

### 3.2 Streamed chunk (`object: "chat.completion.chunk"`)

```json
{"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-6-astra",
 "system_fingerprint":"fp_44709d6fcb","service_tier":"default",
 "choices":[{"index":0,"delta":{"role":"assistant","content":""},"logprobs":null,"finish_reason":null}],
 "usage":null,"obfuscation":"r4N7vQ2m"}
```

* `choices[].delta`: `role?`, `content?` (string|null), `refusal?`, `tool_calls?[]`, `function_call?`
  (deprecated), `audio?`.
* `delta.tool_calls[]`: `{index: int (required), id?: string, type?: "function", function?: {name?, arguments?}}`.
* `finish_reason`: `stop | length | tool_calls | content_filter | function_call` (deprecated). Non-standard values
  seen: OpenRouter `"error"` (plus `native_finish_reason`).
* `obfuscation`: random padding string, on by default. Set `stream_options.include_obfuscation:false` to drop it.
  Ignore it in the parser.
* Every chunk has the same `id`/`created`. With `include_usage`, every chunk carries `"usage": null` except an extra
  **final chunk with `choices: []`** sent right before `data: [DONE]`. That chunk is missing if the stream is
  interrupted.

### 3.3 Usage object

```json
{"prompt_tokens":182,"completion_tokens":41,"total_tokens":223,
 "prompt_tokens_details":{"cached_tokens":0,"cache_write_tokens":0,"audio_tokens":0,"image_tokens":0,"text_tokens":182},
 "completion_tokens_details":{"reasoning_tokens":0,"accepted_prediction_tokens":0,"rejected_prediction_tokens":0,"audio_tokens":0,"text_tokens":41}}
```

Treat every `*_details` field as optional. llama.cpp sends only `prompt_tokens_details.cached_tokens`. Ollama sends
`prompt_tokens_details.cached_tokens` when set.

### 3.4 Tool-call delta merge algorithm (robust across servers)

```text
state: calls = Map<int choiceIdx, List<Slot>>  (one slot per tool call, keyed by tool_call.index)
on each chunk:
  if chunk has top-level "error": raise mid-stream error
  for choice in chunk.choices (may be empty → usage-only frame):
    d = choice.delta
    reasoning = d.reasoning_content ?? d.reasoning           // §2; also d.reasoning_details[] (OpenRouter)
    if reasoning non-empty: emit ReasoningDelta
    if d.content is String && non-empty: emit TextDelta       // also run <think> splitter if profile says so
    for tc in d.tool_calls ?? []:
      i = tc.index ?? (tc.id != null ? indexOfId(tc.id) ?? nextIndex : lastOpenIndex)   // index missing: defensive
      slot = slots[i] ??= new Slot()
      if tc.id != null && slot.id != null && tc.id != slot.id && slot.args.isNotEmpty:
          // server reused index 0 for a 2nd call (seen on some compat proxies): open a new slot
          i = nextIndex; slot = slots[i] = new Slot()
      if tc.id != null && slot.id == null: slot.id = tc.id
      if tc.function?.name non-empty && slot.name == null: slot.name = name; emit ToolCallStart(i, id, name)
          // never concatenate names (LM Studio 0.3.16 bug appended "" / some servers resend the full name)
      a = tc.function?.arguments
      if a is Map: a = jsonEncode(a)                           // non-compliant servers
      if a is String && a.isNotEmpty: slot.args += a; emit ToolCallArgsDelta(i, a)
    if choice.finish_reason != null: finish = choice.finish_reason (keep first non-"error"; OpenRouter repeats it)
on [DONE] or EOF-after-finish:
  for each slot: id ??= synthesize("call_" + uuid); args = slot.args.trim().isEmpty ? "{}" : slot.args
     parse strictly; if invalid → repair (close brackets/quotes) else ToolCallComplete with parse error flag
  if any slot exists and finish in {stop, null}: finish = tool_calls            // Ollama/older servers
```

The openai-python accumulator (`lib/streaming/_deltas.py`) confirms: merge list entries by `index`, concatenate
strings, never accumulate `index`/`type`, and "Even the first indexed list must be merged: one chunk can contain
several fragments for the same index."

### 3.5 Errors, status codes, headers (OpenAI)

* Body: `{"error": {"message": "...", "type": "...", "param": null|"...", "code": null|"..."}}` (schema `Error`
  requires `type, message, param, code`).
* Statuses: 400 `invalid_request_error` (incl. invalid `service_tier`); 401 (bad key, not in org, IP not
  allowlisted); 403 (unsupported region); 429 several distinct causes. Retryable 429s: rate limit, and `slow_down`
  (`type: rate_limit_error`). **Non-retryable 429s:** `credit_balance_exhausted`, `organization_spend_limit_exceeded`,
  `project_spend_limit_exceeded`, `organization_usage_limit_exceeded`; their `error.type` can be
  `insufficient_quota`. 500 server error. 503 `service_unavailable_error`/`server_is_overloaded`.
* `Retry-After` (seconds) may be present on 429 and 503. Otherwise use exponential backoff with jitter.
* Rate headers: `x-ratelimit-{limit,remaining,reset}-{requests,tokens}` (reset format like `1s`, `6m0s`), plus
  `x-ratelimit-*-project-tokens` when project limits apply.
* Response headers: `x-request-id`, `openai-processing-ms`, `openai-organization`, `openai-version: 2020-10-01` (the
  last is a good "this is real OpenAI" signal). Clients may send `X-Client-Request-Id`.

### 3.6 First-party OpenAI: Chat vs Responses

Verified (latest-model guide, reasoning guide, migrate guide):

* "Use the Responses API for tool calling. Chat Completions supports requests without tools" (GPT-6.1 Sol).
* "GPT-6 Astra and GPT-6.1 Sol support Chat Completions, but tool calling requires Responses. GPT-6 Sol and GPT-6
  Luna support function calling in Chat Completions only with `reasoning_effort: "none"`."
* "Starting with GPT-5.4, Chat Completions does not support tool calling with `reasoning_effort` values other than
  `none`."
* Model page `gpt-6-astra`: 1,050,000 context window, **max input 922,000**, 128,000 max output. Reasoning efforts
  `low..max`. Prompts over 272K input tokens are billed at 2× input and 1.5× output.

### 3.7 Retry policy (all OpenAI-style)

Retry automatically only (a) on connect or HTTP errors before any SSE event, for 408/409/429 (only when not a quota
code)/5xx/529, honoring `Retry-After`; or (b) on EOF before any content delta. After the first token, surface a
resumable error and let the agent loop decide. Replaying a streamed half-answer silently doubles cost and confuses
tool state.

---

## 4. Per-server details

### 4.1 llama.cpp `llama-server` (verified in source)

* **Endpoints:** `GET /health` (also `/v1/health`, no API key) → `{"status":"ok"}`; `GET /props`;
  `GET /models`, `/v1/models`; `POST /v1/chat/completions`; `POST /v1/responses`; `POST /v1/messages`
  (Anthropic-compatible) and `/v1/messages/count_tokens`; `POST /tokenize`, `/detokenize`, `/apply-template`;
  `POST /v1/chat/completions/input_tokens` (chat body → `{"object":"response.input_tokens","input_tokens":11}`);
  `POST /v1/chat/completions/control` (`{"id","action":"reasoning_end"}`, needs `reasoning_control:true`);
  `GET /slots`, `/metrics`. Router mode adds `GET /models` with `status`, plus `POST /models/load|unload`.
* **Auth:** `--api-key` (comma list) or `--api-key-file`, sent as `Authorization: Bearer`. The Anthropic route also
  takes `x-api-key`.
* **Flags:** `--jinja` is **enabled by default** for the server (`common/arg.cpp`: "default: enabled"). It is
  required for tools and for `tool_choice != "auto"` ("tool_choice param requires --jinja flag"). Other flags:
  `--reasoning-format none|deepseek|deepseek-legacy` (default `auto`); `-rea/--reasoning on|off|auto`;
  `--reasoning-effort`; `--reasoning-budget N`; `--chat-template-kwargs '{"enable_thinking":false}'`;
  `-c/--ctx-size`; `-np/--parallel`.
* **Per-request extras:** `reasoning_format`, `chat_template_kwargs`, `reasoning_effort` ("If `none`,
  reasoning/thinking is disabled"), `parallel_tool_calls`, `reasoning_control`, `sse_ping_interval`,
  `return_progress` (UNVERIFIED name; source emits `prompt_progress`), `timings_per_token`. It accepts `max_tokens`
  and `max_completion_tokens` (both alias `n_predict`). `response_format` takes `json_object` + `schema` or
  `json_schema`.
* **Stream emission** (`server-task.cpp`):
  * The first chunk is `delta: {"role":"assistant","content":null}`.
  * Then one chunk per diff:
    `{"reasoning_content":"..."}` | `{"content":"..."}` |
    `{"tool_calls":[{"index":i,"id":"..","type":"function","function":{"name":"..","arguments":".."}}]}`.
    `id` and `type` appear only on the first fragment of a call.
  * Then `{"finish_reason":"stop"|"tool_calls"|"length","index":0,"delta":{}}`.
  * If `include_usage`, a final chunk follows with `choices:[]` and
    `usage {completion_tokens, prompt_tokens, total_tokens, prompt_tokens_details:{cached_tokens}}`.
  * `timings` is attached to the last chunk, and `data: [DONE]` ends the stream.
  * `system_fingerprint` is the build string.
* **timings:** `{cache_n, prompt_n, prompt_ms, prompt_per_token_ms, prompt_per_second, predicted_n, predicted_ms,
  predicted_per_token_ms, predicted_per_second[, draft_n, draft_n_accepted]}`. Per README, "total tokens in context
  = prompt_n + cache_n + predicted_n". Ollama now emits a compatible `timings` object too (fields without `cache_n`).
* **Errors:** `{"error":{"code":400,"message":"...","type":"invalid_request_error"}}`. Types:
  `invalid_request_error` 400, `authentication_error` 401, `permission_error` 403, `not_found_error` 404,
  `server_error` 500, `not_supported_error` 501, `unavailable_error` 503 (model loading/sleeping),
  `exceed_context_size_error` **400 with extra `n_prompt_tokens`, `n_ctx`** ("request (N tokens) exceeds the
  available context size (M tokens), try increasing it"). Map that to `contextOverflow` and use the numbers.
* **Context:** `GET /props` → `default_generation_settings.n_ctx` is the **per-slot** context (effective window per
  request), not `n_ctx_train`. `/v1/models` → `data[0].meta.{n_ctx, n_ctx_train, n_params, size, n_vocab}`
  (`meta` may be `null` while loading); `owned_by:"llamacpp"`; `architecture.{input_modalities,output_modalities}`.
  `/props` also has `modalities.{vision,audio,video}`, `chat_template_caps`, `build_info`, `is_sleeping`,
  `total_slots`. Router mode uses `/props?model=<name>`.
* **Quirk:** `/v1/models` also returns an Ollama-style `"models":[{name, model, details:{format:"gguf"}...}]` array
  next to `data`. **Do not** detect Ollama by the presence of `models`.
* **Quirk:** the vendored and upstream source show `"n_ctx"` in `/v1/models` meta, but the README example omits it.
  Prefer `/props`.

### 4.2 Ollama

* **OpenAI layer `/v1`:**
  * Supported request fields: `model, messages, frequency_penalty, presence_penalty, response_format, seed, stop,
    stream, stream_options, temperature, top_p, max_tokens, tools, reasoning_effort, reasoning{effort}`.
  * **Not supported:** `tool_choice`, `logit_bias`, `user`, `n`. Ollama ignores the API key locally. Ollama
    extension: `keep_alive`.
  * `reasoning_effort`: model-defined names. Boolean-only thinking models map efforts to `true`; `"none"` → `false`.
    Discover allowed values via `/api/show` `thinking.values`/`default`.
* **Delta shape** (`openai/openai.go`):
  * `Delta{role?, content?, reasoning?, tool_calls?}`. A turn that mixes thinking and content is split into two
    chunks (reasoning first).
  * **Tool calls arrive whole:** `{"id":"..","index":n,"type":"function","function":{"name":"..","arguments":"{...}"}}`.
  * The finish chunk has `delta:{}`. `finish_reason` is remapped from `stop` to `tool_calls` if a tool call was
    sent. `system_fingerprint:"fp_ollama"`.
  * Errors: `{"error":{"message","type","param","code"}}`.
* **Responses `/v1/responses`** (v0.13.3+): stateless only (no `previous_response_id`/`conversation`). Supports
  tools, reasoning summaries, and `think` extension.
* **Cloud:** `https://ollama.com/v1` with `OLLAMA_API_KEY`. No stateful Responses.
* **Context length:**
  * Default context is chosen by VRAM: **<24 GiB → 4k, 24–48 GiB → 32k, ≥48 GiB → 256k**. Docs: "agents, and
    coding tools should be set to at least 64000 tokens". Cloud models default to their max.
  * The `/v1` API cannot set it ("The OpenAI API does not have a way of setting the context size"). The options
    are a Modelfile `PARAMETER num_ctx`, `OLLAMA_CONTEXT_LENGTH=64000 ollama serve`, or the native
    `/api/chat` `options.num_ctx`.
  * Discovery:
    * `POST /api/show {"model":"gemma4"}` gives:
      * `model_info["<general.architecture>.context_length"]` (trained max, e.g. `gemma4.context_length: 131072`);
      * `parameters` text (e.g. `num_ctx 2048`, a Modelfile override);
      * `capabilities: ["completion","tools","thinking","vision",...]`;
      * `thinking:{values,default}`.
    * `GET /api/ps` → `models[].context_length` gives the **allocated** context of loaded models (field in
      `api/types.go ProcessModelResponse`).
* **Detect:** `GET /api/version` → `{"version":"x.y.z"}`. `GET /` returns the plain text "Ollama is running"
  (**UNVERIFIED** this session).

### 4.3 LM Studio

* **Endpoints:**
  * OpenAI-compat: `/v1/models`, `/v1/chat/completions`, `/v1/responses` (0.3.29+), `/v1/embeddings`,
    `/v1/completions`, `/v1/decisions`.
  * Anthropic-compat: `POST /v1/messages` (0.4.1+).
  * Native REST v1 (0.4.0+): `/api/v1/chat`, `/api/v1/models`, `/api/v1/models/load|unload|download`.
  * The legacy v0 REST API is `/api/v0/*`.
  * Auth is off by default. Optional API tokens are sent as `Authorization: Bearer $LM_API_TOKEN`.
* **Context:** `GET /api/v1/models` →
  `models[]{type, publisher, key, display_name, architecture, quantization{name,bits_per_weight}, size_bytes,
  params_string, loaded_instances[]{id, config{context_length, eval_batch_size, parallel, flash_attention, ...}},
  max_context_length, format, capabilities{vision, trained_for_tool_use, reasoning{allowed_options, default}}}`.
  Use `loaded_instances[].config.context_length` when loaded, else `max_context_length`. v0:
  `GET /api/v0/models` → `data[]{id, type: llm|vlm|embeddings, arch, compatibility_type: gguf|mlx, quantization,
  state: loaded|not-loaded, max_context_length}`.
* **JIT loading:** with JIT ON, `/v1/models` lists all downloaded models. With JIT OFF, it lists only loaded ones.
* **Changelog quirks to code around:** an empty function name was appended after the first streamed tool-call
  packet (fixed 0.3.16). Parallel tool calls via streaming were mishandled (fixed 0.3.19). Streaming usage stats were
  wrong (fixed 0.3.19).

### 4.4 vLLM

* `--enable-auto-tool-choice` is **mandatory** for `tool_choice:"auto"`. It also needs `--tool-call-parser <name>`
  and optionally `--chat-template`. Named and `required` choices use structured-output decoding: the "first time
  ... several seconds of latency" for FSM compile.
* `--reasoning-parser <name>` (qwen3, deepseek_r1, glm45, gemma4, ...). The output field is **`reasoning`**. The
  doc warns: "`reasoning` used to be called `reasoning_content` ... your client code could silently read an empty
  `reasoning_content`." On input, the server renames `reasoning_content`→`reasoning`. Request `include_reasoning`
  (default true). `reasoning_effort` sets `enable_thinking = effort != "none"`. Per-model toggles go through
  `chat_template_kwargs` (`enable_thinking`, `thinking`).
* With the `hf` response-template parser, "each tool call is emitted whole once its region parses". That parser
  rejects strict tools, required/named choice and `parallel_tool_calls=false`.
* `/v1/models` → `data[]{id, object:"model", created, owned_by:"vllm", root, parent, max_model_len, permission[]}`.
  `GET /version` → `{"version": "..."}`.
* Errors: `{"error":{"message","type","param","code":<int>}}`.
* Also serves `/v1/responses` and `/v1/messages`.

### 4.5 OpenRouter

* Reasoning:
  * Request `reasoning: {effort: max|xhigh|high|medium|low|minimal|none | max_tokens: N, exclude: bool,
    enabled: bool}`.
  * Response `message.reasoning` (string) plus `message.reasoning_details[]`. Detail types:
    `reasoning.summary {summary}`, `reasoning.encrypted {data}`, `reasoning.text {text, signature}`, each with `id`,
    `format` (`anthropic-claude-v1`, `openai-responses-v1`, ...) and `index`.
  * Streaming puts them in `delta.reasoning_details` (concatenate in order). Encrypted content may show
    `[REDACTED]`.
  * **Pass `reasoning_details` back unmodified** for tool loops, especially for Claude via OpenRouter.
* Models API `GET /api/v1/models`: `context_length`, `top_provider{context_length, max_completion_tokens}`,
  `supported_parameters[]` (filterable `?supported_parameters=tools`), and
  `reasoning{supported_efforts, default_effort, default_enabled, mandatory}`.
* Streams: `: OPENROUTER PROCESSING` comments. The final usage chunk **repeats `finish_reason` and has non-empty
  `choices`**: "treat the usage chunk as an accounting frame rather than a second terminal event". Mid-stream errors
  use `finish_reason:"error"`. `X-Generation-Id` header. Cancellation by aborting the connection stops billing for
  supported providers.

### 4.6 DeepSeek

* `thinking: {"type":"enabled"|"disabled"}` (via `extra_body`) plus `reasoning_effort: low|high|max` (mapping:
  minimal/low→low, medium/high/xhigh→high, max/ultra→max). Thinking is on by default at `high`. Anthropic-format and
  Responses-format equivalents exist.
* `reasoning_content` sits next to `content`. With `tools` present, "the reasoning_content must be fully passed back
  to the API in all subsequent requests — even for turns where the model did not perform a tool call. If your code
  does not correctly pass back reasoning_content, the API will return a 400 error." Without tools, it is ignored if
  sent.
* In thinking mode, `temperature`/`presence_penalty`/`frequency_penalty` are accepted but ignored. Models named in
  docs: `deepseek-flash`, `deepseek-v4-pro`.

### 4.7 Hugging Face router

* Base `https://router.huggingface.co/v1`, `Authorization: Bearer $HF_TOKEN`. Model id policy suffixes:
  `:fastest` (default), `:cheapest`, `:preferred`, or `:<provider>` (e.g. `openai/gpt-oss-120b:groq`).
* `GET /v1/models` (no auth needed, checked live) →
  `data[]{id, owned_by, architecture{input_modalities, output_modalities}, providers[]{provider, status,
  context_length, pricing{input,output}, supports_tools, supports_structured_output, first_token_latency_ms,
  throughput, is_model_author}}`.
  Pick `context_length` from the provider that the suffix selects, or the min across `live` providers.

---

## 5. Detecting the server type from a base URL

Run these in order, each with a short timeout (≈2–3 s), and cache the result per base URL. Let the user override.
`root` = base URL with a trailing `/v1` or `/api/v1` stripped.

1. **Known hosts:** `api.openai.com` → OpenAI (Responses for tools). `api.anthropic.com` → Anthropic.
   `openrouter.ai` → OpenRouter. `router.huggingface.co` → HF. `api.deepseek.com` → DeepSeek. `ollama.com` → Ollama
   Cloud.
2. Run the probes in parallel and treat the first decisive one as the answer:
   * `GET {root}/api/version` → 200 JSON `{"version":...}` and **no** `owned_by` probe hit for llamacpp/vllm →
     **Ollama**.
   * `GET {root}/props` → JSON containing `default_generation_settings` (and `build_info`) → **llama.cpp**.
   * `GET {root}/api/v1/models` → JSON `{"models":[{"key":..}]}` → **LM Studio ≥0.4**. Else `GET {root}/api/v0/models`
     → `data[].max_context_length` + `state` → **LM Studio 0.3.x**.
   * `GET {base}/models` → `data[].owned_by == "llamacpp"` → llama.cpp. `owned_by == "vllm"` or presence of
     `max_model_len` → **vLLM** (confirm with `GET {root}/version`). Any response header `openai-version` → OpenAI.
3. Otherwise → **generic OpenAI-compatible**. Use conservative capabilities: no `tool_choice` beyond `auto`, send
   `max_tokens` **and** omit `max_completion_tokens`, parse both reasoning fields, keep a `<think>…</think>` splitter
   available, use a context window from user input (fallback 8192).

Cautions:

* llama.cpp's `/v1/models` includes an Ollama-shaped `models` key. Ollama and vLLM both have a `{"version"}` endpoint,
  but on different paths.
* LM Studio and llama.cpp share a lot of surface (LM Studio's engine is llama.cpp, but its HTTP server is LM Studio's
  own).
* On Android emulators `localhost` is the emulator; the host machine is `10.0.2.2`. iOS and Android need cleartext
  HTTP allowances for LAN servers (§11 Risks).

---

## 6. Context-length and token-count discovery (summary)

| Server | Window | Output cap | Token counting |
|---|---|---|---|
| Anthropic | `GET /v1/models/{id}` → `max_input_tokens` | `max_tokens` | `POST /v1/messages/count_tokens` → `{"input_tokens":N}` (free, separate RPM limit; 32 MB) |
| OpenAI | not in API. Static table from model pages (gpt-6-astra: 1,050,000 ctx / 922,000 max input) | 128,000 (model page) | `POST /v1/responses/input_tokens` exists (reference index); shape **UNVERIFIED** |
| llama.cpp | `/props` `default_generation_settings.n_ctx` (per slot) | `n_ctx` − prompt | `POST /tokenize {"content":"..","add_special":false,"with_pieces":false}` → `{"tokens":[...]}`; `POST /v1/chat/completions/input_tokens` (exact incl. template) |
| Ollama | `/api/ps` `context_length` (loaded) ▸ Modelfile `num_ctx` in `/api/show.parameters` ▸ server default by VRAM. `model_info.<arch>.context_length` is only the ceiling | — | none (**UNVERIFIED**); use the previous response's `usage.prompt_tokens` |
| LM Studio | `/api/v1/models` `loaded_instances[].config.context_length` ▸ `max_context_length` | — | **UNVERIFIED** |
| vLLM | `/v1/models` `max_model_len` | — | `/tokenize` exists (`ServingTokenization`); shape **UNVERIFIED** |
| OpenRouter | `/api/v1/models` `context_length` | `top_provider.max_completion_tokens` | none |
| HF router | `/v1/models` `providers[].context_length` | — | none |

---

## 7. Anthropic Messages API (`POST https://api.anthropic.com/v1/messages`)

### 7.1 Headers

```
x-api-key: $ANTHROPIC_API_KEY            (OAuth: Authorization: Bearer <tok> + anthropic-beta: oauth-2025-04-20)
anthropic-version: 2023-06-01            (the only current version)
content-type: application/json
anthropic-beta: a,b,c                    (comma-separated; unknown/not-enabled value → 400
                                          "Unexpected value(s) `<v>` for the `anthropic-beta` header.")
```

Responses carry `request-id: req_...`; the same id appears as `request_id` in error bodies.

### 7.2 Request shape

```json
{
  "model": "claude-opus-5-5",
  "max_tokens": 64000,
  "stream": true,
  "system": [{"type": "text", "text": "You are Sherpa...", "cache_control": {"type": "ephemeral", "ttl": "1h"}}],
  "messages": [
    {"role": "user", "content": [
      {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "iVBORw0..."}},
      {"type": "document", "source": {"type": "base64", "media_type": "application/pdf", "data": "JVBERi0..."}},
      {"type": "text", "text": "Summarize these."}
    ]}
  ],
  "tools": [{
    "name": "get_weather",
    "description": "Call when the user asks about current weather.",
    "input_schema": {"type": "object", "properties": {"city": {"type": "string"}},
                     "required": ["city"], "additionalProperties": false},
    "strict": true,
    "eager_input_streaming": true,
    "cache_control": {"type": "ephemeral"}
  }],
  "tool_choice": {"type": "auto", "disable_parallel_tool_use": false},
  "thinking": {"type": "adaptive", "display": "summarized"},
  "output_config": {"effort": "medium"},
  "stop_sequences": ["\nObservation:"],
  "metadata": {"user_id": "<opaque hash>"},
  "cache_control": {"type": "ephemeral"}
}
```

* `system`: string or array of `text` blocks (each may carry `cache_control`). `messages[].role`:
  `user|assistant|system`. A mid-conversation `system` message is supported on Opus 5/5.5, Opus 4.8, Fable 5/5.1,
  Mythos 5/5.1, Sonnet 5.5, Haiku 5.5. It must follow a user turn and cannot be `messages[0]`. Max 100,000 messages.
* **Content blocks (input):**
  * `text {text, cache_control?, citations?}`
  * `image {source: base64{media_type: image/jpeg|png|gif|webp, data} | url{url} | file{file_id},
    transformations?{oversized_image: downsize|error}}`
  * `document {source ... application/pdf | text, citations?}`
  * `search_result`
  * `tool_use {id ^[a-zA-Z0-9_-]+$, name, input, caller?}`
  * `tool_result {tool_use_id, content: string | [text|image|search_result|document|tool_reference], is_error?}`
  * `thinking {thinking, signature}`
  * `redacted_thinking {data}`
  * server-tool blocks (`server_tool_use`, `web_search_tool_result`, ...) and `container_upload`
* **Tool definition:**
  * `name` ^[a-zA-Z0-9_-]{1,128}$ (OpenAI: same charset, max 64). MCP names with dots or slashes need a reversible
    mapping.
  * Other fields: `description`, `input_schema` (type object), `strict`, `eager_input_streaming`,
    `cache_control`, `defer_loading`, `input_examples`, `allowed_callers`.
* **`tool_choice`:**
  * `{"type":"auto"}`, `{"type":"any"}`, `{"type":"tool","name":"x"}`, `{"type":"none"}`.
  * `disable_parallel_tool_use:true` means "at most one" with `auto`, "exactly one" with `any`/`tool`.
  * **`any` and `tool` → 400 on Opus 5.5, Sonnet 5.5, Fable 5.1, Mythos 5.1**
    ("tool_choice: type "tool" and "any" are not supported for this model."). Use `auto` + prompt + `strict:true`,
    or structured outputs `output_config.format {type:"json_schema", schema}`.
* **Sampling:** on Fable 5/5.1, Mythos, Opus 5/5.5/4.8/4.7, Sonnet 5/5.5, Haiku 5.5, any non-default
  `temperature`/`top_p`/`top_k` → 400. Sending both `temperature` and `top_p` → 400 even at defaults. The `top_p`
  default is 0.99, so `top_p: 1` → 400. **Don't send sampling params to Anthropic by default.**
* **Prefill:** a final assistant turn → 400 on all 4.6+ models.
* Request size limit 32 MB (413 `request_too_large`). Images: up to 600 per request (100 on 200K-context models),
  ≤ 8000×8000 px, ≤ 10 MB base64 each on the direct API. Over 20 images triggers a stricter per-image dimension
  limit. Claude 4.7+ native max long edge is 2576 px (4784 visual tokens); visual tokens = ⌈w/28⌉·⌈h/28⌉.
  **Downscale on device before upload.**

### 7.3 Thinking and effort per model (from `build-with-claude/thinking`)

| Model | omit `thinking` | `adaptive` | `enabled`+`budget_tokens` | `between_tools` | `disabled` | default effort |
|---|---|---|---|---|---|---|
| Opus 5.5 | adaptive | ✓ | 400 | 400 | **400** | **medium** |
| Sonnet 5.5 | adaptive | ✓ | 400 | ✓ (effort ≤ high; no other fields) | **400** | high |
| Haiku 5.5 | adaptive | ✓ | 400 | 400 | ✓ at effort ≤ high | medium |
| Fable 5.1 / Mythos 5.1 / Fable 5 | adaptive | ✓ | 400 | 400 | 400 | high |
| Opus 5 | adaptive | ✓ | 400 | 400 | ✓ at effort ≤ high | high |
| Sonnet 5 | adaptive | ✓ | 400 | 400 | ✓ | high |
| Opus 4.8 / 4.7 | **off** | ✓ | 400 | 400 | ✓ | high |
| Opus 4.6 / Sonnet 4.6 | off | ✓ | deprecated | 400 | ✓ | high |
| Opus/Sonnet/Haiku 4.5 | off | 400 | ✓ (≥1024, < max_tokens) | 400 | ✓ | n/a (Haiku 4.5: no effort) |

* `output_config.effort`: `low|medium|high|xhigh|max` (`xhigh` from Opus 4.7). A changed top-level effort or
  thinking config **invalidates the prompt cache**. Per-message effort changes (beta
  `mid-conversation-output-config-2026-07-01`) avoid that.
* `thinking.display`: `summarized` or `omitted`. **`omitted` is the default** on every 4.7+ and 5.x model. With
  omitted, the thinking block streams one `thinking_delta` with `""` and then the `signature_delta`. `updates`
  (beta `thinking-display-updates-2026-08-18`) shows only progress-update notes. If the UI shows reasoning, send
  `display:"summarized"` explicitly. Billing is identical.
* **Progress updates:** Fable 5.1, Mythos 5.1, Opus 5.5, Sonnet 5.5 and Fable 5 can write a short progress-update
  `thinking` block (own signature) **immediately before each `tool_use`**. So expect `thinking` blocks interleaved
  between tool calls, not only at index 0.
* **Interleaved thinking** is automatic with adaptive thinking (no beta header).
* The Models API exposes all of this: `capabilities.thinking.types.{adaptive,enabled,disabled}.supported`,
  `capabilities.effort.{low..max}.supported`. Use it to gate requests.

### 7.4 Prompt caching

* `cache_control: {"type":"ephemeral"}` (5 min) or `{"type":"ephemeral","ttl":"1h"}`. It goes on tools, system
  blocks and message blocks. The top-level `cache_control` auto-places on the last cacheable block.
* Max 4 breakpoints per request. Longer TTLs must come before shorter ones.
* Render order: `tools → system → messages`. Minimum cacheable prefix: 512 tokens on the 5.x line, 1024–4096 on older
  models; below the minimum, nothing caches silently.
* Writes cost 1.25× (5 min) or 2× (1 h). Reads cost 0.1× base (0.05× Opus 5.5 / Sonnet 5.5; 0.025× Fable 5.1).
* Verify with `usage.cache_read_input_tokens`, and `usage.cache_creation.{ephemeral_5m_input_tokens,
  ephemeral_1h_input_tokens}`. Each breakpoint looks back at most 20 block positions; a run of parallel `tool_use` or
  `tool_result` blocks counts as one.
* Recommended for agent loops: one explicit breakpoint on the last system block, plus top-level automatic caching.

### 7.5 Streaming events (exact)

```
message_start        {"type":"message_start","message":{id,type:"message",role:"assistant",model,content:[],stop_reason:null,stop_sequence:null,usage:{input_tokens,cache_creation_input_tokens,cache_read_input_tokens,output_tokens}}}
content_block_start  {"type":"content_block_start","index":i,"content_block":<block with empty payload>}
                       text:            {"type":"text","text":""}
                       thinking:        {"type":"thinking","thinking":"","signature":""}
                       redacted_thinking:{"type":"redacted_thinking","data":"..."}         (arrives whole; no deltas — UNVERIFIED)
                       tool_use:        {"type":"tool_use","id":"toolu_..","name":"..","input":{}}   (input is a placeholder)
                       server_tool_use: {"type":"server_tool_use","id":"srvtoolu_..","name":"web_search","input":{}}
                       *_tool_result:   e.g. {"type":"web_search_tool_result","tool_use_id":"srvtoolu_..","content":[...]} (whole)
                       fallback:        start+stop pair with no deltas at a model boundary (server-side fallback beta)
content_block_delta  {"type":"content_block_delta","index":i,"delta":D}
                       D = {"type":"text_delta","text":".."}
                         | {"type":"input_json_delta","partial_json":".."}     (concatenate; parse at content_block_stop)
                         | {"type":"thinking_delta","thinking":".."}
                         | {"type":"signature_delta","signature":".."}       (just before content_block_stop)
                         | {"type":"citations_delta","citation":{type: char_location|page_location|content_block_location|web_search_result_location|search_result_location, ...}}
content_block_stop   {"type":"content_block_stop","index":i}
message_delta        {"type":"message_delta","delta":{"stop_reason":"..","stop_sequence":null|"..","stop_details":null|{...},"container":null},"usage":{output_tokens, input_tokens?, cache_creation_input_tokens?, cache_read_input_tokens?, output_tokens_details?{thinking_tokens}, server_tool_use?{web_search_requests,web_fetch_requests}}}
message_stop         {"type":"message_stop"}
ping                 {"type":"ping"}                              (any time)
error                {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}
```

* Usage in `message_delta` is **cumulative**. Take the last value per field, falling back to `message_start` values.
* `input_json_delta` currently emits one complete key/value at a time, so there may be pauses. Turn on
  `eager_input_streaming:true` per client tool for true incremental streaming. The input is then not validated by
  the server: validate it against the schema, check `stop_reason` for `max_tokens`/`refusal` before running tools,
  and on invalid JSON return `tool_result {is_error:true, content:"{\"INVALID_JSON\": \"<raw>\"}"}`. Do not send the
  legacy `fine-grained-tool-streaming-2025-05-14` header.
* **Handle unknown event and block types gracefully** (versioning policy). Store unknown blocks verbatim and echo
  them back.
* Optional beta `thinking-binding-controls-2026-08-01` adds `message.input_transformations[]` to `message_start`
  (list of dropped thinking blocks).
* **Error recovery on 4.6+:** a partial stream cannot be continued with assistant prefill. Send a user message
  ("Your previous response was interrupted and ended with [...]. Continue from where you left off."). Tool-use and
  thinking blocks cannot be partially recovered.

### 7.6 `stop_reason`

`end_turn` | `max_tokens` | `stop_sequence` (+ `stop_sequence` string) | `tool_use` | `pause_turn` | `refusal` |
`model_context_window_exceeded`. In streaming it is `null` in `message_start` and set in `message_delta`.

* `pause_turn`: the server-tool loop hit its iteration limit (default 10). Resend the conversation with the paused
  assistant content appended unchanged. **Do not** add a "continue" user message. Cap continuations (e.g. 5).
* `refusal`: HTTP 200, `content` possibly partial, and
  `stop_details {type:"refusal", category: cyber|bio|frontier_llm|reasoning_extraction|general_harms|null,
  explanation, recommended_model?}`. Branch on `stop_reason`, not on `stop_details` internals. **Discard partial
  output and never run that turn's tools.** Refusals before output are billed for `bio`/`frontier_llm`/
  `reasoning_extraction`. Optional server-side fallback: beta `server-side-fallback-2026-07-01` +
  `"fallbacks":"default"`; not for Haiku 5.5; Claude API only.
* `model_context_window_exceeded` (4.5+, no beta): input + `max_tokens` may exceed the window. Generation then stops
  at the window. Treat it as truncated.

### 7.7 Errors and rate limits

* Body: `{"type":"error","error":{"type":"<type>","message":"..."},"request_id":"req_..."}`.
* Types and statuses:
  * 400 `invalid_request_error` (also spend limits you set)
  * 401 `authentication_error`
  * 402 `billing_error`
  * 403 `permission_error`
  * 404 `not_found_error` (also models not available to the org)
  * 409 `conflict_error`
  * 413 `request_too_large`
  * 429 `rate_limit_error` (a tier spend-cap 429 has **no** `retry-after` and keeps failing, so it is not
    retryable)
  * 500 `api_error`
  * 504 `timeout_error`
  * **529 `overloaded_error`**
* Headers:
  * `retry-after` (seconds).
  * `anthropic-ratelimit-{requests,tokens,input-tokens,output-tokens}-{limit,remaining,reset}`. The reset values
    are RFC 3339; token remainders are rounded to the nearest thousand.
  * The `tokens-*` headers report the most restrictive limit in effect.
* SDK semantics to mirror: retry 408/409/429/5xx and connection errors twice with exponential backoff, honoring
  `retry-after`.

### 7.8 Models and token counting

* `GET /v1/models?limit=&after_id=&before_id=&lifecycle=active,deprecated` →
  `{data:[ModelInfo], first_id, last_id, has_more}`. `GET /v1/models/{id}`.
* `ModelInfo`: `id, display_name, created_at, line (haiku|sonnet|opus|fable|mythos|null), lifecycle
  (active|deprecated|retired), deprecated_at, retires_at, max_input_tokens, max_tokens, capabilities{batch, citations,
  code_execution, context_management{clear_thinking_20251015, clear_tool_uses_20250919, compact_20260112},
  effort{low,medium,high,xhigh,max}, image_input, pdf_input, server_tools{web_search, code_execution},
  structured_outputs, thinking{types{adaptive,enabled,disabled}}}`.
  Each leaf is `{supported: bool}`. No `context_window` field. Don't infer `line` from `id`.
* `POST /v1/messages/count_tokens` takes the same body (model, system, messages, tools) and returns
  `{"input_tokens": N}`. It is free and has its own RPM limit. Forced `tool_choice` 400s here too on Opus 5.5 and
  friends.

### 7.9 Thinking blocks in tool loops: the hard rules

1. **Within a tool-use turn, pass every `thinking` and `redacted_thinking` block back complete and unmodified**, in
   the original order, next to the `tool_use` blocks. "Modified thinking blocks are rejected with a 400." The one
   exception: text placed into the empty `thinking` of an *omitted* block is ignored. Filtering on
   `type=="thinking"` alone silently drops `redacted_thinking`.
2. Across turns: pass everything back. The API filters, keeps what the model needs, and bills only what it shows.
   Keep-all models: Opus 4.5+, Sonnet 4.6+, Haiku 5.5, Fable/Mythos. Older models are last-turn-only.
3. **Preserved thinking** (Fable 5.1, Opus 5.5, Sonnet 5.5, Haiku 5.5):
   * A thinking block is valid only while the top-level `system`, `tools` and all messages before it are
     byte-identical.
   * **Enforced by default for accounts created ≥ 2026-08-31 00:00 UTC.** The 400 message starts:
     ``messages.1.content.0: Invalid `signature` in `thinking` block. The block is bound to a different conversation.``
   * Older accounts are checked only if `thinking.block_binding.prefix_mismatch_behavior` is set (beta
     `thinking-binding-controls-2026-08-01`, values `"error"`/`"drop_block"`).
   * Invalid edits:
     * editing, reordering or deleting any earlier user/assistant/system message;
     * clearing or shortening an earlier `tool_result`;
     * re-encoding an image;
     * changing `system`;
     * adding, removing or renaming a tool;
     * removing a thinking block from the middle;
     * an image URL whose bytes change;
     * deleting a turn-scoped reminder.
   * Valid changes:
     * appending;
     * changing any other param (`effort`, `max_tokens`, `tool_choice`, `thinking.display`, `metadata`);
     * moving `cache_control`;
     * dropping thinking from the start or end, or all of it;
     * server-side context editing or compaction.
   * Replacement patterns for common edits:
     * Turn tools off with `tool_choice:{type:"none"}` rather than removing them.
     * Add new instructions with a mid-conversation `role:"system"` message.
     * Send per-turn reminders as a text block after the `tool_result`s (or as a `clear_at` system message, beta).
     * Change tools with `tool_addition`/`tool_removal` (beta `mid-conversation-tool-changes-2026-07-01`).
4. **Account binding:** Sonnet 5.5 and Haiku 5.5 thinking blocks work only in the producing (or a linked) account.
   Signatures are otherwise portable across Claude API, Bedrock and Vertex.
5. **Model switching:** blocks the target model can't read are dropped silently and unbilled. Fable 5.1 reads Opus
   5.5 blocks on the Claude API; the reverse is not true. Keep sending them unchanged anyway.
6. Toggling thinking *within* a tool-use turn silently disables thinking for that request. Change thinking config
   only at a new user turn.
7. **Compaction compatible with preserved thinking.** Recommended "simple compaction": summarize the whole session
   into one user message plus the next instruction, so no earlier thinking is replayed. Never compact between a
   `tool_use` and its `tool_result`. Never cut turns from the middle.

### 7.10 Context management features (should a third-party client use them?)

* **Context editing** (beta `context-management-2025-06-27`):
  ```json
  "context_management": {"edits": [{"type": "clear_tool_uses_20250919",
     "trigger": {"type": "input_tokens", "value": 30000}, "keep": {"type": "tool_uses", "value": 3},
     "clear_at_least": {"type": "input_tokens", "value": 5000}, "exclude_tools": ["web_search"],
     "clear_tool_inputs": false}]}
  ```
  Also `clear_thinking_20251015`. It runs server-side, so **it doesn't count as a prefix edit**. That makes it the
  sanctioned way to trim old tool output on preserved-thinking models. It invalidates the cache at the clear point,
  hence `clear_at_least`.
* **Compaction:**
  * On-demand (beta `compact-2026-09-04`, top-level `compaction`) returns a signed block that you swap in place of
    the summarized messages.
  * Threshold (beta `compact-2026-01-12`, edit `compact_20260112`, default trigger 150K) runs inside ordinary
    requests. You must append the full `response.content` (including the compaction blocks).
* **Memory tool:** `{"type":"memory_20250818","name":"memory"}` (no schema). The client implements file-like
  commands against its own storage. Fits Sherpa's on-device storage, but it is a product feature.
* **Recommendation:** v1 = append-only history + "simple compaction" (new segment seeded with a summary) as the
  universal fallback. Behind a capability flag (`capabilities.context_management.*` from the Models API), offer
  `clear_tool_uses_20250919` for long tool sessions on the Claude API. Defer server compaction (two competing betas,
  churn). Betas are not on every platform.

### 7.11 Current Anthropic models (Models overview, 2026-10-18)

| Model | API id | Context | Max out | Thinking | Default effort | $/MTok in/out |
|---|---|---|---|---|---|---|
| Claude Fable 5.1 | `claude-fable-5-1` | 1M | 128K | adaptive, always on | high | 10 / 50 |
| Claude Opus 5.5 | `claude-opus-5-5` | 1M | 128K | adaptive, always on | medium | 4 / 20 |
| Claude Sonnet 5.5 | `claude-sonnet-5-5` | 1M | 128K | adaptive | high | 2 / 10 |
| Claude Haiku 5.5 | `claude-haiku-5-5` | 1M | 128K | adaptive | medium | from 0.10 / 0.50 |
| Legacy (still served) | `claude-fable-5`, `claude-opus-5`, `claude-opus-4-8`, `claude-opus-4-7`, `claude-opus-4-6`, `claude-opus-4-5`, `claude-sonnet-5`, `claude-sonnet-4-6`, `claude-haiku-4-5` (200K/64K) | | | | | |

Dateless ids are pinned snapshots. Don't append date suffixes. Discover at runtime via `/v1/models` rather than
hardcoding.

---

## 8. OpenAI Responses API (brief)

* `POST /v1/responses`. Key fields:
  * `input` (string, or an items array: messages, `function_call`, `function_call_output {type, call_id, output:
    string|[input_text|input_image|input_file]}`, `reasoning {encrypted_content, summary, content}`, `compaction`)
  * `instructions`, `tools` (function tools are **flat**: `{type:"function", name, description, parameters,
    strict}`, plus `async`)
  * `tool_choice`, `parallel_tool_calls`, `max_output_tokens`, `max_tool_calls`
  * `reasoning {effort, summary}`, `text {format}` (structured outputs), `store` (**default true**),
    `previous_response_id`, `include` (e.g. `"reasoning.encrypted_content"`)
  * `prompt_cache_key`, `prompt_cache_options`, `context_management` (compaction), `truncation`
* **Stateless mode** (`store:false` or ZDR): reasoning items include `encrypted_content` by default. Replay them in
  the next `input` to keep reasoning across tool calls. This is the Responses equivalent of Anthropic thinking
  signatures.
* **Streaming:** SSE with `event: <type>` lines and data carrying `type` and `sequence_number`.
  * Lifecycle: `response.created`, `response.in_progress`, `response.completed`, `response.failed`,
    `response.incomplete`, `response.queued`.
  * Items: `response.output_item.added`, `response.output_item.done`.
  * Text: `response.content_part.added/.done`, `response.output_text.delta/.done`, `response.refusal.delta/.done`.
  * Function calls: `response.function_call_arguments.delta` `{item_id, output_index, delta}` and
    `response.function_call_arguments.done` `{item_id, output_index, arguments}`.
  * Reasoning: `response.reasoning_summary_part.added/.done`, `response.reasoning_summary_text.delta/.done`,
    `response.reasoning_text.delta/.done`.
  * Other: `response.custom_tool_call_input.delta/.done`, `response.compaction.compacting`, and the
    web/file/mcp/code-interpreter/shell/image events.
  * Errors: `error`.
* **Parallel function calls** arrive as separate output items. Key the accumulator by `output_index`. The
  `response.output_item.added` item carries `id` (`fc_..`), `call_id` (`call_..`), `name`, `arguments:""`. Return
  results with `call_id`. Usage lives on `response.completed.response.usage {input_tokens,
  input_tokens_details{cached_tokens, cache_write_tokens}, output_tokens, output_tokens_details{reasoning_tokens},
  total_tokens}`.
* **Worth it in v1?** **Yes, for `api.openai.com` only, if OpenAI first-party is a v1 target** (§3.6: no tools with
  reasoning on Chat Completions for GPT-5.4+/GPT-6). It is also implemented, with partial fidelity, by llama.cpp,
  Ollama (stateless), LM Studio (0.3.29+), vLLM and OpenRouter. Chat Completions remains the better common
  denominator for those. Implement Responses **stateless** (`store:false`, replay encrypted reasoning). That matches
  Sherpa's local-first transcript and avoids server-side state.

---

## 9. Test fixtures (raw SSE; one streamed parallel-tool-call turn each)

Conventions:

* Every `data:` line is one JSON object. Events are separated by a blank line.
* Expected normalized output uses `sherpa_core` `ModelEvent` names.
* Keep these as golden files: `test/fixtures/sse/<name>.sse`.

### F1: OpenAI Chat Completions, parallel tool calls (synthesized from the documented schema)

Request (abridged): `model:"gpt-6-luna"`, `reasoning_effort:"none"` (required for tools on Chat per §3.6),
`stream:true`, `stream_options:{include_usage:true}`, tools `get_weather(city)`, `get_time(timezone)`.

```text
data: {"id":"chatcmpl-F1","object":"chat.completion.chunk","created":1760780000,"model":"gpt-6-luna","service_tier":"default","system_fingerprint":"fp_f1","choices":[{"index":0,"delta":{"role":"assistant","content":null,"refusal":null},"logprobs":null,"finish_reason":null}],"usage":null,"obfuscation":"q8Rz"}

data: {"id":"chatcmpl-F1","object":"chat.completion.chunk","created":1760780000,"model":"gpt-6-luna","service_tier":"default","system_fingerprint":"fp_f1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_wX1","type":"function","function":{"name":"get_weather","arguments":""}}]},"logprobs":null,"finish_reason":null}],"usage":null,"obfuscation":"a"}

data: {"id":"chatcmpl-F1","object":"chat.completion.chunk","created":1760780000,"model":"gpt-6-luna","service_tier":"default","system_fingerprint":"fp_f1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"ci"}}]},"logprobs":null,"finish_reason":null}],"usage":null,"obfuscation":"Zk"}

data: {"id":"chatcmpl-F1","object":"chat.completion.chunk","created":1760780000,"model":"gpt-6-luna","service_tier":"default","system_fingerprint":"fp_f1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ty\": \"Paris\"}"}}]},"logprobs":null,"finish_reason":null}],"usage":null,"obfuscation":"m"}

data: {"id":"chatcmpl-F1","object":"chat.completion.chunk","created":1760780000,"model":"gpt-6-luna","service_tier":"default","system_fingerprint":"fp_f1","choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"call_tY2","type":"function","function":{"name":"get_time","arguments":""}}]},"logprobs":null,"finish_reason":null}],"usage":null,"obfuscation":"Qp4"}

data: {"id":"chatcmpl-F1","object":"chat.completion.chunk","created":1760780000,"model":"gpt-6-luna","service_tier":"default","system_fingerprint":"fp_f1","choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"function":{"arguments":"{\"timezone\": "}}]},"logprobs":null,"finish_reason":null}],"usage":null,"obfuscation":"x"}

data: {"id":"chatcmpl-F1","object":"chat.completion.chunk","created":1760780000,"model":"gpt-6-luna","service_tier":"default","system_fingerprint":"fp_f1","choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"function":{"arguments":"\"Asia/Tokyo\"}"}}]},"logprobs":null,"finish_reason":null}],"usage":null,"obfuscation":"7Hd"}

data: {"id":"chatcmpl-F1","object":"chat.completion.chunk","created":1760780000,"model":"gpt-6-luna","service_tier":"default","system_fingerprint":"fp_f1","choices":[{"index":0,"delta":{},"logprobs":null,"finish_reason":"tool_calls"}],"usage":null,"obfuscation":"k2"}

data: {"id":"chatcmpl-F1","object":"chat.completion.chunk","created":1760780000,"model":"gpt-6-luna","service_tier":"default","system_fingerprint":"fp_f1","choices":[],"usage":{"prompt_tokens":182,"completion_tokens":41,"total_tokens":223,"prompt_tokens_details":{"cached_tokens":0,"audio_tokens":0},"completion_tokens_details":{"reasoning_tokens":0,"audio_tokens":0,"accepted_prediction_tokens":0,"rejected_prediction_tokens":0}},"obfuscation":"P"}

data: [DONE]

```

Expected:

```text
ToolCallStart(0, call_wX1, get_weather)
ToolCallArgsDelta(0, {"ci)
ToolCallArgsDelta(0, ty": "Paris"})
ToolCallStart(1, call_tY2, get_time)
ToolCallArgsDelta(1, {"timezone": )
ToolCallArgsDelta(1, "Asia/Tokyo"})
ToolCallComplete(0, {city: Paris})
ToolCallComplete(1, {timezone: Asia/Tokyo})
Usage(in 182, cached 0, out 41, reasoning 0)
Finish(toolCalls)
```

Follow-up turn: append one assistant message with
`tool_calls:[{id:"call_wX1",type:"function",function:{name:"get_weather",arguments:"{\"city\": \"Paris\"}"}},
{id:"call_tY2",...}]`, then two `{role:"tool", tool_call_id, content}` messages in the same order.

### F2: llama.cpp variant (reasoning_content, ping comment, timings), derived from server source

```text
data: {"choices":[{"finish_reason":null,"index":0,"delta":{"role":"assistant","content":null}}],"created":1760780001,"id":"chatcmpl-F2llama","model":"qwen3-8b","system_fingerprint":"b7000-abc1234","object":"chat.completion.chunk"}

data: {"choices":[{"finish_reason":null,"index":0,"delta":{"reasoning_content":"Need weather and time; call both."}}],"created":1760780001,"id":"chatcmpl-F2llama","model":"qwen3-8b","system_fingerprint":"b7000-abc1234","object":"chat.completion.chunk"}

:

data: {"choices":[{"finish_reason":null,"index":0,"delta":{"tool_calls":[{"index":0,"id":"Vd9q2LxR8sTn4KbP","type":"function","function":{"name":"get_weather","arguments":"{\"city\":"}}]}}],"created":1760780001,"id":"chatcmpl-F2llama","model":"qwen3-8b","system_fingerprint":"b7000-abc1234","object":"chat.completion.chunk"}

data: {"choices":[{"finish_reason":null,"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"Paris\"}"}}]}}],"created":1760780001,"id":"chatcmpl-F2llama","model":"qwen3-8b","system_fingerprint":"b7000-abc1234","object":"chat.completion.chunk"}

data: {"choices":[{"finish_reason":null,"index":0,"delta":{"tool_calls":[{"index":1,"id":"Hc3mW7yZ0aQe5UjD","type":"function","function":{"name":"get_time","arguments":"{\"timezone\":\"Asia/Tokyo\"}"}}]}}],"created":1760780001,"id":"chatcmpl-F2llama","model":"qwen3-8b","system_fingerprint":"b7000-abc1234","object":"chat.completion.chunk"}

data: {"choices":[{"finish_reason":"tool_calls","index":0,"delta":{}}],"created":1760780001,"id":"chatcmpl-F2llama","model":"qwen3-8b","system_fingerprint":"b7000-abc1234","object":"chat.completion.chunk"}

data: {"choices":[],"created":1760780001,"id":"chatcmpl-F2llama","model":"qwen3-8b","system_fingerprint":"b7000-abc1234","object":"chat.completion.chunk","usage":{"completion_tokens":58,"prompt_tokens":240,"total_tokens":298,"prompt_tokens_details":{"cached_tokens":212}},"timings":{"cache_n":212,"prompt_n":28,"prompt_ms":41.2,"prompt_per_token_ms":1.47,"prompt_per_second":679.6,"predicted_n":58,"predicted_ms":1210.5,"predicted_per_token_ms":20.87,"predicted_per_second":47.9}}

data: [DONE]

```

Expected:

```text
ReasoningDelta(...)
ToolCallStart(0) ... ToolCallStart(1)
Usage
Finish(toolCalls)
Context used = 28 + 212 + 58 = 298 (compare with /props n_ctx)
```

Mid-stream error variant (replaces the tail; no `[DONE]` follows):
`data: {"error":{"code":500,"message":"...","type":"server_error"}}`

### F3: Ollama `/v1` variant (whole tool calls, `reasoning` field), derived from `openai/openai.go`

```text
data: {"id":"chatcmpl-417","object":"chat.completion.chunk","created":1760780002,"model":"qwen3:8b","system_fingerprint":"fp_ollama","choices":[{"index":0,"delta":{"role":"assistant","content":"","reasoning":"Two lookups needed."},"finish_reason":null}]}

data: {"id":"chatcmpl-417","object":"chat.completion.chunk","created":1760780002,"model":"qwen3:8b","system_fingerprint":"fp_ollama","choices":[{"index":0,"delta":{"tool_calls":[{"id":"call_a1b2c3d4","index":0,"type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Paris\"}"}},{"id":"call_e5f6g7h8","index":1,"type":"function","function":{"name":"get_time","arguments":"{\"timezone\":\"Asia/Tokyo\"}"}}]},"finish_reason":null}]}

data: {"id":"chatcmpl-417","object":"chat.completion.chunk","created":1760780002,"model":"qwen3:8b","system_fingerprint":"fp_ollama","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

data: {"id":"chatcmpl-417","object":"chat.completion.chunk","created":1760780002,"model":"qwen3:8b","system_fingerprint":"fp_ollama","choices":[],"usage":{"prompt_tokens":231,"completion_tokens":44,"total_tokens":275}}

data: [DONE]

```

Exact chunk boundaries and the `usage` chunk placement for Ollama are **UNVERIFIED**; the struct shapes are
verified.

### F4: Anthropic Messages, adaptive thinking (summarized) + parallel tool_use (assembled from documented events)

Request (abridged):

```json
{"model":"claude-opus-5-5","max_tokens":64000,"stream":true,
 "thinking":{"type":"adaptive","display":"summarized"},"output_config":{"effort":"medium"},
 "tools":[{"name":"get_weather","input_schema":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]},"eager_input_streaming":true},
          {"name":"get_time","input_schema":{"type":"object","properties":{"timezone":{"type":"string"}},"required":["timezone"]},"eager_input_streaming":true}],
 "messages":[{"role":"user","content":"Weather in Paris and the time in Tokyo?"}]}
```

```text
event: message_start
data: {"type":"message_start","message":{"id":"msg_01F4example","type":"message","role":"assistant","model":"claude-opus-5-5","content":[],"stop_reason":null,"stop_sequence":null,"stop_details":null,"usage":{"input_tokens":690,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":2}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}

event: ping
data: {"type":"ping"}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Two independent lookups: Paris weather and Tokyo time."}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":" Both can run in parallel."}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"EqQBCgIYAhIM1gbcDa9GJwZA2b3hGgxBdjrkzLoky3dl1pkiMOYds"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: content_block_start
data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Checking both now."}}

event: content_block_stop
data: {"type":"content_block_stop","index":1}

event: content_block_start
data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_01AbCdEf","name":"get_weather","input":{}}}

event: content_block_delta
data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"city\": \"Par"}}

event: content_block_delta
data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"is\"}"}}

event: content_block_stop
data: {"type":"content_block_stop","index":2}

event: content_block_start
data: {"type":"content_block_start","index":3,"content_block":{"type":"tool_use","id":"toolu_01GhIjKl","name":"get_time","input":{}}}

event: content_block_delta
data: {"type":"content_block_delta","index":3,"delta":{"type":"input_json_delta","partial_json":"{\"timezone\": \"Asia/Tokyo\"}"}}

event: content_block_stop
data: {"type":"content_block_stop","index":3}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null,"stop_details":null},"usage":{"input_tokens":690,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":118}}

event: message_stop
data: {"type":"message_stop"}

```

Expected:

```text
ReasoningDelta x2
ReasoningSignature(signature)
TextDelta("Checking both now.")
ToolCallStart(2, toolu_01AbCdEf, get_weather) + deltas → Complete({city:Paris})
ToolCallStart(3, toolu_01GhIjKl, get_time) → Complete({timezone:Asia/Tokyo})
Usage(in 690, out 118)
Finish(toolCalls)
```

Indexes are content-block indexes, so the tool-call ordinal ≠ block index. Map them to 0..n for the agent and keep
the block index for replay.

Next request: append the assistant message **exactly as received**, then a single user message with the results
**first**:

```json
[{"role":"assistant","content":[
   {"type":"thinking","thinking":"Two independent lookups: Paris weather and Tokyo time. Both can run in parallel.","signature":"EqQBCgIYAhIM1gbcDa9GJwZA2b3hGgxBdjrkzLoky3dl1pkiMOYds"},
   {"type":"text","text":"Checking both now."},
   {"type":"tool_use","id":"toolu_01AbCdEf","name":"get_weather","input":{"city":"Paris"}},
   {"type":"tool_use","id":"toolu_01GhIjKl","name":"get_time","input":{"timezone":"Asia/Tokyo"}}]},
 {"role":"user","content":[
   {"type":"tool_result","tool_use_id":"toolu_01AbCdEf","content":"18°C, cloudy"},
   {"type":"tool_result","tool_use_id":"toolu_01GhIjKl","content":"21:04 JST","is_error":false}]}]
```

Variants to include as separate fixtures:

* **(a) `display` omitted (default on Opus 5.5).** Index 0 gets one
  `{"type":"thinking_delta","thinking":""}` and then the `signature_delta`. Replay with `"thinking":""`.
* **(b) Progress updates.** An extra `thinking` block with its own signature sits immediately before each
  `tool_use`, so blocks run 0 thinking, 1 text, 2 thinking, 3 tool_use, 4 thinking, 5 tool_use.
* **(c) Mid-stream overload.** After any event:
  `event: error` / `data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}`, with no
  `message_stop`. Expected: a `ProviderException(overloaded)` that is not auto-retried, because content was already
  emitted.
* **(d) Refusal.** `message_delta` carries
  `{"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber","explanation":"..."}}`. Expected:
  `Finish(refusal)`, partial output discarded, tools not run.
* **(e) `redacted_thinking`.** `content_block_start` carries `{"type":"redacted_thinking","data":"EmwKAhgB..."}` and
  is followed directly by `content_block_stop`. This streaming shape is **UNVERIFIED**; the block shape is verified.

### F5: OpenAI Responses, parallel function calls (shape from the reference; trimmed `response` objects)

```text
event: response.created
data: {"type":"response.created","sequence_number":0,"response":{"id":"resp_F5","object":"response","status":"in_progress","model":"gpt-6-astra","output":[]}}

event: response.output_item.added
data: {"type":"response.output_item.added","sequence_number":1,"output_index":0,"item":{"type":"reasoning","id":"rs_F5","summary":[]}}

event: response.output_item.done
data: {"type":"response.output_item.done","sequence_number":2,"output_index":0,"item":{"type":"reasoning","id":"rs_F5","summary":[],"encrypted_content":"gAAAAABo..."}}

event: response.output_item.added
data: {"type":"response.output_item.added","sequence_number":3,"output_index":1,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"get_weather","arguments":"","status":"in_progress"}}

event: response.function_call_arguments.delta
data: {"type":"response.function_call_arguments.delta","sequence_number":4,"item_id":"fc_1","output_index":1,"delta":"{\"city\":\"Paris\"}"}

event: response.function_call_arguments.done
data: {"type":"response.function_call_arguments.done","sequence_number":5,"item_id":"fc_1","output_index":1,"arguments":"{\"city\":\"Paris\"}"}

event: response.output_item.done
data: {"type":"response.output_item.done","sequence_number":6,"output_index":1,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"get_weather","arguments":"{\"city\":\"Paris\"}","status":"completed"}}

event: response.output_item.added
data: {"type":"response.output_item.added","sequence_number":7,"output_index":2,"item":{"type":"function_call","id":"fc_2","call_id":"call_2","name":"get_time","arguments":"","status":"in_progress"}}

event: response.function_call_arguments.delta
data: {"type":"response.function_call_arguments.delta","sequence_number":8,"item_id":"fc_2","output_index":2,"delta":"{\"timezone\":\"Asia/Tokyo\"}"}

event: response.function_call_arguments.done
data: {"type":"response.function_call_arguments.done","sequence_number":9,"item_id":"fc_2","output_index":2,"arguments":"{\"timezone\":\"Asia/Tokyo\"}"}

event: response.output_item.done
data: {"type":"response.output_item.done","sequence_number":10,"output_index":2,"item":{"type":"function_call","id":"fc_2","call_id":"call_2","name":"get_time","arguments":"{\"timezone\":\"Asia/Tokyo\"}","status":"completed"}}

event: response.completed
data: {"type":"response.completed","sequence_number":11,"response":{"id":"resp_F5","object":"response","status":"completed","model":"gpt-6-astra","usage":{"input_tokens":201,"input_tokens_details":{"cached_tokens":0},"output_tokens":77,"output_tokens_details":{"reasoning_tokens":40},"total_tokens":278}}}

```

Exact field sets inside the `response` and `reasoning` items are **UNVERIFIED** and trimmed. Event names and
delta/done fields are verified. Next turn `input`: the prior items (the reasoning item including
`encrypted_content`, then both `function_call` items), then
`{"type":"function_call_output","call_id":"call_1","output":"18°C"}` and the same for `call_2`.

---

## 10. Mapping onto current `sherpa_core` contracts

* **`FinishReason`:**

  | Source value | `FinishReason` |
  |---|---|
  | OpenAI `stop` (→ `toolCalls` if any call was accumulated) | `stop` |
  | OpenAI `length` | `length` |
  | OpenAI `tool_calls`, `function_call` | `toolCalls` |
  | OpenAI `content_filter` | `contentFilter` |
  | OpenRouter `error` | `error` |
  | Anthropic `end_turn`, `stop_sequence` | `stop` |
  | Anthropic `max_tokens` | `length` |
  | Anthropic `tool_use` | `toolCalls` |
  | Anthropic `pause_turn` | `pause` |
  | Anthropic `refusal` | `refusal` |
  | Anthropic `model_context_window_exceeded` | `contextOverflow` (truncated) |
  | Responses `completed` (+ calls → `toolCalls`) | `stop` |
  | Responses `incomplete` | `length` (reason names **UNVERIFIED**) |

* **`ProviderErrorKind`:**

  | Source | `ProviderErrorKind` |
  |---|---|
  | 400 | `invalidRequest` |
  | llama.cpp `exceed_context_size_error`, or a 400 whose message says context/prompt too long (exact Anthropic/OpenAI messages **UNVERIFIED**) | `contextOverflow` |
  | 401 | `auth` |
  | 402, and quota 429s (OpenAI `insufficient_quota`/`*_spend_limit_exceeded`/`credit_balance_exhausted`; Anthropic 429 with no `retry-after` on spend cap) | **add `quota`** (not retryable; today's enum would mislabel these as `rateLimited` = retryable) |
  | 403 | `auth` (permission/region) |
  | 404 | `modelNotFound` |
  | 413 | `invalidRequest` |
  | 429 | `rateLimited` + `retryAfter` |
  | 500 | `server` |
  | 503 (OpenAI `server_is_overloaded`, llama.cpp `unavailable_error`), 529 | `overloaded` |
  | 504 | `timeout` |
  | 501 (llama.cpp `not_supported_error`) | `unsupported` |

* **`ReasoningEffort {off, low, medium, high}`:** the doc comment ("Anthropic budget_tokens") is stale. Proposed
  enum: `{providerDefault, off, minimal, low, medium, high, xhigh, max}`.
  * Anthropic: effort → `output_config.effort`; `off` per §7.3 (Opus 5.5: impossible → map to `low` and flag;
    Sonnet 5.5: `between_tools`; Haiku 5.5/Opus 5 ≤ high: `disabled`; 4.x: omit/`disabled`).
  * OpenAI: `reasoning_effort` (Chat) / `reasoning.effort` (Responses) with model gating (Astra has no `none`).
  * DeepSeek: `thinking.type` + `reasoning_effort`.
  * vLLM/llama.cpp: `reasoning_effort:"none"` or `chat_template_kwargs.enable_thinking`.
  * Ollama: `reasoning_effort` per `/api/show thinking.values`.
* **`ToolChoiceRequired`/`ToolChoiceSpecific`:**
  * Anthropic Opus 5.5 / Sonnet 5.5 / Fable 5.1 → downgrade to `auto` + instruction (+ `strict`) and report a
    `ProviderNotice`.
  * Ollama → unsupported, so omit and instruct.
  * llama.cpp → `"required"` works (string); a specific tool is unsupported, so use `required` + restrict `tools` to
    that one... **but** changing `tools` invalidates Anthropic thinking, which is irrelevant for llama.cpp.
* **`ReasoningSignature`:** also needs `kind` (anthropic-thinking | anthropic-redacted | openai-encrypted-reasoning |
  openrouter-reasoning-details | chatcompat-field-name) plus the producing provider, model and account, so replay
  sends it only to a compatible target (§7.9.4–5).
* **`ProviderKind`:** split *wire protocol* (`openAiChat`, `openAiResponses`, `anthropicMessages`) from
  *server flavor* (`openai, llamacpp, ollama, lmstudio, vllm, openrouter, hf, deepseek, generic`). A flavor selects a
  quirk profile (§2).

---

## Recommendations for Sherpa

1. **Implement three wire adapters behind `ModelProvider`, sharing one SSE parser and one tool-call accumulator:**
   * **(A)** `AnthropicMessagesProvider` (native; never the compat layer).
   * **(B)** `OpenAiChatProvider` with server-flavor profiles: llama.cpp, Ollama, LM Studio, vLLM, OpenRouter, HF,
     DeepSeek, generic.
   * **(C)** `OpenAiResponsesProvider`, used by default only for `api.openai.com`. Run it stateless: `store:false`,
     replay `encrypted_content`.

   If OpenAI first-party is out of v1 scope, ship A+B and keep C as v1.1. Do not claim tool support for GPT-5.4+
   reasoning models over Chat.
2. **Make the transcript append-only by construction for Anthropic.** Freeze `system` and `tools` per conversation
   segment.
   * Express dynamic instructions as appended `role:"system"` messages (supported models) or as a trailing text block
     after `tool_result`s.
   * Disable tools with `tool_choice:{type:"none"}`, not by removing them.
   * Implement `ContextOverlay`/`PartRewrite` only for flavors without signed reasoning (local servers). For
     Anthropic, compaction = "simple compaction" into a new segment, plus optional server `clear_tool_uses_20250919`.
   * Ship a debug assertion that diffs consecutive request bodies (prefix must be identical).
3. **Drive per-model behavior from discovery, not constants.** Use Anthropic `GET /v1/models` (`max_input_tokens`,
   `max_tokens`, `capabilities.thinking.types.*`, `effort.*`, `structured_outputs`, `image_input`, `pdf_input`) and
   per-flavor probes (§5, §6). Keep a small bundled fallback table for OpenAI (no context field in the API) and for
   offline cold start.
4. **Never send sampling params to Anthropic unless the user explicitly sets them and the model allows them.** Never
   send forced `tool_choice` to Opus 5.5 / Sonnet 5.5 / Fable 5.1. Send `display:"summarized"` when the UI shows
   reasoning. Set `output_config.effort` explicitly (Opus 5.5 defaults to `medium`).
5. **Reasoning I/O union.** Read `reasoning_content` ?? `reasoning` ?? `reasoning_details` (OpenRouter), with a
   `<think>` tag splitter as a per-profile fallback. Persist the exact field and the original value on the
   `ReasoningPart`. Replay rules:
   * DeepSeek with tools: `reasoning_content` on **every** prior assistant turn (else 400).
   * OpenRouter: `reasoning_details` unmodified.
   * vLLM: `reasoning`.
   * llama.cpp: `reasoning_content`.
   * Ollama: `reasoning`.
   * OpenAI Chat: none.
6. **Always request usage:** `stream_options:{include_usage:true}` on Chat flavors that support it (OpenAI,
   llama.cpp, Ollama, LM Studio ≥0.3.18, vLLM). Treat the OpenRouter usage frame as accounting only. For context
   meters on llama.cpp, prefer `timings` (`prompt_n + cache_n + predicted_n`) together with `/props n_ctx`.
7. **Anthropic streaming:** set `eager_input_streaming:true` on client tools, validate tool input against the JSON
   schema before execution, check `stop_reason` (`max_tokens`/`refusal`) before running tools, and return
   `INVALID_JSON` error results.
8. **Error and retry policy:** add `ProviderErrorKind.quota`. Retry only before the first emitted delta. Honor
   `retry-after`/`Retry-After`. Treat 529/503 as overloaded. For a resume after partial output on Anthropic 4.6+,
   continue via a user message, never via prefill. Surface `request-id`/`x-request-id` in diagnostics.
9. **Tool naming:** sanitize to `^[a-zA-Z0-9_-]{1,64}$` (the strictest common denominator: OpenAI 64, Anthropic 128).
   Keep a reversible map to MCP names. Tool results with images go to Anthropic `tool_result` image blocks; for
   OpenAI Chat, use a follow-up user message with `image_url`.
10. **Media:** downscale images on device (≤2576 px long edge for Claude 4.7+, ≤1568 px for others) before base64
    encoding. Enforce the 32 MB Anthropic request cap and the 10 MB per-image cap.
11. **Golden-file tests:** add §9 fixtures F1–F5 (plus variants a–e and the llama.cpp error tail). Test chunk
    boundary fuzzing: split each fixture at every byte offset and re-feed it, so UTF-8 decoding, line splitting and
    JSON fragment accumulation are exercised.

---

## Risks

* **OpenAI drift away from Chat Completions:** tools already require Responses on the newest models, and Chat may lose
  more features. Mitigation: adapter C plus flavor detection.
* **Preserved-thinking 400s for every new Anthropic account** if any code path rewrites history: overlays, a model
  switch that re-renders the system prompt, tool toggles, re-encoding images, or deleting reminders. These fail hard
  (400), not degrade. `drop_block` keeps requests alive but raises output tokens (Anthropic measured +4.5% at high
  effort per single drop, up to +67% at max when dropping every turn).
* **Account-bound thinking** (Sonnet 5.5 / Haiku 5.5): conversations exported or imported between users or API keys,
  or a user rotating to a key in another org, silently lose reasoning or fail. A model switch also drops reasoning
  silently.
* **Field-name drift in compat servers:** vLLM renamed `reasoning_content`→`reasoning`, LM Studio uses both by model
  or setting, and llama.cpp still uses `reasoning_content`. Silent empty reasoning is the failure mode.
* **llama.cpp silently ignores the object-form `tool_choice`**, and Ollama ignores `tool_choice` entirely, so forced
  tools may not be forced. Parallel calls depend on the template.
* **Ollama's default context is 4k on <24 GiB VRAM:** an agent system prompt plus tool schemas can overflow it. How
  Ollama truncates (or errors) is **UNVERIFIED**. Must detect via `/api/ps` and warn.
* **Mobile transport:** long thinking turns (minutes) versus iOS/Android background socket suspension; cellular
  handoffs mid-stream. Partial tool or thinking blocks cannot be resumed. Platform behavior not re-verified in this
  session.
* **Cleartext and LAN access** to local servers: iOS ATS / local-network permission, and Android
  `usesCleartextTraffic` / network security config. Not re-verified here.
* **Billing surprises:** some refusal categories are billed before output; fallback models cost differently; 1 h
  cache writes cost 2×; OpenAI prompts over 272K are billed at 2× input.
* **Beta churn:** context editing, two compaction betas, mid-conversation tool changes, thinking display updates,
  binding controls. Gate everything behind capability flags and an `anthropic-beta` allowlist (an unknown beta value
  causes a 400).

---

## Open questions for the product owner

1. Is **api.openai.com (first-party) a v1 target**? If yes, we must ship the Responses adapter in v1 (tools plus
   reasoning are unavailable over Chat Completions on GPT-5.4+/GPT-6).
2. Should we **show model reasoning** by default (Anthropic `display:"summarized"`, OpenRouter/vLLM/llama.cpp
   reasoning text), or only progress notes? It affects time-to-first-text and UI.
3. Default **effort per provider/model**, and do we expose `xhigh`/`max` (cost)?
4. **Refusal handling on Anthropic:** opt into server-side `fallbacks:"default"` (silently answers with another
   model, different price), or surface the refusal and let the user retry?
5. May users **toggle tools or edit the system prompt mid-conversation**? With preserved thinking that must become
   "start a new segment" or use beta tool-change blocks.
6. Which **Anthropic betas** may Sherpa send (context editing, compaction, memory tool, server tools like
   web_search/code_execution)? Server tools move data and execution off-device, which is a privacy indicator
   question.
7. **OpenAI `store`:** default `store:false` (stateless, privacy-friendly; Responses stores by default for 30+ days)?
8. Which compat servers are **officially supported** (CI test matrix): llama.cpp, Ollama, LM Studio, vLLM,
   OpenRouter, HF, DeepSeek?
9. Do we also support **Anthropic-wire local servers** (llama.cpp, LM Studio, vLLM and Ollama all expose
   `/v1/messages`), or standardize local servers on Chat Completions?
10. How do we handle **cross-account conversation portability** (export/import, shared sessions) given account-bound
    thinking signatures?

---

## Verification log (10 most load-bearing claims)

| # | Claim | Evidence (fetched 2026-10-18) | Status |
|---|---|---|---|
| 1 | Chat Completions: no tool calling for GPT-6 Astra / GPT-6.1 Sol; GPT-6 Sol/Luna tools only with `reasoning_effort:"none"`; "Starting with GPT-5.4, Chat Completions does not support tool calling with `reasoning_effort` values other than `none`." | developers.openai.com/api/docs/guides/latest-model.md (lines "Tool calling: Use the Responses API..."), …/guides/reasoning.md, …/guides/migrate-to-responses.md | Verified (3 pages agree) |
| 2 | Chat chunk schema: `delta.tool_calls[{index (required), id?, type?, function{name?, arguments?}}]`; `finish_reason ∈ {stop,length,tool_calls,content_filter,function_call}`; `include_usage` → extra final chunk with `choices: []`; `usage.prompt_tokens_details.cached_tokens`, `completion_tokens_details.reasoning_tokens` | developers.openai.com/api/reference/resources/chat/subresources/completions/streaming-events.md; chat.md create params; openai-python `_deltas.py` | Verified |
| 3 | Anthropic SSE event set and delta types (`text_delta`, `input_json_delta`, `thinking_delta`, `signature_delta`, `citations_delta`), cumulative usage in `message_delta`, `ping`, `event: error` with `overloaded_error` | platform.claude.com/docs/en/build-with-claude/streaming.md; api/messages/create.md (RawMessageStreamEvent) | Verified |
| 4 | Thinking blocks must be passed back unmodified within tool loops; preserved-thinking prefix check enforced by default for accounts created ≥ 2026-08-31 (Fable 5.1, Opus 5.5, Sonnet 5.5, Haiku 5.5); tool add/remove and `system` change invalidate later blocks | build-with-claude/thinking.md §Preserving thinking blocks / §Preserved thinking; build-with-claude/preserved-thinking.md "What counts as an edit", "When the API enforces the check" | Verified |
| 5 | Forced `tool_choice` (`any`/`tool`) → 400 on Opus 5.5, Sonnet 5.5, Fable 5.1, Mythos 5.1; non-default sampling params → 400 on current 5.x / 4.7+; Opus 5.5 rejects `disabled` and `budget_tokens`, default effort `medium` | thinking.md §Limits and feature compatibility and §Configuring thinking table; models/overview.md | Verified |
| 6 | Anthropic `/v1/models` exposes `max_input_tokens`, `max_tokens`, `capabilities{thinking.types, effort, context_management, ...}`, `line`, `lifecycle` | platform.claude.com/docs/en/api/models/list.md; models/overview.md "Using the Models API" | Verified |
| 7 | llama.cpp streams `delta.reasoning_content`, tool-call fragments with `id`/`type` only on the first fragment, final `choices: []` usage chunk plus `timings{cache_n,prompt_n,...,predicted_per_second}`, `":"` keep-alive comments, mid-stream `data: {"error":{...}}` with no `[DONE]`; `/props default_generation_settings.n_ctx`; `/v1/models owned_by:"llamacpp"`, `meta.n_ctx/n_ctx_train`; string-only `tool_choice`; `--jinja` default enabled | local source tools/server/{server-chat.cpp, server-task.cpp, server-context.cpp, server-common.cpp, server-schema.cpp}, common/chat.cpp; upstream raw README.md, server-chat.cpp, server-context.cpp, server-common.cpp, common/arg.cpp | Verified (local + upstream agree) |
| 8 | vLLM output field is `reasoning` ("used to be called `reasoning_content`"), input normalizes the old name; `--enable-auto-tool-choice` mandatory for auto; `/v1/models` `owned_by:"vllm"`, `max_model_len`; `/version` | vllm docs/features/reasoning_outputs.md, tool_calling.md; vllm/entrypoints/openai/chat_completion/protocol.py; serve/engine/protocol.py; serve/instrumentator/basic.py | Verified |
| 9 | Ollama `/v1`: `delta.reasoning`; `tool_choice` unsupported; `max_tokens` only; tool calls emitted whole; context default by VRAM (4k/32k/256k); `/api/show model_info.<arch>.context_length`; `/api/ps models[].context_length` | docs.ollama.com/api/openai-compatibility.md, context-length.md, api-reference/show-model-details.md; ollama openai/openai.go; api/types.go `ProcessModelResponse.ContextLength` | Verified |
| 10 | DeepSeek: with `tools`, `reasoning_content` of all prior turns must be passed back or the API returns 400; OpenRouter: pass `reasoning_details` back unmodified, usage chunk repeats `finish_reason` with non-empty `choices` | api-docs.deepseek.com/guides/thinking_mode; openrouter.ai/docs/guides/best-practices/reasoning-tokens.md, api/reference/streaming.md | Verified |

Notable items left **UNVERIFIED** (see inline marks):

* the OpenAI Chat mid-stream error shape;
* whether OpenAI Responses sends `[DONE]`;
* `redacted_thinking` streaming shape;
* LM Studio's current default reasoning field;
* HF router and DeepSeek parameter details;
* vLLM `/tokenize` shape;
* Ollama truncation behavior;
* exact context-overflow error messages on OpenAI and Anthropic.
