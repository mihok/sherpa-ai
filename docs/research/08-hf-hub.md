# 08 — Hugging Face Hub: browse, download, auth, router, safety, naming

Research digest for Sherpa's model browser, downloader, device-fit engine and model-name parser.
Researched **2026-10-18** against the live Hub (`curl https://huggingface.co/api/...` from a US-East egress, anonymous),
the published OpenAPI spec (`https://huggingface.co/.well-known/openapi.json`, 299 paths), huggingface.co/docs,
`huggingface_hub` `main` (`hf_api.py`, `utils/_http.py`, `_oauth.py`), `huggingface.js` (`oauth-*.ts`) and the vendored
llama.cpp in `/opt/vendor-src/llama-py/llama_cpp_python-0.3.36/vendor/llama.cpp` (quantize.cpp, ggml.h, llama.h, gguf-py,
common/download.cpp).

Evidence tags used below:

- **LIVE** — observed in a live HTTP call on 2026-10-18 (response pasted, trimmed with `...`).
- **DOCS** — stated on huggingface.co/docs (quoted or paraphrased).
- **SRC** — read in source code (file named).
- **UNVERIFIED** — not reproduced here; treat as a hypothesis to test.

All downloaded content was treated as untrusted data (parsed with `python3 -I`, never executed).
Model names below include many 2026 releases (Qwen3.8, Gemma 4, Muse-Spark, ...) — they are verbatim live data, not typos.

---

## 0. Key facts (TL;DR)

1. `GET /api/models` accepts `search, author, filter (repeatable or comma = AND), pipeline_tag, apps, gated, inference,
   inference_provider, num_parameters, sort, direction, limit (cap 1000), full, config, cardData, expand[]`.
   `library=` is **silently ignored** — filter libraries with `filter=gguf|mlx|...` (LIVE).
2. Sort values accepted: `trendingScore` (default), `downloads`, `likes`, `likes30d` (undocumented), `lastModified`,
   `createdAt`. **Only `createdAt` accepts `direction=1`**; all others 400 "only descending sort is supported" (LIVE).
3. Using `expand[]` replaces the default field set: response contains only `_id`, `id`, the sort key and the requested
   fields. Allowed list values: 30 names (exact list in §2.4) — single-model endpoint additionally allows
   `childrenModelCount`, `usedStorage` (LIVE, from the 400 validation error).
4. Pagination = RFC 8288 `Link: <...&cursor=...>; rel="next"`; the cursor is opaque (base64 of a Mongo query); a bad
   cursor → `400 {"error":"Error parsing pagination cursor"}` (LIVE). Tree listing paginates the same way.
5. Repo-level `gguf` summary (`total`, `architecture`, `context_length`, `chat_template`, `bos_token`, `eos_token`,
   `totalFileSize`, ...) describes **one arbitrary file** of the repo — observed picking an MTP draft (903 MB) in a 27B
   repo and the IQ4_NL file in another. Never use it as the size of the file the user will download (LIVE).
6. `safetensors.total` is the **logical** parameter count even for packed GPTQ/AWQ/MLX weights (I32/U32 counted
   unpacked), so it is a good "model size" truth; dtype keys don't reveal bit width (LIVE).
7. Downloads: `/{repo}/resolve/{rev}/{path}` → for LFS/Xet files **302** to a CloudFront-signed URL
   `https://us.aws.cdn.hf.co/xet-bridge-us/{repo _id}/{xetHash}?...Expires=...&Signature=...&Key-Pair-Id=...` valid
   **3600 s**; small non-LFS files → **307** to a relative `/api/resolve-cache/models/{repo}/{commit}/{path}?...` (LIVE).
8. **HTTP Range + resume works on Xet-backed files** through the bridge: `206`, `Content-Range: bytes 0-99/657289344`,
   open-ended tail ranges, `416` past EOF; HEAD on the CDN URL returns full `Content-Length` (LIVE).
9. The CDN **ignores `If-Range`** (mismatched validator still returned 206) and its `ETag` is the **Xet hash**, not
   SHA-256. Hub's 302 carries `X-Linked-Size`, `X-Linked-ETag` (= LFS SHA-256), `X-Xet-Hash`, `X-Repo-Commit` (LIVE).
10. Expired signed URL → `403 text/plain "Auth failed: credentials expired"` → re-resolve and continue with Range (LIVE).
11. Non-LFS files may come back `Content-Encoding: gzip` with a weak `ETag W/"..."` and no `Content-Length` when the
    client advertises gzip — send `Accept-Encoding: identity` for byte-exact resume (LIVE).
12. Rate limits (5-min fixed windows, IETF draft headers): anonymous **api 500 / resolvers 3000 / pages 100** per IP;
    free user 1000/5000/200; PRO 2500/12000/400 (DOCS). Headers seen: `ratelimit: "api";r=425;t=157`,
    `ratelimit-policy: "fixed window";"api";q=500;w=300` (LIVE). We got throttled once from a shared egress IP:
    `{"error":"We had to rate limit your IP (...)...","retryAfter":48}` (LIVE body).
13. Gated repos: metadata, tree and `cardData.extra_gated_*` are public; file content without auth →
    `401` + `X-Error-Code: GatedRepo` + `X-Error-Message: Access to model X is restricted...` (LIVE). `gated` is
    `false | "auto" | "manual"` (LIVE: 129 auto / 71 manual in a sample of 200 gated repos).
14. Missing repo, or bad token on `/api/whoami-v2` → `401 {"error":"Invalid username or password."}` (no error code)
    — indistinguishable from "private" by design. Missing file → `404 X-Error-Code: EntryNotFound`; bad rev →
    `404 X-Error-Code: RevisionNotFound` (LIVE).
15. OIDC discovery (LIVE): `authorization_endpoint /oauth/authorize`, `token_endpoint /oauth/token`,
    `device_authorization_endpoint /oauth/device`, `registration_endpoint /oauth/register`, `jwks_uri`, PKCE **S256 only**,
    grants `authorization_code, refresh_token, device_code, token-exchange`, `client_id_metadata_document_supported: true`.
    Server enforces `code_verifier` ≥ 43 chars (LIVE).
16. Public (secretless) OAuth apps are supported for native apps; redirect URIs must match exactly; custom schemes
    (`myapp://callback`) are allowed but exact-match; `http` loopback accepts any port (DOCS).
    Scopes: `openid profile email read-billing read-memberships read-repos gated-repos contribute-repos write-repos
    manage-repos read-collections write-collections inference-api read-endpoints write-endpoints jobs webhooks
    write-discussions` (DOCS).
17. Inference Providers router: `https://router.huggingface.co/v1` (OpenAI-compatible, chat only). `GET /v1/models`
    is **public** and lists per-provider `supports_tools`, `context_length`, `pricing`, `throughput` (LIVE, 133 models,
    14 providers). Model suffixes: `:<provider>`, `:fastest` (default), `:cheapest`, `:preferred` (DOCS).
18. Security: `?securityStatus=true` → `securityRepoStatus {scansDone, filesWithIssues[]}`; `/api/models/{repo}/scan`
    same shape; `tree?expand=true` / `paths-info expand=true` → per-file `securityFileStatus` with protectAi, ClamAV,
    pickleImportScan (imports + `safety: innocuous|dangerous`), VirusTotal, JFrog (LIVE, incl. a real `unsafe` file).
19. llama.cpp (vendored) GGUF quant set: 41 ftypes incl. new **Q1_0 (1.125 bpw)**, **Q2_0 (2.25)**, **NVFP4 (4.5)**,
    **MXFP4_MOE**; `Q4_0_4_4/4_8/8_8` and `IQ4_NL_4_4/...` are **removed** (files fail to load) (SRC).
20. Name-implied bpw is unreliable for small models: `unsloth/gemma-3-270m-it` **Q2_K = 7.07 effective bpw**
    (262k-vocab embeddings dominate); for 30B MoE it is 2.95 (LIVE sizes). The device-fit engine must use real file
    bytes from `tree`/`paths-info`, not names.
21. GGUF metadata (arch, ctx, layers, heads, `general.size_label`, `general.file_type`, chat template) sits at the file
    head; for a 128k-vocab model the KV + tensor-info section ended at **7.83 MB** — fetch with one Range request (LIVE).
22. Sidecar roles in GGUF repos: `mmproj` (vision/audio projector), `mtp-`, `dflash-`, `eagle3-`, `dspark-`
    (speculative drafts), `imatrix` (calibration), `.layout.json`; llama.cpp's own `-hf` picker excludes these (SRC).
23. Sharding patterns seen: llama.cpp `-00001-of-00003.gguf` (5 digits); quant-per-folder `UD-IQ1_S/...-00001-of-00005.gguf`;
    mradermacher raw byte splits `.gguf.part1of2` (must concatenate); safetensors `model-00001-of-000002.safetensors`
    (6 digits) and `model.safetensors-00001-of-00002.safetensors` (LIVE).

---

## 1. Base URLs, headers, conventions

| Purpose | URL |
|---|---|
| Hub API | `https://huggingface.co/api/...` |
| File download | `https://huggingface.co/{namespace}/{repo}/resolve/{rev}/{path}` (models have no `models/` prefix; datasets use `/datasets/...`) |
| OpenAPI | `https://huggingface.co/.well-known/openapi.json` / `.md` (DOCS: the old docs/hub/api page now redirects there) |
| OIDC | `https://huggingface.co/.well-known/openid-configuration` |
| Router | `https://router.huggingface.co/v1` |
| Xet CAS | `https://cas-server.xethub.hf.co` (only for native Xet clients) |

Notes (LIVE unless stated):

- The OpenAPI spec does **not** document `GET /api/models` or `GET /api/models/{repo}` (only sub-resources) — behaviour
  below is from live probing + `huggingface_hub`.
- `Access-Control-Expose-Headers: X-Repo-Commit,X-Request-Id,X-Error-Code,X-Error-Message,X-Total-Count,ETag,Link,Accept-Ranges,Content-Range,X-Linked-Size,X-Linked-ETag,X-Xet-Hash`
  — this is the canonical list of headers a client should read.
- Errors: JSON `{"error": "..."}` on `/api/*` plus `X-Error-Code` / `X-Error-Message` headers; `text/plain` bodies on
  `/resolve/`. Always branch on `X-Error-Code` first, status second.
- Unauthenticated downloads get `x-hf-warning: unauthenticated; Warning: You are sending unauthenticated requests to the
  HF Hub. Please set a HF_TOKEN to enable higher rate limits and faster downloads.`
- `expand[]=x` and `expand=x` are both accepted (server echoes `expand=x` in `Link`).
- An **invalid** bearer token on a public read (`/api/models/{repo}`, `/resolve/` of a public file) was **ignored**
  (200/307), but `/api/whoami-v2` → 401. Validate tokens explicitly via `whoami-v2` at sign-in.

---

## 2. `GET /api/models` — search / browse

### 2.1 Parameters

| Param | Verified behaviour |
|---|---|
| `search` | Case-insensitive substring over full `author/name` (LIVE: `search=bartowski/Llama-3.2-1B` matches; `search=qwen3%20coder` matches ids containing both words). |
| `author` | Exact namespace. |
| `filter` | Tag filter; repeat or comma-separate = **AND** (LIVE: `filter=gguf&filter=mlx` ≡ `filter=gguf,mlx`). Works for library tags (`gguf`, `mlx`, `onnx`, `tflite`, `executorch`, `coreml`, `transformers`, `safetensors`, `litert-lm`), pipeline tags, `conversational`, `4-bit`, `8-bit`, `gptq`, `awq`, `exl3`, `imatrix`, `moe`, `license:apache-2.0`, `base_model:quantized:Qwen/Qwen3-8B`, `dataset:...`, free-form user tags (`tool-use`, `function-calling`). |
| `library` | **Ignored** (LIVE: results identical to no filter). Use `filter`. |
| `pipeline_tag` | e.g. `text-generation`, `image-text-to-text`, `feature-extraction`, `sentence-similarity`, `automatic-speech-recognition` (52 values in `/api/models-tags-by-type`). |
| `apps` | Enum (LIVE, from 400): `llama.cpp, lmstudio, jan, drawthings, diffusionbee, joyfusion, vllm, ollama, mlx-lm, docker-model-runner, lemonade, sglang, unsloth, pi, hermes-agent, atomic-chat, openclaw`. Useful: `apps=llama.cpp`, `apps=mlx-lm`. |
| `gated` | `true` / `false`. |
| `inference` | `warm` → served by ≥1 provider. |
| `inference_provider` | `all` or a provider name. |
| `num_parameters` | `min:1B,max:4B` (SRC hub docstring; LIVE works) — but for GGUF repos it matches the unreliable repo-level `gguf.total` (a 27B repo matched `max:4B` because its summary came from a 1.86B draft file). |
| `sort` | `trendingScore` (default when omitted), `downloads` (30-day), `likes`, `likes30d` (undocumented, LIVE), `lastModified`, `createdAt`. `downloadsAllTime` → `400 ✖ Invalid sort parameter`. |
| `direction` | `-1` default. `1` only for `createdAt`; else `400 {"error":"Invalid sort direction, only descending sort is supported for downloads"}`. huggingface_hub no longer sends `direction`. |
| `limit` | Max **1000** (LIVE: `limit=1001` returned 1000). Use 20–50 for UI pages. |
| `full=true` | Adds `author, gated, lastModified, sha, config(?), siblings[{rfilename}]`; no sizes. If `expand` is also sent, `expand` wins (server) — the Python client refuses the combo. |
| `config=true` | Adds summarized `config`. |
| `cardData=true` | Adds `cardData` (license, base_model, gated prompts...). |
| `expand[]` | See 2.4. Mutually exclusive with full/config/cardData in the client lib. |
| `cursor` | From `Link` only. Opaque. |

### 2.2 Default response item (LIVE, trimmed)

```json
GET /api/models?author=bartowski&search=Llama-3.2-1B-Instruct-GGUF&limit=1
[{"_id":"66f457ed2dc07e76a1bde8d6","id":"bartowski/Llama-3.2-1B-Instruct-GGUF","likes":184,
  "trendingScore":0,"private":false,"downloads":155390,
  "tags":["gguf","facebook","meta", "...(+17 more)"],
  "pipeline_tag":"text-generation","createdAt":"2024-09-25T18:35:25.000Z",
  "modelId":"bartowski/Llama-3.2-1B-Instruct-GGUF"}]
```

`library_name` appears only when set (often absent for GGUF repos). `trendingScore` is present when sorting by trend.

### 2.3 Pagination (LIVE)

```
link: <https://huggingface.co/api/models?author=unsloth&filter=gguf&sort=downloads&direction=-1&limit=3&cursor=eyIkb3IiOlt7ImRvd25sb2Fkcy...>; rel="next"
```

Cursor decodes to `{"$or":[{"downloads":1869350,"_id":{"$gt":"688b..."}},...],"searchSequenceToken":"..."}` — treat as
opaque; it embeds the last item's sort value, so it is stable under insertions but can skip/duplicate when
downloads change between pages (dedupe by `_id` client-side). No `X-Total-Count` on this endpoint.

### 2.4 `expand[]` values (LIVE, from validation error)

List endpoint accepts exactly:
`author, baseModels, cardData, config, createdAt, disabled, downloads, downloadsAllTime, evalResults, gated, inference,
inferenceProviderMapping, lastModified, library_name, likes, mask_token, model-index, pipeline_tag, private, safetensors,
sha, siblings, spaces, tags, transformersInfo, trendingScore, widgetData, gguf, resourceGroup, xetEnabled`.
Single-model endpoint additionally: `childrenModelCount, usedStorage`. Unknown value →
`400 {"error":"✖ Invalid option: expected one of \"author\"|...\n  → at expand[0]"}`.

Recommended browse query (one request per page, includes everything a card needs):

```
GET /api/models?filter=gguf&pipeline_tag=text-generation&sort=trendingScore&limit=30
    &expand[]=downloads&expand[]=likes&expand[]=lastModified&expand[]=gated&expand[]=tags
    &expand[]=pipeline_tag&expand[]=library_name&expand[]=safetensors&expand[]=gguf&expand[]=siblings
```

Real trimmed item with expands (LIVE):

```json
{"_id":"6acce01c0fdd3575a646b079","id":"ggml-org/vllm-d3-mini-GGUF",
 "cardData":{"license":"apache-2.0","pipeline_tag":"image-text-to-text","tags":["gguf","quantized","decision-model"],"base_model":["vllm-sr/d3-mini"]},
 "gated":false,"inferenceProviderMapping":[],"lastModified":"2026-10-12T13:27:04.000Z","trendingScore":8,
 "sha":"c03ac9c3bdc5ae949111acb945338933f396e4d7","downloadsAllTime":5499,
 "gguf":{"total":4841450496,"architecture":"qwen35","context_length":262144,"causal":false,
         "chat_template":"{%- set image_count = namespace(value=0) %}...[7756 chars]","eos_token":"<|im_end|>",
         "decision_type":"vllm-d3","totalFileSize":9695793600},
 "pipeline_tag":"image-text-to-text",
 "siblings":[{"rfilename":".gitattributes"},{"rfilename":".src_sha"},{"rfilename":"README.md"},"...(+6 more)"],
 "xetEnabled":true}
```

Note: `gguf` can carry extra keys (`causal`, `decision_type`, `quantize_imatrix_file`) — parse leniently.
Note: list-endpoint `siblings` have **no sizes**; sizes need `tree` / `paths-info` / `?blobs=true` on the single endpoint.

`inferenceProviderMapping` in **list** responses is an **array** (LIVE):

```json
{"_id":"6ad13da0cab7d8264a3d8d60","provider":"baseten","providerId":"meta-models/muse-spark-open","status":"live",
 "task":"conversational","features":{"structuredOutput":true,"toolCalling":true},
 "performance":{"requestLatencyMs":19563,"firstTokenLatencyMs":3694,"tokensPerSecond":129.94},
 "providerDetails":{"context_length":1048576,"pricing":{"input":1.25,"output":4.25}},
 "previousStatus":"live","type":"single-model","isModelAuthor":false}
```

In the **single-model** endpoint it is an **object keyed by provider** (LIVE):
`{"novita":{"status":"live","providerId":"meta-llama/llama-3.1-8b-instruct","task":"conversational","isModelAuthor":false}, ...}`;
empty is `{}` vs `[]`. Model the two shapes separately.

### 2.5 Tag vocabulary (`GET /api/models-tags-by-type`, LIVE)

Keys: `region, library (54), other (8), license (82), language (5620), deploy, dataset, bucket, pipeline_tag (52)`.
`other` = `moe, decision-model, merge, 4-bit, 8-bit, custom_code, eval-results, co2_eq_emissions`.
There is **no official `tool-use` tag**; `tool-use` / `function-calling` exist only as author-supplied tags
(e.g. `lmstudio-community/Llama-3-Groq-8B-Tool-Use-GGUF`). Hub-computed tags seen: `conversational` (repo has a chat
template), `imatrix` (GGUF has `quantize.imatrix.*`), `gguf`, `mlx`, `4-bit`, `gptq`, `awq`, `bitsandbytes`,
`compressed-tensors`, `exl3`, `text-generation-inference`, `endpoints_compatible`, `base_model:quantized:...`.

---

## 3. `GET /api/models/{repo}` and `/api/models/{repo}/revision/{rev}`

Same payload; `/revision/{rev}` pins a branch/tag/commit (URL-encode the rev — branch names like `SC_4.00bpw_H5_V6`
contain dots). Extra query flags (SRC hf_api.py; LIVE): `securityStatus=true` → `securityRepoStatus`;
`blobs=true` → siblings with `blobId`, `size`, `lfs{sha256,size,pointerSize}`. Neither combines with `expand`.

### 3.1 Default fields (LIVE, `bartowski/Llama-3.2-1B-Instruct-GGUF`)

```
_id, id, private, pipeline_tag, tags, downloads, likes, modelId, author, sha, lastModified, gated, disabled,
widgetData, model-index, config, cardData, gguf, siblings, spaces, createdAt, usedStorage
(+ securityRepoStatus when securityStatus=true)
```

```json
{"id":"bartowski/Llama-3.2-1B-Instruct-GGUF","sha":"067b946cf014b7c697f3654f621d577a3e3afd1c",
 "lastModified":"2024-10-08T14:00:29.000Z","gated":false,"disabled":false,"private":false,"config":{},
 "cardData":{"base_model":"meta-llama/Llama-3.2-1B-Instruct","license":"llama3.2","pipeline_tag":"text-generation",
             "quantized_by":"bartowski","extra_gated_prompt":"### LLAMA 3.2 COMMUNITY LICENSE AGREEMENT...[13542 chars]",
             "extra_gated_fields":{"First Name":"text","Date of birth":"date_picker","Country":"country",
                                   "Job title":{"type":"select","options":["Student","..."]},"geo":"ip_location","By clicking Submit ...":"checkbox"},
             "extra_gated_button_content":"Submit"},
 "gguf":{"total":1235814432,"architecture":"llama","context_length":131072,
         "chat_template":"{{- bos_token }}\n{%- if custom_tools is defined %}...[3827 chars]",
         "bos_token":"<|begin_of_text|>","eos_token":"<|eot_id|>","totalFileSize":2479595360},
 "siblings":[{"rfilename":".gitattributes"},{"rfilename":"Llama-3.2-1B-Instruct-IQ3_M.gguf"},"..."],
 "createdAt":"2024-09-25T18:35:25.000Z","usedStorage":17157953114}
```

Field semantics (SRC `ModelInfo` docstring + LIVE):

| Field | Meaning / gotcha |
|---|---|
| `sha` | Commit of the resolved revision. Pin downloads to it (all shards from one commit). |
| `lastModified` | Date of last commit. |
| `downloads` / `downloadsAllTime` | 30-day / cumulative. |
| `gated` | `false`, `"auto"` (instant approval after form), `"manual"` (author reviews). |
| `private`, `disabled` | bool. Disabled repos error with message "Access to this resource is disabled." (SRC). |
| `cardData.license` | SPDX-ish id (`apache-2.0`, `llama3.2`, `gemma`, `other` + `license_name`/`license_link`). Quant repos often copy the base model's license and even its `extra_gated_*` text while being `gated:false` (above). |
| `cardData.base_model` | String or list; with `tags: base_model:quantized:X` / `base_model:finetune:X`. |
| `baseModels` (expand) | `{"relation":"quantized","models":[{"_id":...,"id":"HuggingFaceTB/SmolLM2-135M"}]}` |
| `childrenModelCount` | `{"adapter":75,"merge":2,"quantized":145,"finetune":390}` — great for "find quantizations of X". |
| `usedStorage` | Bytes of **all revisions/files** — not the download size. |
| `xetEnabled` | Repo stored on Xet. |
| `gguf.total` | Param count **of the one file the Hub sampled** (see risk). `totalFileSize` = that file (or its shard set). Observed samples: bartowski 1B → the f16 file; unsloth 30B → IQ4_NL file; HauhauCS 27B → `...-FastMTP-32K.gguf` draft (total 1.86B). Selection heuristic UNVERIFIED. |
| `safetensors` | `{"parameters":{"BF16":134515008},"total":134515008}`; GPTQ example `{"I32":6525288448,"F16":1090328064}` (= 7.6B logical); MLX 4-bit `{"U32":4022272000,"BF16":196096}`. |
| `config` (summary) | `architectures`, `model_type`, `quantization_config:{bits, quant_method}`, `tokenizer_config:{bos_token, eos_token, pad_token, unk_token, chat_template}`, `chat_template_jinja` (when `chat_template.jinja` exists). Group size and other details require fetching `config.json` itself. |
| `transformersInfo` | `{"auto_model":"AutoModelForCausalLM","pipeline_tag":"text-generation","processor":"AutoTokenizer"}` |
| `inference` (expand, single) | `"warm"` or absent. |

### 3.2 `?securityStatus=true&blobs=true` (LIVE)

```json
"securityRepoStatus":{"scansDone":false,"filesWithIssues":[]},
"siblings":[{"rfilename":".gitattributes","blobId":"b051f4c2...","size":2842},
            {"rfilename":"Llama-3.2-1B-Instruct-IQ3_M.gguf","blobId":"a50e6536...","size":657289344,
             "lfs":{"sha256":"c80cc062a721c267ec50fee83fe6b55d36fc7abe708392dbe22e16fbd42687e8","size":657289344,"pointerSize":134}}]
```

`blobs=true` is the cheapest way to get **every file size + sha256 in one call** for small repos.

---

## 4. Files: tree, paths-info, treesize, refs

### 4.1 `GET /api/models/{repo}/tree/{rev}[/{path}]` (DOCS OpenAPI + LIVE)

Params: `recursive` (bool), `expand` (bool: adds `lastCommit` + `securityFileStatus`), `limit`
("1.000 by default, 100 by default for expand=true"), `cursor`. Pagination via `Link` (LIVE):

```
link: <https://huggingface.co/api/models/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF/tree/main?expand=false&recursive=true&limit=3&cursor=ZXlKbWFXeGxYMjVoYldVaU9p...>; rel="next"
```

Entries (LIVE, trimmed; directories included in recursive mode with `size:0`):

```json
{"type":"directory","oid":"03170ee52d8843bc8ccfb6afe6ebc10efd6b9429","size":0,"path":"BF16"}
{"type":"file","oid":"6f90dc5522a79372c17e084217e9dac8d496c1d7","size":49655154016,
 "lfs":{"oid":"c432d5b64272ae30f0df02326619557a1994b034c40139c6e8d7dce928142845","size":49655154016,"pointerSize":136},
 "xetHash":"5ac0a558ac478344b891e6a1897296038d8cd2c55c43e249a5ba3ec710020cb6",
 "path":"BF16/Qwen3-Coder-30B-A3B-Instruct-BF16-00001-of-00002.gguf"}
```

With `expand=true` each entry adds `"lastCommit":{"id","title","date"}` and `securityFileStatus` (§10).
`oid` = git blob sha1; `lfs.oid` = SHA-256 of content (the integrity hash to verify); `xetHash` = Xet content hash
(= CDN `ETag`). Non-LFS files have no `lfs`/`xetHash`.

### 4.2 `POST /api/models/{repo}/paths-info/{rev}` (LIVE)

JSON `{"paths":[...],"expand":false}` or form `paths=a&paths=b&expand=true`. Returns the same entry shape for the
requested paths only; **unknown paths are silently omitted** (no error) — detect by diffing. Ideal for "selected
quant + its shards + mmproj" sizing without listing a 300-file repo.

### 4.3 `GET /api/models/{repo}/treesize/{rev}/{path}` (LIVE)

`{"path":"/BF16","size":61095806048}` — total bytes under a folder (unsloth puts multi-shard quants in folders).
Root needs no trailing slash (`/treesize/main/` → 302 to `/treesize/main`).

### 4.4 `GET /api/models/{repo}/refs` (LIVE)

`{"tags":[],"branches":[{"name":"3_5","ref":"refs/heads/3_5","targetCommit":"be6dca10..."}],"converts":[]}`.
Needed for EXL2/EXL3/GPTQ repos that store variants in branches:
`bartowski/L3-8B-Stheno-v3.2-exl2` → `3_5, 4_25, 5_0, 6_5, 8_0, main`;
`turboderp/Qwen3.8-27B-exl3` → `SC_6.00bpw_H6_V6, ..., SC_1.40bpw_H3, 6.00bpw, main`;
`TheBloke/Llama-2-7B-Chat-GPTQ` → `gptq-4bit-128g-actorder_True, gptq-4bit-32g-actorder_True, gptq-4bit-64g-actorder_True`.

---

## 5. Downloads: resolve, redirects, Range/resume, integrity

### 5.1 LFS/Xet file — HEAD without following (LIVE)

```
curl -sI https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-IQ3_M.gguf
HTTP/2 302
content-length: 1108                      <- body length, NOT file size
location: https://us.aws.cdn.hf.co/xet-bridge-us/66f457ed2dc07e76a1bde8d6/6d98e192e0c830d32a001c71ac58d103d67dbe66347c67c75129d99c66e265ee?<signed>
ratelimit: "resolvers";r=2993;t=279
ratelimit-policy: "fixed window";"resolvers";q=3000;w=300
x-repo-commit: 067b946cf014b7c697f3654f621d577a3e3afd1c
accept-ranges: bytes
x-linked-size: 657289344
x-linked-etag: "c80cc062a721c267ec50fee83fe6b55d36fc7abe708392dbe22e16fbd42687e8"   <- sha256 == lfs.oid
x-xet-hash: 6d98e192e0c830d32a001c71ac58d103d67dbe66347c67c75129d99c66e265ee
cache-control: no-store
link: <https://huggingface.co/api/models/bartowski/Llama-3.2-1B-Instruct-GGUF/xet-read-token/067b946c...>; rel="xet-auth",
      <https://cas-server.xethub.hf.co/v1/reconstructions/6d98e192...>; rel="xet-reconstruction-info"
```

Signed URL query keys (LIVE): `response-content-disposition, xip, user_id, X-Xet-Cas-Uid, Expires, Policy, Signature,
Key-Pair-Id, Hash-Algorithm` (CloudFront signed URL). `Expires − now = 3600 s`. Path segment 1 is the repo `_id`,
segment 2 the `xetHash`. `?download=true` on resolve switches disposition to `attachment`.
Old TheBloke repos are also Xet-bridged now (same host). The bridge host previously documented as
`cas-bridge.xethub.hf.co` and LFS `cdn-lfs*.hf.co` were **not** observed — treat the redirect target as opaque
(region/host can vary; UNVERIFIED from other regions).

### 5.2 Range on the bridge (LIVE)

```
curl -L -r 0-99 .../Llama-3.2-1B-Instruct-IQ3_M.gguf
HTTP/2 206
content-type: application/octet-stream
etag: "6d98e192e0c830d32a001c71ac58d103d67dbe66347c67c75129d99c66e265ee"     <- xetHash, not sha256
content-length: 100
content-range: bytes 0-99/657289344
x-hf-cdn-pop: aws-us-east-1
(first bytes: G G U F 03 00 00 00 ...)
```

| Probe on signed URL | Result |
|---|---|
| `Range: bytes=657289000-` (open tail) | 206, `content-range: bytes 657289000-657289343/657289344`, 344 bytes |
| `HEAD` | 200, `content-length: 657289344`, `accept-ranges: bytes`, same ETag |
| `Range: bytes=1000000-1000099` + `If-Range: "<matching etag>"` | 206 |
| same + `If-Range: "deadbeef"` | **206 (If-Range ignored)** |
| `Range: bytes=657289344-...` | `416`, empty body |
| `Authorization: Bearer <bogus>` on CDN | 206 (header ignored) |
| `Expires` tampered to the past | `403 text/plain` `Auth failed: credentials expired` |
| `Accept-Encoding: gzip, br` + Range | 206, no content-encoding (binary not compressed) |

### 5.3 Small (non-LFS) file (LIVE)

```
HEAD .../HuggingFaceTB/SmolLM2-135M-Instruct/resolve/main/config.json
HTTP/2 307
location: /api/resolve-cache/models/HuggingFaceTB/SmolLM2-135M-Instruct/12fd25f77366fa6b3b4b768ec3050bf629380bac/config.json?%2FHuggingFaceTB%2F...=&etag=%2236293b60...%22
x-repo-commit: 12fd25f77366fa6b3b4b768ec3050bf629380bac
x-linked-etag: "36293b6099200eb8aeb55ae2c01bca2ba46d80d0"      <- git blob sha1 (== tree oid)
content-range: bytes 0-9/861                                   (when Range sent)
→ follow: HTTP/2 200, content-length: 861, etag: "36293b60..."
```

With `Accept-Encoding: gzip`, a 2 MB `tokenizer.json` came back `200`, `content-encoding: gzip`,
`etag: W/"f922b179..."`, no content-length. Each small-file fetch costs **2 resolver requests** (307 + target).
The relative `Location` must be resolved against `https://huggingface.co`.

### 5.4 Native Xet (optional)

`GET /api/models/{repo}/xet-read-token/{commit}` (LIVE, anonymous OK for public):
`{"casUrl":"https://cas-server.xethub.hf.co","exp":1792359304,"accessToken":"<408 chars>"}` — TTL 900 s.
The Xet protocol (chunk dedup, reconstruction API) is documented at huggingface.co/docs/xet; implementing it is not
needed for Sherpa — the HTTP bridge supports Range (DOCS: "a legacy client will get a single URL from the bridge").

### 5.5 Download algorithm for Sherpa (derived from the above)

1. Resolve file list + sizes + sha256 via `paths-info` (or `tree`) **at the pinned commit** `sha`.
2. `GET /{repo}/resolve/{sha}/{path}` with redirects **disabled** (`HttpClientRequest.followRedirects = false` in
   dart:io); send `Authorization` only to `huggingface.co`. Read `X-Linked-Size`, `X-Linked-ETag`, `X-Xet-Hash`,
   `Location`. (Whether dart:io forwards `Authorization` across hosts on auto-redirect: UNVERIFIED — avoid relying on it.)
3. Download `Location` with `Range: bytes=<have>-` and `Accept-Encoding: identity`, write to `<file>.part`; persist
   `{url_expires, xetHash, sha256, bytes_done}`.
4. On `403` (expired) / connection loss / app relaunch → re-do step 2 and resume. Because `If-Range` is ignored,
   compare the new `X-Xet-Hash` with the saved one before resuming; mismatch → restart file.
5. Verify `Content-Range` total == expected size; at the end stream-hash SHA-256 and compare with `lfs.oid`
   (CDN ETag is not SHA-256).
6. Parallelism: each shard is an independent resumable job; multiple range segments per file are possible
   (each segment ≥ 64 MB) but count against nothing except bandwidth (only the resolve hits the "resolvers" bucket).
7. iOS background `URLSession` follows redirects itself and caches the signed URL in resume data → resumes after
   1 h will 403; treat that as "re-resolve" not "failure". Android: WorkManager + foreground service for >1 GB.

### 5.6 Peeking GGUF metadata before download (LIVE)

`Range: bytes=0-8388607` on `Llama-3.2-1B-Instruct-Q4_K_M.gguf` and a 60-line parser gave:
`magic GGUF, version 3, n_tensors 147, n_kv 35`; keys `general.architecture=llama`, `general.name=Llama 3.2 1B Instruct`,
`general.basename=Llama-3.2`, `general.size_label=1B`, `general.finetune=Instruct`, `general.file_type=15` (Q4_K_M),
`llama.context_length=131072`, `llama.block_count=16`, `llama.embedding_length=2048`, `llama.attention.head_count=32`,
`head_count_kv=8`, `key_length=64`, `tokenizer.ggml.tokens` (128256), `tokenizer.ggml.merges` (280147),
`tokenizer.chat_template`, `quantize.imatrix.file=...Llama-3.2-1B-Instruct.imatrix`, `quantize.imatrix.chunks_count=125`.
**KV section ended at byte 7,822,851; tensor-info at 7,831,525.** Tensor types: 96×Q4_K, 17×Q6_K, 34×F32
(`token_embd.weight` is Q6_K). Strategy: fetch 2 MB, parse; if truncated, fetch more (big-vocab models need ~8 MB).
These fields feed the device-fit engine (KV-cache bytes = 2 × n_layer × n_ctx × n_head_kv × head_dim × bytes/elem).

---

## 6. Rate limits

DOCS (rate-limits page, "September '25" table; 5-minute fixed windows; org limits are per member):

| Plan | API | Resolvers | Pages |
|---|---|---|---|
| Anonymous (per IP) | 500* | 3,000* | 100* |
| Free user | 1,000* | 5,000* | 200* |
| PRO | 2,500 | 12,000 | 400 |
| Team org | 3,000 | 20,000 | 400 |
| Enterprise | 6,000 | 50,000 | 600 |
| Enterprise Plus | 10,000 | 100,000 | 1,000 |

\* "subject to change over time depending on platform health".

- Buckets: **api** (`/api/*`), **resolvers** (anything with `/resolve/`, incl. `/api/resolve-cache`), **pages** (HTML).
- Headers (LIVE): `ratelimit: "api";r=<remaining>;t=<seconds to reset>`, `ratelimit-policy: "fixed window";"api";q=<quota>;w=300`.
  Present on 200s too — use them proactively (throttle when `r` < 10%).
- 429 (DOCS): "you will receive a 429 Too Many Requests"; huggingface_hub ≥1.2 sleeps `t` seconds when `r=0`,
  else honours `Retry-After` (delay-seconds only) (SRC `_http.py`; retries 408/429/500/502/503/504).
- Observed throttle body (LIVE, IP redacted; status/headers not captured — assumed 429):
  `{"error":"We had to rate limit your IP (x.x.x.x). To continue using our service, create a HF account or login to your existing account, and make sure you ...","retryAfter":48}`
  — note the JSON `retryAfter` field. This happened from a **shared** egress IP well under our own 500 — mobile users
  behind CGNAT/corporate NAT will hit this anonymously. Strongly prefer signed-in requests.
- Budget for Sherpa: one browse page = 1 api call (with expands). Model detail = 1 api call (`?blobs=true` or
  `paths-info`). Avoid per-card detail calls; cache list pages 5–10 min with ETag (`etag: W/"5b5-..."` is returned on
  `/api/models`; If-None-Match support UNVERIFIED).

---

## 7. Auth, tokens, errors, gated access

### 7.1 Tokens

- `Authorization: Bearer hf_...` (user access tokens) or OAuth access tokens (prefix `hf_oauth_...` per DOCS example).
- Roles (DOCS): `read`, `write`, `fine-grained` (recommended for production). Pre-filled creation link from the
  Inference Providers docs: `https://huggingface.co/settings/tokens/new?ownUserPermissions=inference.serverless.write&tokenType=fineGrained`
  ("Make calls to Inference Providers"). Fine-grained permission name for public gated repos (UI: "Read access to
  contents of all public gated repos you can access") and its query-param id: UNVERIFIED.
- Validate with `GET /api/whoami-v2` (401 `Invalid username or password.` on bad token, LIVE).
- Leaked tokens can be revoked by anyone: `POST /api/credentials/revoke {"credentials":[...]}` → always 202 (DOCS).

### 7.2 Error matrix

| Situation | Status | Headers / body | Evidence |
|---|---|---|---|
| Gated file, no token | 401 | `X-Error-Code: GatedRepo`, `X-Error-Message: Access to model meta-llama/Llama-3.2-1B-Instruct is restricted. You must have access to it and be authenticated to access it. Please log in.`, `WWW-Authenticate: Bearer realm="Authentication required"`; same for HEAD | LIVE |
| Gated file, token without accepted terms | 403 | `X-Error-Code: GatedRepo`; message per docs "...is restricted and you are not in the authorized list. Visit https://huggingface.co/{repo} to ask for access." | UNVERIFIED (SRC maps code→GatedRepoError) |
| Gated repo metadata / tree / cardData | 200 | public | LIVE |
| Repo doesn't exist (or private) unauthenticated | 401 | `{"error":"Invalid username or password."}`, no X-Error-Code | LIVE |
| Repo not found with valid token | 404 | `X-Error-Code: RepoNotFound` | SRC (UNVERIFIED live) |
| File not found | 404 | `X-Error-Code: EntryNotFound`, body `Entry not found` | LIVE |
| Bad revision | 404 | `X-Error-Code: RevisionNotFound`, `{"error":"Invalid rev id: nope-branch"}` | LIVE |
| Bad query param | 400 | `{"error":"✖ Invalid sort parameter: bogus"}` (zod-style text) | LIVE |
| Disabled repo | 403? | message `Access to this resource is disabled.` | SRC |
| Org token policy | 403 | "Your token has been revoked by the organization administrator..." | DOCS |
| Expired CDN URL | 403 | `text/plain: Auth failed: credentials expired` | LIVE |

### 7.3 Gated-access UX

- Detect from metadata: `gated` != false → show `cardData.extra_gated_prompt` (markdown, can be 13 KB),
  `extra_gated_fields` (types seen: `text`, `date_picker`, `country`, `checkbox`, `select{options}`, `geo: ip_location`),
  `extra_gated_description`, `extra_gated_button_content`, plus `license`.
- Send the user to `https://huggingface.co/{repo}` in an in-app browser tab (ASWebAuthenticationSession / Custom Tabs)
  where they are already signed in; `auto` repos grant instantly, `manual` can take days.
- API alternative: `POST /{namespace}/{repo}/ask-access` (form fields = the `extra_gated_fields`, response `303` to the
  repo) exists in OpenAPI; whether it accepts OAuth bearer tokens from a third-party app: UNVERIFIED.
- Check access: `HEAD /{repo}/resolve/{sha}/config.json` (or the smallest file) with the token → 302/307 = granted,
  403 GatedRepo = pending/denied. The `gated-repos` OAuth scope is required for OAuth tokens to read gated content.

---

## 8. "Sign in with Hugging Face" (OAuth 2 / OIDC) for a native app

### 8.1 Discovery (LIVE, complete)

```json
{"issuer":"https://huggingface.co","registration_endpoint":"https://huggingface.co/oauth/register",
 "token_endpoint":"https://huggingface.co/oauth/token","authorization_endpoint":"https://huggingface.co/oauth/authorize",
 "userinfo_endpoint":"https://huggingface.co/oauth/userinfo","device_authorization_endpoint":"https://huggingface.co/oauth/device",
 "jwks_uri":"https://huggingface.co/oauth/jwks","response_types_supported":["code"],"response_modes_supported":["query"],
 "id_token_signing_alg_values_supported":["RS256"],"subject_types_supported":["public"],
 "code_challenge_methods_supported":["S256"],"token_endpoint_auth_methods_supported":["client_secret_basic","client_secret_post"],
 "client_id_metadata_document_supported":true,
 "grant_types_supported":["urn:ietf:params:oauth:grant-type:token-exchange","urn:ietf:params:oauth:grant-type:device_code","authorization_code","refresh_token"]}
```

No `scopes_supported` key. `token_endpoint_auth_methods_supported` omits `none` although public apps are documented
and `/oauth/register` accepts `token_endpoint_auth_method: "none"` (OpenAPI) — generic OIDC libraries that validate
discovery strictly (e.g. AppAuth) may need configuration to allow a public client.

### 8.2 Facts

- **Public apps (no secret)**: DOCS — "useful for native apps, CLIs... Public apps authenticate using only the client ID
  (e.g. in device code or authorization code flows with PKCE)". Created at `https://huggingface.co/settings/applications/new`
  (choose "no secret", or delete the secret later).
- **Redirect URIs** (DOCS): exact match required; `http` loopback (`localhost`, `127.0.0.1`, `[::1]`) accepts any port;
  "`https` and custom-scheme (e.g. `myapp://callback`) redirect URIs always require an exact match, port included" →
  custom schemes are accepted. Whether the settings form accepts a reverse-DNS scheme like `ai.sherpa.app:/oauth`
  (no `//`): UNVERIFIED — prefer `sherpa-ai://oauth/callback` or claimed HTTPS app links.
- **Authorize**: `GET /oauth/authorize?client_id&redirect_uri&response_type=code&scope=openid%20profile%20...&state&code_challenge&code_challenge_method=S256[&orgIds=ORG_ID]`
  (huggingface.js `oauthLoginUrl` sends exactly these + `nonce`). Bad client → `400 text/html`, `X-Error-Message: Invalid client_id` (LIVE).
- **Token**: `POST /oauth/token` form `grant_type=authorization_code&code&redirect_uri&client_id&code_verifier`.
  Short verifier → `400 {"error":"invalid_request","error_description":"✖ Too small: expected string to have >=43 characters\n  → at code_verifier"}` (LIVE).
- **Device flow** (RFC 8628, DOCS + LIVE): `POST /oauth/device client_id=...&scope=...` → `device_code, user_code,
  verification_uri` ; poll `POST /oauth/token grant_type=urn:ietf:params:oauth:grant-type:device_code&device_code&client_id`.
  Unknown client → `400 {"error":"invalid_client","error_description":"Client not found, maybe it was deleted"}` (LIVE).
- **Scopes** (DOCS): `openid, profile, email, read-billing, read-memberships, read-repos, gated-repos, contribute-repos,
  write-repos, manage-repos, read-collections, write-collections, inference-api, read-endpoints, write-endpoints, jobs,
  webhooks, write-discussions`. For Sherpa: `openid profile gated-repos inference-api` (+ `read-repos` only if users
  should see their private repos). "Please contact us if you need any extra scopes."
- **Token lifetime**: Spaces OAuth default 8 h (`hf_oauth_expiration_minutes: 480`), max 30 days (DOCS); token-exchange
  tokens 8 h, "No refresh tokens are provided" (DOCS). For a normal OAuth app: `expires_in` returned; huggingface_hub's
  mock returns `expires_in: 28800` + `refresh_token` (SRC mock); huggingface.js has `// refresh_token: string;`
  commented out (SRC). Discovery advertises `refresh_token` grant. → Refresh-token issuance/rotation for public clients:
  UNVERIFIED — must be tested with a real app registration before committing to "stay signed in".
- **userinfo**: `GET /oauth/userinfo` (OAuth tokens only) — `sub, name, preferred_username, picture, profile, website?, email?, email_verified?,
  isPro, canPay? (read-billing), orgs[{sub, name, preferred_username, plan?, canPay?, roleInOrg?, ...}]` (SRC huggingface.js types).
- **CIMD** / **dynamic registration**: `client_id` may be a URL to a JSON metadata doc (`token_endpoint_auth_method:"none"`)
  — meant for websites/MCP clients; not useful for an app-store binary (UNVERIFIED for mobile).

### 8.3 Recommended native flow

Authorization Code + PKCE (S256) through `ASWebAuthenticationSession` (iOS) / Chrome Custom Tabs (Android) with an
exact custom-scheme redirect; store tokens in Keychain/Keystore; device flow as fallback (TV-style, no redirect needed);
"paste a fine-grained token" as an advanced option.

---

## 9. Inference Providers router (OpenAI-compatible)

- Base `https://router.huggingface.co/v1`; `POST /v1/chat/completions` (chat only; DOCS) and `GET /v1/models`.
- Auth: `Authorization: Bearer <HF token>` with fine-grained permission "Make calls to Inference Providers" or OAuth
  scope `inference-api` (DOCS). No auth → `401 text/html` page; bad token → `401 {"error":"Invalid username or password."}` (LIVE).
- Model naming (DOCS): `org/model` (default policy `:fastest` = highest tokens/s), `org/model:fastest`,
  `org/model:cheapest` (lowest output-token price), `org/model:preferred` (user's order in settings),
  `org/model:<provider>` e.g. `openai/gpt-oss-120b:groq`. Failover only in auto mode.
- `GET /v1/models` is **public** (LIVE, 89 KB, 133 models). Entry:

```json
{"id":"meta-models/Muse-Spark-Open-816B-A42B","object":"model","created":1789500199,"owned_by":"meta-models",
 "architecture":{"input_modalities":["text","image"],"output_modalities":["text"]},
 "providers":[{"provider":"baseten","status":"live","context_length":1048576,"pricing":{"input":1.25,"output":4.25},
               "is_free":false,"supports_tools":true,"supports_structured_output":true,
               "first_token_latency_ms":3694,"throughput":129.94,"is_model_author":false}]}
```

  Provider keys: `context_length, first_token_latency_ms, is_free, is_model_author, pricing, provider, status,
  supports_structured_output, supports_tools, throughput` (some providers omit most, e.g. `featherless-ai`).
  Provider counts: deepinfra 72, featherless-ai 67, novita 51, nscale 17, zai-org 17, together 15, cohere 15,
  baseten 10, fireworks-ai 10, scaleway 9, ovhcloud 8, publicai 4, groq 3, cerebras 2 (LIVE).
  Tool support is **per provider**: `meta-llama/Llama-3.1-8B-Instruct` → novita `false`, nscale `false`,
  deepinfra `true` (LIVE). So pin `:deepinfra` (or choose the provider with `supports_tools:true`) when the agent
  needs tools; `:fastest` may route to a provider without tool support.
- Pricing unit appears to be USD per 1M tokens (UNVERIFIED). Billing: pay-as-you-go with monthly credits for PRO/Team (DOCS).
- End-to-end tool-call request/stream behaviour: UNVERIFIED (no token in this environment).

---

## 10. Tool-use / reasoning signals

| Signal | Where | Reliability |
|---|---|---|
| Chat template mentions `tools` / `tool_calls` / tool role | `gguf.chat_template`, `config.tokenizer_config.chat_template`, `config.chat_template_jinja`, or GGUF `tokenizer.chat_template` | Best local signal. LIVE test: Llama-3.2-1B GGUF template → tools/tool_calls/ipython true; SmolLM2-135M-Instruct → all false. |
| Reasoning | template contains `<think>`, `enable_thinking`, `reasoning_content`, `reasoning_effort` | LIVE (Qwen3.8 / Muse-Spark templates) |
| Router `supports_tools` | `/v1/models` providers[] | Authoritative for remote. |
| `inferenceProviderMapping[].features.toolCalling` | list endpoint | Authoritative for remote. |
| Tags `tool-use`, `function-calling`, `agent` | author-supplied | Sparse; boost only. |
| Name tokens `Tool-Use`, `FC`, `Agent`, `functiongemma` | name | Heuristic. |

Heuristic regex set (case-sensitive on template): `\btools\b`, `tool_calls`, `'tool'|"tool"|ipython`, `<tool_call>`,
`<\|tool_call\|>`, `\[TOOL_CALLS\]`. Remember GGUF templates can differ from upstream (quantizers patch them).

---

## 11. Safety: pickle vs safetensors, Hub scanners

- Unsafe (pickle-based, arbitrary code on load): `*.bin` (PyTorch `pytorch_model*.bin`), `*.pt`, `*.pth`, `*.pkl`,
  `*.pickle`, `*.ckpt`, `*.joblib`, `*.dat` (when pickle), legacy GGML `.bin` is not pickle but is unsupported;
  `.npz/.npy` can contain pickles if `allow_pickle`. DOCS: "The instructions that pose a threat are STACK_GLOBAL, GLOBAL
  and REDUCE"; the Hub runs ClamAV + Pickle Import scans and third-party scanners.
- Safe-by-format (no code execution): `.gguf`, `.safetensors`, `.onnx` (+`.onnx_data`), `.tflite`, `.litertlm`, `.task`
  (zip bundle), `.mlpackage/.mlmodelc`, `.pte`. Sherpa runtimes (llama.cpp, MLX, LiteRT) never need pickle → hard
  allowlist; never download `.bin/.pt/.pth/.ckpt/.pkl` at all.
- `GET /api/models/{repo}/scan` (LIVE): `{"scansDone":true,"filesWithIssues":[{"path":"pytorch_model.bin","level":"unsafe"}]}`
  (`ykilcher/totally-harmless-model`); levels seen `unsafe`, `caution` (`mcpotato/42-eicar-street`: `.pkl`, `.dat`,
  EICAR file unsafe, `build_pickles.py` caution).
- Per file (`tree?expand=true` / `paths-info expand=true`, LIVE):

```json
"securityFileStatus":{"status":"unsafe",
 "protectAiScan":{"status":"unsafe","message":"This file is vulnerable to threat(s) PAIT-PYTCH-100.","reportLink":"https://insights-db.paloaltonetworks.com/..."},
 "avScan":{"status":"unsafe","message":"Detected malware signatures: Py.Malware.CodeExec___builtin___eval_GLOBAL"},
 "pickleImportScan":{"status":"unsafe","message":"This file contains imports that may be unsafe.",
   "pickleImports":[{"module":"torch","name":"FloatStorage","safety":"innocuous"},{"module":"__builtin__","name":"eval","safety":"dangerous"}],"version":"0.0.32"},
 "virusTotalScan":{"status":"suspicious","message":"2/75 engines detect it as malicious."},
 "jFrogScan":{"status":"unsafe","message":"Pickle-based model with embedded malicious code"}}
```

  Statuses seen: `safe`, `unsafe`, `suspicious`, `unscanned`; `scansDone:false` exists for older repos. For GGUF
  files the scanners still run (`jFrogScan: safe`). Use as a **secondary** gate (block on any `unsafe`), not a
  substitute for the extension allowlist. GGUF files can still crash parsers → parse headers defensively
  (bounds-check counts and string lengths; we saw `n_kv=35`, arrays of 280k).

---

## 12. GGUF quantization reference (vendored llama.cpp)

Nominal bpw = block bytes × 8 / block size from `gguf-py/gguf/constants.py GGML_QUANT_SIZES` (SRC).
"File bpw" = llama-bench on Llama-3.1-8B from `tools/quantize/README.md` (mix incl. embeddings; SRC).
Live effective bpw = file bytes × 8 / params for `unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF` (30.53B params, LIVE).

| ftype name (quantize) | ftype id | main tensor type(s) | nominal bpw | README 8B bpw | quantize.cpp note | Qwen3-30B-A3B live |
|---|---|---|---|---|---|---|
| F32 | 0 | F32 | 32 | – | 26.00G @7B | – |
| F16 | 1 | F16 | 16 | 16.00 | 14.00G +0.0020 ppl | – |
| BF16 | 32 | BF16 | 16 | – | 14.00G −0.0050 ppl | – |
| Q8_0 | 7 | Q8_0 (32w, 34B) | 8.5 | 8.50 | 7.96G +0.0026 | 8.51 |
| Q6_K | 18 | Q6_K | 6.5625 | 6.56 | 6.14G +0.0217 | 6.57 |
| Q5_K_M / Q5_K | 17 | Q5_K (+Q6_K) | 5.5 | 5.70 | 5.33G +0.0569 | 5.69 |
| Q5_K_S | 16 | Q5_K | 5.5 | 5.57 | 5.21G +0.1049 | 5.52 |
| Q5_1 | 9 | Q5_1 | 6.0 | – | 5.65G +0.1062 | – |
| Q5_0 | 8 | Q5_0 | 5.5 | – | 5.21G +0.1316 | – |
| Q4_K_M / Q4_K | 15 | Q4_K (+Q6_K) | 4.5 | 4.89 | 4.58G +0.1754 | 4.86 |
| Q4_K_S | 14 | Q4_K | 4.5 | 4.67 | 4.37G +0.2689 | 4.57 |
| Q4_1 | 3 | Q4_1 | 5.0 | – | 4.78G +0.4511 | 5.03 |
| Q4_0 | 2 | Q4_0 | 4.5 | – | 4.34G +0.4685 | 4.55 |
| IQ4_NL | 25 | IQ4_NL | 4.5 | 4.68 | 4.50 bpw non-linear | 4.54 |
| IQ4_XS | 30 | IQ4_XS | 4.25 | 4.46 | 4.25 bpw non-linear | 4.29 |
| MXFP4_MOE | 38 | MXFP4 (experts) | 4.25 | – | "MXFP4 MoE" | – |
| NVFP4 | 39 | NVFP4 (64w, 36B) | 4.5 | – | (no quantize option; produced by converters) | – |
| Q3_K_L | 13 | Q3_K (+Q5_K) | 3.4375 | 4.30 | 4.03G +0.5562 | – |
| Q3_K_M / Q3_K | 12 | Q3_K (+Q4_K) | 3.4375 | 4.00 | 3.74G +0.6569 | 3.85 |
| Q3_K_S | 11 | Q3_K | 3.4375 | 3.64 | 3.41G +1.6321 | 3.48 |
| IQ3_M | 27 | IQ3_S mix | 3.4375 | 3.76 | 3.66 bpw mix | – |
| IQ3_S | 26 | IQ3_S | 3.4375 | 3.66 | 3.44 bpw | – |
| IQ3_XS | 22 | IQ3_XXS/IQ3_S mix | – | 3.50 | 3.3 bpw | – |
| IQ3_XXS | 23 | IQ3_XXS | 3.0625 | 3.25 | 3.06 bpw | – |
| Q2_K | 10 | Q2_K (+Q3_K/Q4_K) | 2.625 | 3.16 | 2.96G +3.5199 | 2.95 |
| Q2_K_S | 21 | Q2_K | 2.625 | 2.97 | 2.96G +3.1836 | – |
| IQ2_M | 29 | IQ2_S mix | 2.5625 | 2.93 | 2.7 bpw | – |
| IQ2_S | 28 | IQ2_S | 2.5625 | 2.74 | 2.5 bpw | – |
| IQ2_XS | 20 | IQ2_XS | 2.3125 | 2.59 | 2.31 bpw | – |
| IQ2_XXS | 19 | IQ2_XXS | 2.0625 | 2.38 | 2.06 bpw | – |
| Q2_0 (new) | 41 | Q2_0 (64w, 18B) | 2.25 | – | 2.25 bpw (group 64) | – |
| TQ2_0 | 37 | TQ2_0 | 2.0625 | – | 2.06 bpw ternarization | – |
| IQ1_M | 31 | IQ1_M | 1.75 | 2.15 | 1.75 bpw | – |
| TQ1_0 | 36 | TQ1_0 | 1.6875 | – | 1.69 bpw ternarization | (UD-TQ1_0: 2.10) |
| IQ1_S | 24 | IQ1_S | 1.5625 | 2.00 | 1.56 bpw | – |
| Q1_0 (new) | 40 | Q1_0 (128w, 18B) | 1.125 | – | 1.125 bpw | – |
| ~~Q4_0_4_4 / Q4_0_4_8 / Q4_0_8_8~~ | ~~33/34/35~~ | removed (ggml types 31–33) | – | – | "removed from gguf files, use Q4_0 and runtime repack" | — files **won't load** |
| ~~IQ4_NL_4_4/4_8/8_8~~ | – | removed (ggml 36–38) | – | – | "REMOVED, use IQ4_NL with runtime repacking" | — |
| (Q4_2, Q4_3, Q4_1_SOME_F16) | 4/5/6 | removed long ago | | | | |
| GUESSED | 1024 | n/a | | | "not specified in the model file" | |

Aliases accepted by `llama-quantize` (case-insensitive): `Q3_K`→Q3_K_M, `Q4_K`→Q4_K_M, `Q5_K`→Q5_K_M (SRC); unsloth
ships files literally named `-Q3_K.gguf`, `-Q4_K.gguf` (LIVE). `general.file_type` in the header is authoritative.

Effective-bpw reality check (LIVE file sizes): the same label is 4.86 bpw on a 30B MoE, 5.23 bpw on Llama-3.2-1B,
and 7.55 bpw on gemma-3-270m (Q4_K_M); `unsloth/gemma-3-270m-it` `Q2_K.gguf` and `Q2_K_L.gguf` are byte-identical in
size (237,079,584). `UD-Q8_K_XL` = 9.43 bpw (30B) / 14.06 bpw (270M).

Community labels on top of llama.cpp ftypes (not real ftypes; read `general.file_type` + tensor types):

| Label | Producer | Meaning |
|---|---|---|
| `_L` / `_XL` (e.g. `Q4_K_L`, `Q3_K_XL`, `Q2_K_L`) | bartowski | "Uses Q8_0 for embed and output weights" (README, LIVE) |
| `UD-<Q>` (`UD-Q4_K_XL`, `UD-IQ1_S`, `UD-TQ1_0`, `UD-IQ4_NL_XL`, `UD-Q8_K_XL`, `UD-Q6_K_L`, `UD-Q6_K_M`) | unsloth | Unsloth Dynamic: "dynamically adjust the quantization type of every possible layer" (unsloth docs); `UD-3` naming exists for v3.0 (docs mention, not seen in files) |
| `i1-` / `.i1-Q4_K_M` / repo suffix `-i1-GGUF` | mradermacher | weighted/imatrix quants; static quants in `-GGUF` repo without `i1` |
| `-imat` | ggml-org (old) | imatrix quant |
| `_K_P` (`Q4_K_P`) | HauhauCS | custom mix (UNVERIFIED semantics) |
| `qat`, `QAD` | ggml-org / LiquidAI | quantization-aware training / distillation source weights |
| `MXFP4_MOE`, `MXFP4` | unsloth / ggml-org | MXFP4 experts (gpt-oss native) |

---

## 13. Naming conventions (what the parser must understand)

### 13.1 Official GGUF convention (SRC `gguf-py/gguf/utility.py naming_convention`, ref ggml docs/gguf.md)

`<BaseName>-<SizeLabel>-<FineTune>-<Version>-<Encoding>-<Type>-<Shard>.gguf`, e.g.
`Mixtral-8x7B-v0.1-KQ2.gguf`; size label from `size_label()`: `"{expert_count}x{per-expert}"` for MoE else rounded
`K/M/B/T` with ≥2 significant digits (`1.5B`, `270M`, `7.6B`). Split suffix `-%05d-of-%05d.gguf` (SRC llama.cpp
`SPLIT_PATH_FORMAT`). Converters write `general.basename`, `general.size_label`, `general.finetune`, `general.version`,
`general.name` into the header — **when present, prefer header over file name**.

### 13.2 llama.cpp's own HF file picker (SRC common/download.cpp) — mirror it

- Split detection: `^(.+)-([0-9]{5})-of-([0-9]{5})$` (case-insensitive) on the name minus `.gguf`.
- Quant tag: `[-.]([A-Z0-9_]+)$` after removing split suffix (uppercased) → bits = first integer in tag
  ("Q4_0 → 4, F16 → 16, NVFP4 → 4, Q8_K_M → 8").
- Model vs sidecar: a `.gguf` is a model unless its basename contains `mmproj`, `imatrix`, `mtp-`, `eagle3-`, `dflash-`, `dspark-`.
- Default pick when no tag: first `Q4_K_M`, then `Q8_0`, then first model file; shard ≠1 skipped.
- Sidecar match: same directory depth preferred, then exact `-TAG.` match, then closest bit-width.

### 13.3 Publisher patterns (LIVE)

| Publisher | Repo pattern | File pattern | Separators |
|---|---|---|---|
| unsloth | `{Name}-GGUF`, `{Name}-unsloth-bnb-4bit`, `{Name}-bnb-4bit`, `{Name}-NVFP4` | `{Name}-{QUANT}.gguf`, `{Name}-UD-{QUANT}.gguf`, `BF16/{Name}-BF16-00001-of-00002.gguf`, `UD-IQ1_S/{Name}-UD-IQ1_S-00001-of-00005.gguf`, `MTP/mtp-{Name}-Q4_0.gguf`, `mmproj-F16.gguf` (no model name!), `imatrix_unsloth.gguf` / `.gguf_file` | `-` |
| bartowski | `{publisher}_{Name}-GGUF` (publisher prefix with `_`), `{Name}-exl2` | `{publisher}_{Name}-{QUANT}.gguf`, `mmproj-{publisher}_{Name}-f16.gguf`, `{Name}.imatrix`, `layouts/{...}.layout.json` | `-`, `_` after publisher |
| mradermacher | `{Name}-GGUF`, `{Name}-i1-GGUF` | `{Name}.{QUANT}.gguf`, `{Name}.i1-{QUANT}.gguf`, `{Name}.mmproj-f16.gguf`, `{Name}.Q8_0.gguf.part1of2` | `.` before quant |
| TheBloke | `{Name}-GGUF/-GPTQ/-AWQ/-GGML` | `{name-lowercase}.{QUANT}.gguf`, `{name}.ggmlv3.q4_0.bin` (legacy), GPTQ branches `gptq-4bit-32g-actorder_True` | `.` |
| lmstudio-community | `{Name}-GGUF`, `{Name}-MLX-{n}bit` | `{Name}-{QUANT}.gguf`, `mmproj-{Name}-BF16.gguf` | `-` |
| ggml-org | `{Name}-GGUF`, `{Name}-{QUANT}-GGUF` | `{Name}-{QUANT}.gguf`, `mmproj-{Name}-Q8_0.gguf`, `mtp-/dflash-/eagle3-{Name}-{Q}.gguf` | `-` |
| Qwen (official GGUF) | `Qwen2.5-Coder-7B-Instruct-GGUF` | all-lowercase `qwen2.5-coder-7b-instruct-q4_k_m-00001-of-00002.gguf`, `-fp16.gguf` | `-` |
| mistralai | `{Name}-GGUF` | `{Name}-BF16-mmproj.gguf` (mmproj **suffix**) | `-` |
| mlx-community | `{Name}-{n}bit`, `-{n}bit-gs32`, `-mxfp4`, `-MXFP4-Q8`, `-{n}bit-DWQ`, `-lm-{n}bit`, `-OptiQ-4bit`, `-bf16` | `model.safetensors`, `model-00001-of-00003.safetensors`, `weights.npz` (legacy) | `-` |
| litert-community / google | `{name}-litert-lm`, `{Name}` | `{Name}_multi-prefill-seq_q8_ekv4096.litertlm`, `_q4_block128_ekv4096.task`, `-gpu.litertlm`, `-web.task`, `_Google_Tensor_G5.litertlm`, `.mediatek.mt6993.litertlm`, `.qualcomm.sm8650.litertlm`, `_dynamic_wi4b32_afp32.litertlm`, `_mixed_int4.litertlm`, `-int4.litertlm` | `_`, `-`, `.` |
| transformers.js ONNX | `{Name}` or `{Name}-ONNX` | `onnx/model.onnx`, `model_fp16`, `model_int8`, `model_q4`, `model_q4f16`, `model_bnb4`, `model_q8` (+ `.onnx_data`) | `_` |
| GPTQ/AWQ | `-GPTQ-Int4`, `-GPTQ-Int8`, `-AWQ`, `-awq`, `quantized.w4a16`, `-W4A16`, `-qat-w4a16-ct`, `-FP8`, `-bnb-4bit` | `model-0000x-of-0000y.safetensors` | |
| EXL2/EXL3 | `{Name}-exl2` (branches `4_25`), `-5.0bpw-h6-exl2`, `-EXL2-4.5bit`, `-exl3` (branches `SC_4.00bpw_H5_V6`, `6.00bpw`), `-EXL3-4.05bpw` | `output-0000x-of-0000y.safetensors`, `model-embed.safetensors` | |

Quant metadata for non-GGUF formats lives in `config.json` (LIVE): MLX `"quantization":{"group_size":64,"bits":4}`
(`gs32` → 32; mxfp4 → `{"group_size":32,"bits":4,"mode":"mxfp4"}`); GPTQ `quantization_config:{bits:4, group_size:128,
desc_act:false, sym:true, quant_method:"gptq"}`; AWQ `{bits:4, group_size:128, quant_method:"awq", version:"gemm",
zero_point:true}`; compressed-tensors `{quant_method:"compressed-tensors", format:"pack-quantized", config_groups...}`.
Derived effective bpw (UNVERIFIED formulas): MLX affine = bits + 32/group_size (fp16 scale+bias) → 4bit-gs64 4.5,
4bit-gs32 5.0, 8bit-gs64 8.5; mxfp4 (e8m0 scale per 32) 4.25; GPTQ/AWQ 4-bit g128 ≈ 4.16. EXL2/3: `bpw` in name is
the average; `h6`/`H5` = head (lm_head) bits; `V6` meaning UNVERIFIED.

### 13.4 Token dictionary for the name parser

| Class | Tokens (seen live) | Notes |
|---|---|---|
| Size | `270M`, `0.6B`, `1.5B`, `1.7b`, `8B`, `12b`, `27B`, `405B`, `816B`; `135M`, `230M`, `5M` | case-insensitive `B/M/T/K`; lowercase common (`gemma-4-12b-it`, `gpt-oss-20b`) |
| MoE total×active | `30B-A3B`, `35B-A3B`, `8B-A1B`, `24B-A2B`, `12B-A2.5B`, `26B-A4B`, `120B-A12B`, `235B-A22B`, `816B-A42B` | `A` + size = active params |
| MoE experts | `8x7B`, `8x22B` | total ≈ not 8×7 (shared attention); read header |
| Effective params | `E2B`, `E4B` (Gemma 3n/4) | raw params ≫ label: `google/gemma-3n-E2B-it` safetensors total 5,439,438,272; E4B 7,849,978,192 (LIVE) |
| Size words | `mini`, `Small`, `Mini`, `nano`, `Flash`, `Lightning`, `Super`, `Bolt`, `Lite`, `Dev` | tier, not a number |
| Variant | `Instruct`, `it`, `IT`, `Chat`, `chat`, `Base`, `Thinking`, `Reasoning`, `Coder`, `Code`, `Distill`, `Distilled`, `VL`, `Vision`, `Audio`, `Embedding`, `Reranker`, `Tool-Use`, `RL`, `abliterated`, `uncensored`, `OBLITERATED`, `heretic`, `Uncensored` | multiple allowed; `it` must not match inside words |
| Version | `v0.3`, `v1.1`, `v3.2`, `V2.6`, `V2.5`, `-2` (`Devstral-Small-2`), family-glued `Qwen3.8`, `LFM2.5`, `Mellum2.1`, `Gemma3`, `SmolLM3`, `granite-4.2`, `Llama-3.3`, `L3` | split glued versions via `^(?<fam>[A-Za-z]+(?:-[A-Za-z]+)*?)(?<ver>\d+(?:\.\d+)*)$` |
| Date/build | `2507`, `2506`, `2512`, `2503`, `2407`, `2602`, `1017` | 4 digits YYMM (or MMDD in `DeepSeek-V4.1-Flash-1017` — ambiguous) |
| Context | `1M`, `4k`, `32K` (`FastMTP-32K`), `128k` | collides with size `M`! `1M` after variant = context |
| Quant (GGUF) | §12 list + `UD-`, `i1-`, `_L`, `_XL`, `_K_P`, `MXFP4_MOE`, `NVFP4`, `f16`, `fp16`, `bf16`, `q4` | case-insensitive |
| Quant (other) | `4bit`, `8bit`, `3bit`, `5bit`, `6bit`, `MLX-4bit`, `gs32`, `DWQ`, `mxfp4`, `mxfp4-q8`, `MXFP4-Q8`, `OptiQ`, `oQ4e`, `GPTQ-Int4`, `Int8`, `AWQ`, `w4a16`, `W4A16`, `FP8`, `NVFP4`, `bnb-4bit`, `qat`, `ct`, `exl2`, `exl3`, `5.0bpw`, `4.5bit`, `h6`, `q8`, `q4`, `int4`, `int8`, `mixed_int4`, `wi4b32_afp32`, `q4_block128`, `q4f16`, `bnb4` | |
| Shard | `-00001-of-00003`, `-00001-of-000002`, `model.safetensors-00001-of-00002`, `.gguf.part1of2`, `output-00001-of-00003`, `model-00001.safetensors` (no total) | |
| Role | `mmproj` (prefix, suffix or `.mmproj-`), `mtp-`, `FastMTP`, `dflash-`, `eagle3-`, `dspark-`, `lilicorr-` (UNVERIFIED), `imatrix`, `.imatrix`, `_mtp.safetensors`, `optiq_vision.safetensors`, `cal_trace.safetensors` | |
| Publisher prefix | `google_`, `Qwen_`, `TheDrummer_`, `Kwaipilot_`, `thomsonreuters_`, `huihui-ai_` (bartowski); `NVIDIA-`, `Meta-`, `Huihui-` | |
| Device target (LiteRT) | `gpu`, `web`, `Google_Tensor_G5/G6`, `mediatek.mt6991/mt6993`, `qualcomm.sm8550/sm8650`, `Intel_PTL`, `ekv1280/4096` (KV-cache length, inferred) | |
| Legacy/unsupported | `.ggmlv3.`, `.bin` GGML, `Q4_0_4_4`, `big-endian`, `.pt`, `.pth` | flag |

Parser precedence: (1) GGUF header fields (if peeked) > (2) Hub metadata (`safetensors.total`, `config.quantization_config`,
`cardData.base_model`, tags) > (3) file name > (4) repo name. Always parse **repo id and file name separately and
merge** (e.g. `ggml-org/SmolLM3-3B-GGUF` / `SmolLM3-Q4_K_M.gguf`: size only in repo; `unsloth/Qwen3.8-27B-GGUF` /
`mmproj-F16.gguf`: model name only in repo).

---

## 14. Test corpus (verbatim, LIVE 2026-10-18)

Columns: fmt = gguf/mlx/st (safetensors)/gptq/awq/exl2/exl3/litert/onnx/pickle/ggml; bpw = nominal or
"(live)" effective where measured; "dyn" = dynamic mix (use file size). Empty = not present in name.
"repo" in the file column means the row tests the repo id (weights are generic `model*.safetensors`).

| # | repo id | file / branch | fmt | family | ver | size | active | variant | quant | bpw | shard / role / note |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | unsloth/Qwen3.8-27B-GGUF | Qwen3.8-27B-UD-Q4_K_XL.gguf | gguf | Qwen | 3.8 | 27B | | | UD-Q4_K_XL | dyn | model |
| 2 | unsloth/Qwen3.8-27B-GGUF | BF16/Qwen3.8-27B-BF16-00001-of-00002.gguf | gguf | Qwen | 3.8 | 27B | | | BF16 | 16 | shard 1/2, folder |
| 3 | unsloth/Qwen3.8-27B-GGUF | MTP/mtp-Qwen3.8-27B-Q4_0.gguf | gguf | Qwen | 3.8 | 27B | | | Q4_0 | 4.5 | role=draft(mtp) |
| 4 | unsloth/Qwen3.8-27B-GGUF | mmproj-F16.gguf | gguf | (from repo) | | | | | F16 | 16 | role=mmproj, name only in repo |
| 5 | unsloth/Qwen3.8-27B-GGUF | imatrix_unsloth.gguf | gguf | | | | | | | | role=imatrix (not loadable) |
| 6 | unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF | Qwen3-Coder-30B-A3B-Instruct-UD-Q4_K_XL.gguf | gguf | Qwen | 3 | 30B | 3B | Coder, Instruct | UD-Q4_K_XL | 4.63 (live) | 17,665,334,432 B |
| 7 | unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF | Qwen3-Coder-30B-A3B-Instruct-UD-TQ1_0.gguf | gguf | Qwen | 3 | 30B | 3B | Coder, Instruct | UD-TQ1_0 | 2.10 (live) | |
| 8 | unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF | Qwen3-Coder-30B-A3B-Instruct-Q2_K_L.gguf | gguf | Qwen | 3 | 30B | 3B | Coder, Instruct | Q2_K_L | 2.97 (live) | |
| 9 | unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF | BF16/Qwen3-Coder-30B-A3B-Instruct-BF16-00002-of-00002.gguf | gguf | Qwen | 3 | 30B | 3B | Coder, Instruct | BF16 | 16 | shard 2/2 |
| 10 | unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF | imatrix_unsloth.gguf_file | other | | | | | | | | role=imatrix, odd extension |
| 11 | unsloth/Qwen3-Coder-30B-A3B-Instruct-1M-GGUF | Qwen3-Coder-30B-A3B-Instruct-1M-Q2_K.gguf | gguf | Qwen | 3 | 30B | 3B | Coder, Instruct | Q2_K | 2.95 | `1M` = context, not size |
| 12 | unsloth/Qwen3.6-35B-A3B-GGUF | Qwen3.6-35B-A3B-MXFP4_MOE.gguf | gguf | Qwen | 3.6 | 35B | 3B | | MXFP4_MOE | ~4.25 experts | |
| 13 | unsloth/Qwen3.6-35B-A3B-GGUF | Qwen3.6-35B-A3B-UD-IQ4_NL_XL.gguf | gguf | Qwen | 3.6 | 35B | 3B | | UD-IQ4_NL_XL | dyn | |
| 14 | unsloth/Qwen3.6-35B-A3B-GGUF | Qwen3.6-35B-A3B-UD-Q8_K_XL.gguf | gguf | Qwen | 3.6 | 35B | 3B | | UD-Q8_K_XL | dyn (9.4 on 30B) | no real Q8_K ftype |
| 15 | unsloth/Muse-Spark-Open-816B-A42B-GGUF | UD-IQ1_S/Muse-Spark-Open-816B-A42B-UD-IQ1_S-00001-of-00005.gguf | gguf | Muse Spark Open | | 816B | 42B | | UD-IQ1_S | dyn | shard 1/5 in quant folder |
| 16 | unsloth/gemma-3-270m-it-GGUF | gemma-3-270m-it-Q8_0.gguf | gguf | Gemma | 3 | 270M | | it | Q8_0 | 8.70 (live) | |
| 17 | unsloth/gemma-3-270m-it-GGUF | gemma-3-270m-it-Q2_K.gguf | gguf | Gemma | 3 | 270M | | it | Q2_K | **7.07 (live)** | name-bpw trap |
| 18 | unsloth/gemma-4-12b-it-GGUF | gemma-4-12b-it-UD-Q4_K_XL.gguf | gguf | Gemma | 4 | 12B | | it | UD-Q4_K_XL | dyn | lowercase `b` |
| 19 | unsloth/gemma-4-12b-it-GGUF | mtp-gemma-4-12b-it.gguf | gguf | Gemma | 4 | 12B | | it | (none) | ? | role=draft(mtp); read header |
| 20 | unsloth/embeddinggemma-2-GGUF | embeddinggemma-2-UD-Q4_K_XL.gguf | gguf | EmbeddingGemma | 2 | | | Embedding | UD-Q4_K_XL | dyn | no size token |
| 21 | unsloth/Qwen3-30B-A3B-Thinking-2507-GGUF | Qwen3-30B-A3B-Thinking-2507-Q4_K_M.gguf | gguf | Qwen | 3 (build 2507) | 30B | 3B | Thinking | Q4_K_M | ~4.86 | |
| 22 | unsloth/NVIDIA-Nemotron-3.5-Super-VL-120B-A12B-GGUF | NVFP4/NVIDIA-Nemotron-3.5-Super-VL-120B-A12B-NVFP4-00001-of-00003.gguf | gguf | Nemotron (NVIDIA) | 3.5 | 120B | 12B | Super, VL | NVFP4 | 4.5 | shard 1/3 |
| 23 | unsloth/NVIDIA-Nemotron-3.5-Super-VL-120B-A12B-GGUF | LiLiCorr/lilicorr-NVIDIA-Nemotron-3.5-Super-VL-120B-A12B-NVFP4.gguf | gguf | Nemotron | 3.5 | 120B | 12B | Super, VL | NVFP4 | 4.5 | unknown sidecar prefix → not primary |
| 24 | unsloth/MiniMax-H3-GGUF | minimax_h3_fl2va_pruned-Q4_K.gguf | gguf | MiniMax | H3 | | | pruned | Q4_K (=Q4_K_M) | ~4.9 | `_` separators; video-gen (not LLM) |
| 25 | bartowski/Llama-3.2-3B-Instruct-GGUF | Llama-3.2-3B-Instruct-Q4_0_4_4.gguf | gguf | Llama | 3.2 | 3B | | Instruct | Q4_0_4_4 | 4.5 | **deprecated: won't load** |
| 26 | bartowski/Llama-3.2-3B-Instruct-GGUF | Llama-3.2-3B-Instruct-Q3_K_XL.gguf | gguf | Llama | 3.2 | 3B | | Instruct | Q3_K_XL | Q3_K_L + Q8_0 embed/out | |
| 27 | bartowski/Llama-3.2-3B-Instruct-GGUF | Llama-3.2-3B-Instruct-Q6_K_L.gguf | gguf | Llama | 3.2 | 3B | | Instruct | Q6_K_L | ≥6.56 | |
| 28 | bartowski/Llama-3.2-3B-Instruct-GGUF | Llama-3.2-3B-Instruct-f16.gguf | gguf | Llama | 3.2 | 3B | | Instruct | F16 | 16 | lowercase |
| 29 | bartowski/Llama-3.2-1B-Instruct-GGUF | Llama-3.2-1B-Instruct-Q4_K_M.gguf | gguf | Llama | 3.2 | 1B | | Instruct | Q4_K_M | 5.23 (live) | header: size_label=1B, file_type=15 |
| 30 | bartowski/Qwen2.5-7B-Instruct-GGUF | Qwen2.5-7B-Instruct-Q4_K_L.gguf | gguf | Qwen | 2.5 | 7B | | Instruct | Q4_K_L | ≥4.89 | |
| 31 | bartowski/Qwen2.5-7B-Instruct-GGUF | Qwen2.5-7B-Instruct.imatrix | other | Qwen | 2.5 | 7B | | Instruct | | | role=imatrix |
| 32 | bartowski/google_gemma-4-E2B-it-GGUF | google_gemma-4-E2B-it-Q4_K_M.gguf | gguf | Gemma (google) | 4 | E2B | | it | Q4_K_M | ~4.9 | effective-param label |
| 33 | bartowski/google_gemma-3n-E4B-it-GGUF | google_gemma-3n-E4B-it-Q4_K_M.gguf | gguf | Gemma 3n (google) | 3n | E4B (7.85B raw) | | it | Q4_K_M | ~4.9 | |
| 34 | bartowski/Qwen_Qwen3.6-35B-A3B-GGUF | Qwen_Qwen3.6-35B-A3B-IQ1_M.gguf | gguf | Qwen (Qwen_) | 3.6 | 35B | 3B | | IQ1_M | 1.75 | publisher prefix |
| 35 | bartowski/thomsonreuters_Thomson-1.0-Small-GGUF | mmproj-thomsonreuters_Thomson-1.0-Small-f16.gguf | gguf | Thomson (thomsonreuters_) | 1.0 | Small | | | F16 | 16 | role=mmproj; size word |
| 36 | bartowski/Mellum2.1-12B-A2.5B-Thinking-GGUF | Mellum2.1-12B-A2.5B-Thinking-Q4_K_M.gguf | gguf | Mellum | 2.1 | 12B | 2.5B | Thinking | Q4_K_M | ~4.9 | glued version, decimal active |
| 37 | bartowski/Mellum2.1-12B-A2.5B-Thinking-GGUF | layouts/Mellum2.1-12B-A2.5B-Thinking-Q4_K_M.layout.json | other | | | | | | | | non-weight sidecar → ignore |
| 38 | bartowski/TheDrummer_Orion-26B-A4B-v1.1-GGUF | TheDrummer_Orion-26B-A4B-v1.1-Q4_K_M.gguf | gguf | Orion (TheDrummer_) | v1.1 | 26B | 4B | | Q4_K_M | ~4.9 | |
| 39 | bartowski/L3-8B-Stheno-v3.2-GGUF | L3-8B-Stheno-v3.2-Q4_K_M.gguf | gguf | Stheno (base L3=Llama 3) | v3.2 | 8B | | | Q4_K_M | ~4.9 | size before name |
| 40 | bartowski/MiMo-V2.6-Distill-Qwen-9B-GGUF | MiMo-V2.6-Distill-Qwen-9B-Q4_K_M.gguf | gguf | MiMo→Qwen | V2.6 | 9B | | Distill | Q4_K_M | ~4.9 | teacher-student name |
| 41 | bartowski/Kwaipilot_KAT-Coder-V2.5-Dev-GGUF | Kwaipilot_KAT-Coder-V2.5-Dev-IQ2_M.gguf | gguf | KAT (Kwaipilot_) | V2.5 | | | Coder, Dev | IQ2_M | 2.7 | no size |
| 42 | mradermacher/Cyber-Ornith-1.5-9B-OBLITERATED-i1-GGUF | Cyber-Ornith-1.5-9B-OBLITERATED.i1-Q4_K_M.gguf | gguf | Ornith (Cyber-) | 1.5 | 9B | | OBLITERATED | i1-Q4_K_M | ~4.9 | `.` separator, imatrix |
| 43 | mradermacher/Cyber-Ornith-1.5-9B-OBLITERATED-i1-GGUF | Cyber-Ornith-1.5-9B-OBLITERATED.i1-IQ1_S.gguf | gguf | Ornith | 1.5 | 9B | | OBLITERATED | i1-IQ1_S | 1.56 | |
| 44 | mradermacher/Ornith-1.5-9B-uncensored-GGUF | Ornith-1.5-9B-uncensored.mmproj-f16.gguf | gguf | Ornith | 1.5 | 9B | | uncensored | F16 | 16 | role=mmproj (dot form) |
| 45 | mradermacher/Ornith-1.5-9B-uncensored-GGUF | Ornith-1.5-9B-uncensored.Q8_0.gguf | gguf | Ornith | 1.5 | 9B | | uncensored | Q8_0 | 8.5 | |
| 46 | mradermacher/Llama-3.3-70B-Instruct-abliterated-GGUF | Llama-3.3-70B-Instruct-abliterated.Q8_0.gguf.part1of2 | gguf-part | Llama | 3.3 | 70B | | Instruct, abliterated | Q8_0 | 8.5 | **byte split 1/2 → concatenate** |
| 47 | mradermacher/Meta-Llama-3-70B-Instruct-i1-GGUF | Meta-Llama-3-70B-Instruct.i1-Q6_K.gguf.part1of2 | gguf-part | Llama (Meta-) | 3 | 70B | | Instruct | i1-Q6_K | 6.56 | byte split 1/2 |
| 48 | mradermacher/Qwen3.5-9B-Kimi-k3-Distilled-GGUF | Qwen3.5-9B-Kimi-k3-Distilled.Q4_K_M.gguf | gguf | Qwen | 3.5 | 9B | | Distilled (from Kimi k3) | Q4_K_M | ~4.9 | teacher after size |
| 49 | mradermacher/LFM2.5-24B-A2B-i1-GGUF | LFM2.5-24B-A2B.i1-Q4_K_M.gguf | gguf | LFM | 2.5 | 24B | 2B | | i1-Q4_K_M | ~4.9 | |
| 50 | lmstudio-community/Qwen3.8-27B-GGUF | mmproj-Qwen3.8-27B-BF16.gguf | gguf | Qwen | 3.8 | 27B | | | BF16 | 16 | role=mmproj |
| 51 | lmstudio-community/Llama-3-Groq-8B-Tool-Use-GGUF | Llama-3-Groq-8B-Tool-Use-Q4_K_M.gguf | gguf | Llama (Groq) | 3 | 8B | | Tool-Use | Q4_K_M | ~4.9 | tags: tool-use, function-calling |
| 52 | lmstudio-community/Mistral-7B-Instruct-v0.3-GGUF | Mistral-7B-Instruct-v0.3-IQ4_NL.gguf | gguf | Mistral | v0.3 | 7B | | Instruct | IQ4_NL | 4.5 | version after variant |
| 53 | ggml-org/gpt-oss-20b-GGUF | gpt-oss-20b-MXFP4.gguf | gguf | gpt-oss | | 20B | (not in name) | | MXFP4 | 4.25 | MoE without A-token |
| 54 | ggml-org/gpt-oss-20b-GGUF | eagle3-gpt-oss-20b-Q8_0.gguf | gguf | gpt-oss | | 20B | | | Q8_0 | 8.5 | role=draft(eagle3) |
| 55 | ggml-org/Qwen3.8-27B-GGUF | dflash-Qwen3.8-27B-Q4_0.gguf | gguf | Qwen | 3.8 | 27B | | | Q4_0 | 4.5 | role=draft(dflash) |
| 56 | ggml-org/gemma-4-E4B-it-GGUF | mmproj-gemma-4-E4B-it-Q8_0.gguf | gguf | Gemma | 4 | E4B | | it | Q8_0 | 8.5 | role=mmproj |
| 57 | ggml-org/gemma-4-E4B-it-GGUF | mtp-gemma-4-E4B-it-BF16.gguf | gguf | Gemma | 4 | E4B | | it | BF16 | 16 | role=draft(mtp) |
| 58 | ggml-org/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-GGUF | NVIDIA-Nemotron-3.5-Lightning-30B-A3B-Q4_0.gguf | gguf | Nemotron (NVIDIA) | 3.5 | 30B | 3B | Lightning | Q4_0 | 4.5 | |
| 59 | ggml-org/Muse-Spark-Open-816B-A42B-GGUF | Muse-Spark-Open-816B-A42B-BF16-00001-of-00022.gguf | gguf | Muse Spark Open | | 816B | 42B | | BF16 | 16 | shard 1/22 |
| 60 | ggml-org/gemma-3-270m-qat-GGUF | gemma-3-270m-qat-Q4_0.gguf | gguf | Gemma | 3 | 270M | | qat | Q4_0 | 4.5 | |
| 61 | ggml-org/Qwen3-Reranker-0.6B-Q8_0-GGUF | qwen3-reranker-0.6b-q8_0.gguf | gguf | Qwen | 3 | 0.6B | | Reranker | Q8_0 | 8.5 | quant also in repo name |
| 62 | ggml-org/models-moved | mistral-7b-v0.2-iq3_s-imat.gguf | gguf | Mistral | v0.2 | 7B | | | IQ3_S (imatrix) | 3.44 | `-imat` suffix after quant |
| 63 | ggml-org/models-moved | bert-bge-small/ggml-model-f16-big-endian.gguf | gguf | BGE (bert) | | small | | | F16 | 16 | **big-endian: reject** |
| 64 | ggml-org/SmolLM3-3B-GGUF | SmolLM3-Q4_K_M.gguf | gguf | SmolLM | 3 | (3B from repo) | | | Q4_K_M | ~4.9 | merge repo+file |
| 65 | Qwen/Qwen2.5-Coder-7B-Instruct-GGUF | qwen2.5-coder-7b-instruct-q4_k_m-00001-of-00002.gguf | gguf | Qwen | 2.5 | 7B | | Coder, Instruct | Q4_K_M | ~4.9 | lowercase, shard 1/2 |
| 66 | Qwen/Qwen2.5-Coder-7B-Instruct-GGUF | qwen2.5-coder-7b-instruct-fp16.gguf | gguf | Qwen | 2.5 | 7B | | Coder, Instruct | F16 (`fp16`) | 16 | also ships fp16 shards of same |
| 67 | mistralai/Ministral-3-3B-Instruct-2512-GGUF | Ministral-3-3B-Instruct-2512-BF16-mmproj.gguf | gguf | Ministral | 3 (build 2512) | 3B | | Instruct | BF16 | 16 | role=mmproj (suffix) |
| 68 | ibm-granite/granite-4.2-8b-GGUF | granite-4.2-8b-Q4_1.gguf | gguf | Granite | 4.2 | 8B | | | Q4_1 | 5.0 | |
| 69 | LiquidAI/LFM2.5-8B-A1B-GGUF | LFM2.5-8B-A1B-Q4_K_M.gguf | gguf | LFM | 2.5 | 8B | 1B | | Q4_K_M | ~4.9 | |
| 70 | LiquidAI/LFM2.5-230M-GGUF | LFM2.5-230M-QAD-Q4_0.gguf | gguf | LFM | 2.5 | 230M | | QAD | Q4_0 | 4.5 | |
| 71 | LiquidAI/LFM2.5-Audio-1.5B-GGUF | mmproj-LFM2.5-Audio-1.5B-Q8_0.gguf | gguf | LFM | 2.5 | 1.5B | | Audio | Q8_0 | 8.5 | role=mmproj (audio) |
| 72 | HuggingFaceTB/SmolLM2-1.7B-Instruct-GGUF | smollm2-1.7b-instruct-q4_k_m.gguf | gguf | SmolLM | 2 | 1.7B | | Instruct | Q4_K_M | ~4.9 | |
| 73 | microsoft/Phi-3-mini-4k-instruct-gguf | Phi-3-mini-4k-instruct-q4.gguf | gguf | Phi | 3 | mini | | instruct | `q4` (ambiguous) | ? | `4k` = context; read header |
| 74 | TheBloke/Mixtral-8x7B-Instruct-v0.1-GGUF | mixtral-8x7b-instruct-v0.1.Q4_K_M.gguf | gguf | Mixtral | v0.1 | 8x7B | | instruct | Q4_K_M | ~4.9 | experts token |
| 75 | TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF | tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf | gguf | TinyLlama | v1.0 | 1.1B | | chat | Q4_K_M | ~4.9 | |
| 76 | TheBloke/Llama-2-7B-Chat-GGML | llama-2-7b-chat.ggmlv3.q4_0.bin | ggml | Llama | 2 | 7B | | chat | q4_0 | 4.5 | **legacy GGML: unsupported** |
| 77 | TheBloke/Vicuna-13B-1.1-GPTQ | vicuna-13B-1.1-GPTQ-4bit-128g.compat.no-act-order.pt | pickle | Vicuna | 1.1 | 13B | | | GPTQ 4bit g128 | ~4.16 | **pickle: block** |
| 78 | TheBloke/Llama-2-7B-Chat-GPTQ | branch `gptq-4bit-32g-actorder_True` | gptq | Llama | 2 | 7B | | Chat | GPTQ 4bit g32 | ~4.6 | variant in branch |
| 79 | mlx-community/Qwen3-8B-4bit | repo | mlx | Qwen | 3 | 8B | | | 4bit gs64 | 4.5 | config `{"group_size":64,"bits":4}` |
| 80 | mlx-community/Qwen2.5-Coder-0.5B-4bit-gs32 | repo | mlx | Qwen | 2.5 | 0.5B | | Coder | 4bit gs32 | 5.0 | |
| 81 | mlx-community/Qwen3.8-27B-mxfp4 | repo | mlx | Qwen | 3.8 | 27B | | | mxfp4 gs32 | 4.25 | config mode=mxfp4 |
| 82 | mlx-community/gpt-oss-20b-MXFP4-Q8 | repo | mlx | gpt-oss | | 20B | | | MXFP4 + Q8 | mixed | |
| 83 | mlx-community/Qwen3-Coder-30B-A3B-Instruct-6bit-DWQ-lr3e-7 | repo | mlx | Qwen | 3 | 30B | 3B | Coder, Instruct | 6bit DWQ | ~6.5 | `lr3e-7` noise token |
| 84 | mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ | repo | mlx | Qwen | 3 | 0.6B | | Embedding | 4bit DWQ | 4.5 | |
| 85 | mlx-community/gemma-3n-E2B-it-lm-4bit | repo | mlx | Gemma 3n | 3n | E2B | | it, lm(text-only) | 4bit | 4.5 | |
| 86 | mlx-community/Llama-3.3-70B-Instruct-3bit | repo | mlx | Llama | 3.3 | 70B | | Instruct | 3bit | 3.5 | |
| 87 | lmstudio-community/Qwen3.8-27B-MLX-6bit | repo | mlx | Qwen | 3.8 | 27B | | | 6bit | 6.5 | `-MLX-` marker |
| 88 | lmstudio-community/Qwen3-4B-Thinking-2507-MLX-4bit | repo | mlx | Qwen | 3 (2507) | 4B | | Thinking | 4bit | 4.5 | |
| 89 | mlx-community/MiMo-V2.6-Flash-RL-mxfp4-q8 | repo | mlx | MiMo | V2.6 | Flash | | RL | mxfp4 + q8 | mixed | |
| 90 | mlx-community/DeepSeek-V4.1-Flash-1017-oQ4e-mtp | repo | mlx | DeepSeek | V4.1 (build 1017) | Flash | | mtp | oQ4e (UNVERIFIED) | ? | unknown scheme |
| 91 | mlx-community/whisper-small-mlx | weights.npz | mlx-npz | Whisper | | small | | | | | legacy npz, ASR |
| 92 | Qwen/Qwen2.5-7B-Instruct-GPTQ-Int4 | repo | gptq | Qwen | 2.5 | 7B | | Instruct | GPTQ Int4 g128 | ~4.16 | st total 7.6B logical |
| 93 | Qwen/Qwen3-8B-AWQ | repo | awq | Qwen | 3 | 8B | | | AWQ 4bit g128 | ~4.16 | |
| 94 | Qwen/Qwen3-235B-A22B-Instruct-2507-FP8 | repo | st | Qwen | 3 (2507) | 235B | 22B | Instruct | FP8 | 8 | F8_E4M3 dtype |
| 95 | google/gemma-4-E2B-it-qat-w4a16-ct | repo | st (compressed-tensors) | Gemma | 4 | E2B | | it, qat | w4a16 | ~4.2 | `ct` = compressed-tensors |
| 96 | nm-testing/SmolLM-1.7B-Instruct-quantized.w4a16 | repo | st | SmolLM | | 1.7B | | Instruct | w4a16 | ~4.2 | `.` before quant |
| 97 | unsloth/Qwen3-4B-Instruct-2507-unsloth-bnb-4bit | repo | st (bnb) | Qwen | 3 (2507) | 4B | | Instruct | bnb-4bit | ~4.5 | GPU-only; skip on mobile |
| 98 | unsloth/Qwen3.8-27B-NVFP4 | model_mtp.safetensors | st | Qwen | 3.8 | 27B | | | NVFP4 | 4.5 | role=draft(mtp) safetensors |
| 99 | casperhansen/deepseek-r1-distill-qwen-32b-awq | repo | awq | DeepSeek R1→Qwen | R1 | 32B | | Distill | AWQ | ~4.16 | all lowercase |
| 100 | bartowski/L3-8B-Stheno-v3.2-exl2 | branch `4_25` | exl2 | Stheno (L3) | v3.2 | 8B | | | EXL2 | 4.25 | bpw in branch, `_` decimal |
| 101 | turboderp/Qwen3.8-27B-exl3 | branch `SC_4.00bpw_H5_V6` | exl3 | Qwen | 3.8 | 27B | | | EXL3 | 4.00 | H5 head bits; main has only `cal_trace.safetensors` |
| 102 | LoneStriker/Nous-Capybara-34B-5.0bpw-h6-exl2 | output-00001-of-00003.safetensors | exl2 | Capybara (Nous) | | 34B | | | EXL2 | 5.0 (h6) | |
| 103 | speakleash/Bielik-11B-v2.2-Instruct-EXL2-4.5bit | repo | exl2 | Bielik | v2.2 | 11B | | Instruct | EXL2 | 4.5 | `bit` not `bpw` |
| 104 | litert-community/gemma-4-E2B-it-litert-lm | gemma-4-E2B-it_Google_Tensor_G5.litertlm | litert | Gemma | 4 | E2B | | it | (SoC build) | ? | device=Tensor G5 NPU |
| 105 | litert-community/gemma-4-E2B-it-litert-lm | gemma-4-E2B-it-web.task | litert | Gemma | 4 | E2B | | it | | ? | target=web |
| 106 | litert-community/Qwen2.5-1.5B-Instruct | Qwen2.5-1.5B-Instruct_multi-prefill-seq_q8_ekv4096.litertlm | litert | Qwen | 2.5 | 1.5B | | Instruct | q8 | ~8 | ekv4096 = KV len (inferred) |
| 107 | litert-community/Gemma3-1B-IT | Gemma3-1B-IT_multi-prefill-seq_q4_block128_ekv4096.task | litert | Gemma | 3 | 1B | | IT | q4 block128 | ~4.1 | glued version, uppercase IT |
| 108 | litert-community/gemma-3-270m-it | gemma3-270m-it-q8.qualcomm.sm8650.litertlm | litert | Gemma | 3 | 270M | | it | q8 | ~8 | device=Snapdragon SM8650 |
| 109 | litert-community/Qwen3-0.6B | Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm | litert | Qwen | 3 | 0.6B | | | int4 w, block32, fp32 act | ~4.5 | |
| 110 | google/gemma-3n-E2B-it-litert-lm | gemma-3n-E2B-it-int4.litertlm | litert | Gemma 3n | 3n | E2B | | it | int4 | ~4 | |
| 111 | HuggingFaceTB/SmolLM2-135M-Instruct | onnx/model_q4f16.onnx | onnx | SmolLM | 2 | 135M | | Instruct | q4f16 | ~4 | |
| 112 | LiquidAI/LFM2.5-24B-A2B-ONNX | onnx/model_q4f16.onnx_data | onnx-data | LFM | 2.5 | 24B | 2B | | q4f16 | | external weights of model_q4f16.onnx |
| 113 | meta-llama/Llama-3.1-8B-Instruct | original/consolidated.00.pth | pickle | Llama | 3.1 | 8B | | Instruct | | 16 | **pickle: skip**; gated manual |
| 114 | mistralai/Mixtral-8x7B-Instruct-v0.1 | consolidated.00.pt | pickle | Mixtral | v0.1 | 8x7B | | Instruct | | | **pickle: skip** |
| 115 | mistralai/Mistral-7B-Instruct-v0.2 | pytorch_model-00001-of-00003.bin | pickle | Mistral | v0.2 | 7B | | Instruct | | | **pickle**, shard 1/3 |
| 116 | deepseek-ai/DeepSeek-R1-Distill-Qwen-7B | model-00001-of-000002.safetensors | st | DeepSeek R1→Qwen | R1 | 7B | | Distill | BF16 | 16 | **6-digit shard total** |
| 117 | Qwen/Qwen3.5-4B | model.safetensors-00001-of-00002.safetensors | st | Qwen | 3.5 | 4B | | | BF16 | 16 | odd shard prefix |
| 118 | google/gemma-3n-E2B-it | repo | st | Gemma 3n | 3n | E2B | | it | BF16 | 16 | raw 5,439,438,272 params |
| 119 | Qwen/Qwen3-30B-A3B-Thinking-2507 | repo | st | Qwen | 3 (2507) | 30B | 3B | Thinking | BF16 | 16 | 30,532,122,624 params |
| 120 | microsoft/Phi-4-mini-reasoning | repo | st | Phi | 4 | mini | | Reasoning | BF16 | 16 | 3,836,021,760 params |
| 121 | mistralai/Mistral-Small-3.2-24B-Instruct-2506 | repo | st | Mistral | 3.2 (2506) | 24B (Small) | | Instruct | | | tier + size + date |
| 122 | mistralai/Devstral-Small-2-24B-Instruct-2512 | repo | st | Devstral | 2 (2512) | 24B (Small) | | Instruct | | | version between tier and size |
| 123 | HuggingFaceTB/SmolLM3-3B-Base | repo | st | SmolLM | 3 | 3B | | Base | | | |
| 124 | meta-llama/Llama-3.1-405B-FP8 | repo | st | Llama | 3.1 | 405B | | | FP8 | 8 | 221 weight files |
| 125 | Qwen/Qwen3.8-Flash-Next | repo | st | Qwen | 3.8 | (Flash) | | Next | | | no size token; 131 shards |
| 126 | mistralai/Mixtral-8x22B-Instruct-v0.1 | repo | st | Mixtral | v0.1 | 8x22B | | Instruct | | | |
| 127 | HauhauCS/Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-MTP-GGUF | Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-FastMTP-32K.gguf | gguf | Qwen | 3.8 | 27B | | Uncensored, Aggressive | (none) | ? | role=draft (FastMTP), `32K` context; Hub `gguf` summary came from this file |
| 128 | HauhauCS/Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-MTP-GGUF | Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-Q4_K_P.gguf | gguf | Qwen | 3.8 | 27B | | Uncensored, Aggressive | Q4_K_P | 5.25 (live) | custom label |

Sizes for live-bpw rows came from `tree` (bytes) ÷ `safetensors.total` or `gguf.total` of the same repo.

---

## 15. Recommendations for Sherpa

1. **Browse** with one `GET /api/models` per page using `expand[]` (§2.4); filters: `filter=gguf` (Android+iOS
   llama.cpp), `filter=mlx` (iOS MLX), `filter=litert-lm`/`tflite` (Android NPU), plus `pipeline_tag=text-generation`
   or `image-text-to-text`. Sort chips: Trending (`trendingScore`), Downloads, Likes, Recently updated (`lastModified`),
   New (`createdAt`; only one with ascending). Cap `limit` ≤ 50, follow `Link`, dedupe by `_id`.
2. **Detail screen**: `GET /api/models/{repo}/revision/main?blobs=true` once → pin `sha`; group siblings into
   *variants* = (quant label, shard set, folder) + attach sidecars (mmproj, draft) using llama.cpp's matching rules
   (§13.2); list unsupported/blocked files greyed with reasons (pickle, Q4_0_4_4, GGML, big-endian, bnb, EXL).
3. **Device-fit engine** inputs, in order of trust: real bytes (sum of shard sizes + mmproj) → GGUF header (Range-peek
   ≤ 8 MB: layers, n_head_kv, head_dim, ctx, vocab) → `safetensors.total` → name. Never use name-implied bpw or the repo
   `gguf.total`/`totalFileSize` for memory math. MoE: memory ∝ total params, speed ∝ active (`A3B`).
4. **Downloader**: manual redirect handling, Range resume, `Accept-Encoding: identity`, re-resolve on 403/expiry,
   validate `Content-Range` total, SHA-256 verify against `lfs.oid`, check `X-Xet-Hash` unchanged before resuming,
   concatenate `.partNofM` byte-splits, keep llama.cpp `-0000N-of-0000M` shards as separate files in one folder.
5. **Auth**: implement "Sign in with Hugging Face" as a public OAuth app (Auth Code + PKCE S256, custom-scheme redirect,
   scopes `openid profile gated-repos inference-api`), device flow fallback, paste-token fallback. Always attach the
   token to Hub API/resolve calls once signed in (rate limits ×2 and gated access). Validate via `whoami-v2`.
6. **Gated UX**: show license + gate prompt from `cardData`, deep-link `https://huggingface.co/{repo}` in an auth
   session, then poll `HEAD resolve` on the smallest file; distinguish `auto` vs `manual` in copy.
7. **Rate-limit client**: parse `RateLimit`/`RateLimit-Policy` on every response, client-side token bucket per bucket
   (api/resolvers), honour `t`, JSON `retryAfter`, and `Retry-After`; exponential backoff on 5xx; cache list pages.
8. **Safety gate**: extension allowlist (`.gguf`, `.safetensors`, `.json`, `.jinja`, `.txt`, `.model` tokenizer,
   `.litertlm`, `.task`, `.tflite`, `.onnx`, `.onnx_data`); block pickles outright; additionally block any file with
   `securityFileStatus.status in {unsafe, suspicious}` from `paths-info expand=true`.
9. **Tool-use badge**: compute from chat template (GGUF header / `config.tokenizer_config.chat_template` /
   `chat_template_jinja`) with the regexes in §10; for remote models use router `supports_tools` per provider and pin a
   tool-capable provider suffix when the agent has tools.
10. **Remote models**: use `https://router.huggingface.co/v1` with the user's OAuth token (`inference-api` scope); fetch
    `/v1/models` (public, cache 1 h) to populate a "cloud" catalog with price/context/tools.
11. **Name parser**: tokenizer on `[-_. /]` with lookahead for multi-token quants (`Q4_K_M`, `UD-Q4_K_XL`,
    `MXFP4_MOE`, `IQ4_NL_XL`, `GPTQ-Int4`, `bnb-4bit`), longest-match quant table, glued-version splitter, context vs
    size disambiguation (`1M` after variant, `32K`), role prefixes first; run the §14 corpus as golden tests.

## 16. Risks

1. **Repo-level `gguf` summary is wrong for sizing** (samples a single file — sometimes a draft head); `num_parameters`
   filter inherits the error. Mitigation: per-file sizes + header peek.
2. **Anonymous rate limits on shared IPs** (observed a throttle from a shared egress IP after well under 500 of our own requests): mobile CGNAT users
   will see 429s while browsing unless signed in; limits for anon/free "subject to change".
3. **Signed URL expiry (1 h) + background download frameworks** that cache the redirected URL → resumes fail with 403.
4. **If-Range ignored by the CDN** → silent corruption if the file changes upstream between resume attempts unless we
   check `X-Xet-Hash`/pin commit and verify SHA-256.
5. **Undocumented list/detail endpoints** (absent from OpenAPI): fields (e.g. `likes30d`, provider-mapping shape,
   `gguf` extras) can change without notice; parse leniently and feature-flag.
6. **OAuth refresh-token behaviour for public clients unverified**; if absent, users re-auth every ~8 h (Spaces default).
   Discovery omits `none` auth method → strict OIDC libs may refuse.
7. **Deprecated GGUF types** (`Q4_0_4_4/4_8/8_8`) still widely listed (bartowski 2024 repos) and fail to load in current
   llama.cpp; new types (`Q1_0`, `Q2_0`, `NVFP4`) fail on older bundled runtimes → gate by bundled llama.cpp version.
8. **Gated/license**: quant repos may copy upstream gate text but be ungated, or vice versa; Llama/Gemma licenses carry
   use restrictions — legal review for in-app display/acceptance.
9. **Naming chaos** (custom labels `_K_P`, `oQ4e`, `UD-Q8_K_XL`, `lilicorr-`, `FastMTP`) → parser must degrade to
   "unknown quant, size from bytes" rather than mis-label.
10. **Pickle in otherwise-safe repos** (`original/consolidated.00.pth`, `pytorch_model.bin` next to safetensors) — a
    naive "download all" would fetch unsafe and huge files.
11. **Router tool support varies by provider**; `:fastest` can silently pick a provider without tools.
12. Model ecosystem churn: trending lists are dominated by uncensored/abliterated fine-tunes — content-policy filter
    needed for store review (App Store/Play).

## 17. Open questions for the product owner

1. Do we require sign-in for browsing (better rate limits) or allow anonymous browse with a soft prompt after 429?
2. Which OAuth scopes are acceptable to ask for at first sign-in (`inference-api` implies spend on the user's HF
   account) — split into incremental consent?
3. Should Sherpa offer HF Inference Providers (cloud) at all, and if so with whose billing (user's HF credits only)?
4. Default content filter: hide `uncensored/abliterated/OBLITERATED/heretic` and `license:other` repos by default?
5. Which formats ship in v1: GGUF only, or also MLX (iOS) and LiteRT-LM (Android NPU, SoC-specific files)?
6. Minimum bundled llama.cpp version / policy for new quant types (Q1_0, Q2_0, NVFP4, MXFP4) and for hiding removed ones.
7. Max download size and cellular policy (Wi-Fi only above N GB?); storage location (app sandbox vs user-visible).
8. Do we display Hub security scan results to users, or only block silently?
9. Is a "paste your own token" path acceptable for power users (fine-grained token instructions), given store policies?
10. Gated models: in-app acceptance via web view vs. external browser only (legal preference)?

---

## 18. Verification log (10 most load-bearing claims)

| # | Claim | How verified (2026-10-18) | Result |
|---|---|---|---|
| 1 | Range/resume works on Xet-backed LFS files | `curl -L -r 0-99 https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-IQ3_M.gguf`; tail range `-r 657289000-`; `-r 1000000-1000099` | `206`, `content-range: bytes 0-99/657289344`, bytes start `GGUF\x03`; tail 344 B; `416` past EOF |
| 2 | Resolve redirect target, headers and 1 h signature | `curl -sI .../resolve/main/...IQ3_M.gguf` + parse `Location` query | `302` → `us.aws.cdn.hf.co/xet-bridge-us/...`; `x-linked-size`, `x-linked-etag`(sha256), `x-xet-hash`, `x-repo-commit`; `Expires − now = 3600`; tampered Expires → `403 Auth failed: credentials expired` |
| 3 | CDN ETag = xetHash; If-Range ignored | GET with `If-Range: "deadbeef"` | still `206`; `etag` equals `x-xet-hash`, differs from `x-linked-etag` |
| 4 | Gated content error shape | `curl -D - https://huggingface.co/meta-llama/Llama-3.2-1B-Instruct/resolve/main/config.json` (no token) | `401`, `x-error-code: GatedRepo`, message "...restricted. You must have access to it and be authenticated..."; `tree` of same repo `200` |
| 5 | Allowed `expand[]` values | `?expand[]=bogus` on list and single endpoints | `400` listing 30 values (list) / 32 values (single adds `childrenModelCount`,`usedStorage`) |
| 6 | Sort/direction/limit rules | `sort=downloads&direction=1`, `sort=createdAt&direction=1`, `sort=likes30d`, `sort=downloadsAllTime`, `limit=1001` | 400 "only descending..."; createdAt asc OK; likes30d OK; downloadsAllTime 400; 1000 items |
| 7 | Cursor pagination via Link (models + tree) | headers of `/api/models?...&limit=3` and `/tree/main?recursive=true&limit=3` | `link: <...&cursor=...>; rel="next"`; `cursor=garbage` → `400 Error parsing pagination cursor` |
| 8 | Rate-limit headers & anon quota | headers on every API/resolve call | `ratelimit: "api";r=...;t=...`, `ratelimit-policy: "fixed window";"api";q=500;w=300`; resolvers `q=3000;w=300`; one throttle body with `retryAfter: 48` |
| 9 | OAuth/OIDC capabilities | `curl https://huggingface.co/.well-known/openid-configuration`; POST `/oauth/token` with 1-char verifier; POST `/oauth/device` bogus client | PKCE S256, device_code + refresh_token grants listed; `invalid_request ... >=43 characters → at code_verifier`; `invalid_client Client not found` |
| 10 | Repo `gguf` summary is from one arbitrary file | `?expand[]=gguf` on `HauhauCS/Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-MTP-GGUF` vs its tree | `total 1863907840`, `totalFileSize 903453952` == `...-FastMTP-32K.gguf`, while main quants are 10–31 GB |

Additional spot checks: router `/v1/models` public (200, 133 models, `supports_tools` per provider); `/api/models/{repo}/scan`
on `ykilcher/totally-harmless-model` → `filesWithIssues:[{"path":"pytorch_model.bin","level":"unsafe"}]`; GGUF header
Range-peek of `Llama-3.2-1B-Instruct-Q4_K_M.gguf` (KV end at byte 7,822,851); `library=mlx` ignored (same results as
unfiltered); non-LFS `tokenizer.json` served `content-encoding: gzip` with weak ETag.

### Sources

- Live API: `https://huggingface.co/api/models`, `/api/models/{repo}[/revision/{rev}]`, `/tree`, `/paths-info`,
  `/treesize`, `/refs`, `/scan`, `/xet-read-token`, `/api/models-tags-by-type`, `/{repo}/resolve/...`,
  `/.well-known/openid-configuration`, `/oauth/*`, `https://router.huggingface.co/v1/models`.
- Docs: https://huggingface.co/docs/hub/api (→ OpenAPI), https://huggingface.co/.well-known/openapi.md,
  https://huggingface.co/docs/hub/rate-limits, https://huggingface.co/docs/hub/oauth,
  https://huggingface.co/docs/hub/spaces-oauth, https://huggingface.co/docs/hub/security-tokens,
  https://huggingface.co/docs/hub/security-pickle, https://huggingface.co/docs/hub/xet/index,
  https://huggingface.co/docs/hub/xet/legacy-git-lfs, https://huggingface.co/docs/inference-providers/index,
  https://unsloth.ai/docs/basics/unsloth-dynamic-2.0-ggufs.
- Source: huggingface_hub `src/huggingface_hub/hf_api.py`, `utils/_http.py`, `_oauth.py` (main);
  huggingface.js `packages/hub/src/lib/oauth-handle-redirect.ts`, `oauth-login-url.ts` (main);
  llama.cpp (vendored in llama_cpp_python 0.3.36): `tools/quantize/quantize.cpp`, `tools/quantize/README.md`,
  `ggml/include/ggml.h`, `include/llama.h`, `src/llama-model-loader.cpp`, `src/llama.cpp`, `common/download.cpp`,
  `gguf-py/gguf/constants.py`, `gguf-py/gguf/utility.py`.
- bartowski README (`bartowski/Llama-3.2-3B-Instruct-GGUF/README.md`) for `_L/_XL` and `Q4_0_X_X` semantics.
