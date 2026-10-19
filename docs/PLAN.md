# Sherpa — architecture and delivery plan

Sherpa is an open, local-first agent harness for Android and iOS. It runs agent loops against on-device
models (llama.cpp, MLX, LiteRT-LM, platform models) or remote models (OpenAI-compatible, OpenAI Responses,
Anthropic), discovers models on the Hugging Face Hub, manages its own context under token and memory
pressure, and is a full MCP host (tools, resources, prompts, elicitation, MCP Apps).

This document is the plan of record. It was written after a verified research pass whose digests live in
[`docs/research/`](research/) (each digest ends with a verification log). Decisions below cite them as
`R01`…`R13`.

---

## 1. What the research changed

Things that would have been built wrong from memory alone:

| # | Finding | Consequence | Source |
|---|---|---|---|
| 1 | The current MCP revision is **2026-07-28 and stateless**: no `initialize`, no `Mcp-Session-Id`; per-request `_meta` protocol/capabilities; `server/discover`; `resultType` on every result; multi-round-trip `InputRequiredResult` replaces server→client requests; `subscriptions/listen` replaces the GET stream; POST-only Streamable HTTP with `Mcp-Method`/`Mcp-Name`/`Mcp-Param-*` headers. Most deployed servers are still 2025-11-25. | The MCP client is **dual-era** from day one, with per-origin era detection and one consent UI fed by both eras. | R01 |
| 2 | MCP auth 2026-07-28 adds issuer identity checks, RFC 9207 `iss`, issuer-keyed credentials, Client ID Metadata Documents ahead of (now deprecated) DCR, and requires the `resource` parameter everywhere. The TS SDKs get several of these wrong. | OAuth is **pure Dart** with injected browser/storage/clock; only the browser hop is native. | R02 |
| 3 | MCP Apps (`io.modelcontextprotocol/ui`, spec 2026-01-26) needs an inner sandboxed `srcdoc` iframe even on native, and the host must enforce tool visibility itself. `webview_flutter`'s JS channel uses `addJavascriptInterface`, which leaks into every frame. | Sherpa ships **its own small WebView plugin** (Android `addWebMessageListener` with origin rules, iOS non-persistent store + content rules). | R03, R07, R06 |
| 4 | Current Anthropic models **bind replayed thinking to the exact prefix**; editing anything earlier (system prompt, tool list, an old tool result) returns 400. They also reject sampling params and forced `tool_choice`. | Context management uses **segments**: rewrites only at user-turn boundaries, reasoning from older prefixes is dropped, the plan lives in the transcript, and large tool sets go through a stable search/call proxy instead of changing the tool list. | R10 |
| 5 | OpenAI's newest models only do tool calling over the **Responses API**. | Three remote adapters: Anthropic Messages, OpenAI Chat (with per-server quirk profiles), OpenAI Responses (stateless, `store:false`). | R10 |
| 6 | Reasoning field names differ per server (`reasoning_content` vs `reasoning`), context length is discovered differently on each, and some 429s (spend caps) must not be retried. | Server-type detection + quirk profiles; `quotaExceeded` error kind. | R10 |
| 7 | Material and Cupertino **moved out of the SDK** into `material_ui` / `cupertino_ui`; `go_router` 18 and `dynamic_color` 2 already use the new types. | The app is built on `material_ui` from the first commit, with `MaterialUiCompatibilityBridge` for legacy packages. | R09, R12 |
| 8 | SQLite now ships through build hooks; encryption is `sqlite3mc` selected by `hooks.user_defines` **in the root pubspec only** (a member pubspec is silently ignored → plaintext DB). | Root-level user_defines + a fail-closed `PRAGMA cipher` check + a CI test that inspects the file header. | R09 |
| 9 | HF's repo-level `gguf` summary describes an arbitrary file (e.g. an MTP draft). Xet-backed downloads support Range resume, but the CDN ignores `If-Range` and signed URLs expire after 1 h. | Device-fit uses real file sizes + a GGUF header Range-peek; downloads pin the commit, re-resolve on 403, check `X-Xet-Hash` before resuming, verify SHA-256 at the end. | R08 |
| 10 | Android's default packaging leaves `nativeLibraryDir` empty, so llama.cpp's directory-scan backend loader finds no CPU backend. | Bare-name, best-first CPU-variant loader in the engine. | R05 |
| 11 | No background GPU on iPhone; Metal command buffers from the background are rejected and MLX's default error handler exits the process. Gemini Nano refuses background use even in a foreground service. | Inference pauses at a token boundary on resign-active and checkpoints; background continuation is Android (foreground service) or remote handoff. | R06, R07 |
| 12 | Android 17 adds a per-app anonymous-memory limiter (≈2 GB foreground on 4 GB devices); only `TRIM_MEMORY_UI_HIDDEN/BACKGROUND` still fire. | Admission control before load, KV-size planning from measured headroom, kill forensics via `setProcessStateSummary`. | R07 |

---

## 2. Architecture

Strict downward dependencies:

```
┌──────────────────────────────────────────────────────────────────────────┐
│ 1. UI            app/ (Flutter, material_ui + cupertino_ui, Riverpod DI) │
├──────────────────────────────────────────────────────────────────────────┤
│ 2. Session/Agent sherpa_core: AgentRunner, ContextManager, handoff, plan │
├────────────────────────────────┬─────────────────────────────────────────┤
│ 3. Providers  sherpa_providers │ MCP  sherpa_mcp (client, auth, apps)    │
│    local: sherpa_inference     │ Hub  sherpa_hub (catalog, fit, parse)   │
├────────────────────────────────┴─────────────────────────────────────────┤
│ 4. Platform  sherpa_net · sherpa_data · sherpa_inference (native engine) │
│              sherpa_platform (memory/thermal/device/background)          │
│              sherpa_webview (sandboxed MCP Apps host view)               │
└──────────────────────────────────────────────────────────────────────────┘
```

Rules:
- `sherpa_core` depends only on `meta`. No Flutter, no IO. Everything is injected (`Clock`, `IdGenerator`,
  `SessionStore`, `ModelProvider`, `ToolRouter`, `ContextManager`, `ContextStrategy`, `MemoryMonitor`,
  `ApprovalHandler`).
- Pure-Dart packages (`sherpa_net`, `sherpa_providers`, `sherpa_mcp`, `sherpa_hub`, `sherpa_data`) are tested
  with `dart test` on the host. Flutter plugins hold only inference, background work, secure storage, the
  sandboxed WebView, and OS signals.
- Business logic never lives in Kotlin/Swift.

### Core interfaces (all fakeable)

| Interface | Package | Real implementations | Test double |
|---|---|---|---|
| `ModelProvider` | core | Anthropic, OpenAI Chat, OpenAI Responses, llama.cpp (FFI / Android `:inference` process), MLX, LiteRT-LM, Gemini Nano (AICore), Apple FM | `ScriptedProvider`, `FakeEngineHost`, fake Pigeon backends |
| `ContextManager` / `ContextStrategy` | core | `LadderContextManager` (M3), model/extractive summarizers | `PassthroughContextManager`, deterministic summarizer |
| `ToolRouter` | core | `CompositeToolRouter` over built-ins, on-device servers, `McpToolRouter` | `LocalToolRouter` |
| `McpConnection` | mcp | dual-era Streamable HTTP, legacy HTTP+SSE, in-process | mock server (shelf) + reference servers |
| `ModelCatalog` | hub | `HfHubCatalog`, local-folder / LAN catalogs | fixture catalog |
| `MemoryMonitor` | core | `sherpa_platform` (iOS/Android) | `FakeMemoryMonitor` |
| `SessionStore` | core | Drift/SQLite (`sherpa_data`) | `InMemorySessionStore` |

### Agent loop (built, `sherpa_core`)
ReAct loop: prepare context → stream model → gate tool calls (annotation-driven policy, scoped/expiring
grants) → run calls in a bounded parallel pool → repeat. A checkpoint is written after every transition;
`resume()` continues after process death and re-runs only idempotent interrupted calls. Invariants: every
tool call is answered before the next model call (also when cancelled/denied/interrupted); the transcript is
append-only (retry/edit create branches); tool output is data (trust-boundary clause + tool-result blocks).

### Context segments (cross-cutting, from finding 4)
- The transcript is immutable. Pruning, truncation and compaction are **overlays** on the context view, so
  the original stays on disk, the UI can diff, and undo deletes the overlay.
- `PreparedContext.prefixKey` fingerprints system prompt + tool schemas + overlays. Each assistant reply is
  stamped with it; for `HistoryPolicy.appendOnly` models reasoning is replayed only under the same key.
- Rewrites (new overlays) for append-only models happen only at user-turn boundaries, never mid tool loop.
- The plan/todo list is carried by `update_plan` tool results (and by compaction summaries), not the system
  prompt, so updating it never invalidates prompt caches or KV prefixes.
- Tool budget: a stable core set plus `tool_search` / `call_tool` proxies for the long tail, so the tool
  list changes only at segment boundaries. Retrieval ranks tools; small local models see ≤ 8 (≤ 5 below 2B).

### Local inference engine (M2)
One C++17 engine, `native/engine` (`sherpa_engine`), wraps llama.cpp + `common` (Jinja chat templates,
tool-call parsers, lazy grammars, speculative decoding, state files) behind a **small versioned C ABI**:
model/session lifecycle, `generate_async` with a typed event callback (text / reasoning / tool-call deltas,
usage, perf, finish), thread-safe cancel, tokenize/count, state save/load (prefix cache), LoRA set, bench.

- **iOS and host tests:** Dart FFI into the engine (`NativeCallable.listener` for events; all calls on a
  worker thread, never the UI isolate).
- **Android:** the same `.so`, hosted by default in an **isolated `:inference` process** (bound service +
  AIDL → Pigeon event channel) so a native crash restarts the engine instead of killing the app; in-process
  FFI is the fallback.
- MLX (iOS), LiteRT-LM and Gemini Nano (Android), and Apple Foundation Models are separate providers behind
  Pigeon, because their SDKs are Swift/Kotlin only. They live in their own plugins (`sherpa_apple_ml`,
  `sherpa_litert`) so the llama.cpp plugin stays lean and each app build only carries what its platform
  uses.
- The Android host is a *private* process, not `android:isolatedProcess`: an isolated uid cannot open the
  GGUF that llama.cpp mmaps by path (implementation note, M2).
- Build: pinned llama.cpp commit, `native/llama/build_{android,ios}.sh` produce prebuilt artifacts
  (`jniLibs`, xcframework); arm64-v8a only; KleidiAI on; GPU/NPU feature-detected and parity-checked against
  CPU before use.

### MCP host (M4–M5)
Dual-era client behind `McpConnection`. Default: adopt `mcp_dart` 2.4.x for protocol plumbing **only after a
code audit in M4**, behind our interface with contract tests against the reference servers; OAuth is ours
(pure Dart, R02 algorithm). Elicitation forms are native widgets; URL elicitation opens the system browser
only after showing the full URL. MCP Apps render in `sherpa_webview`: trusted shell page + inner
`sandbox="allow-scripts"` `srcdoc` iframe (no `allow-forms`: form submission is blocked by CSP anyway, and
apps use button handlers), CSP built only from declared domains, no network
until the user consents per server, non-persistent storage, host-enforced visibility and same-server rules.

---

## 3. Repository layout

```
pubspec.yaml                 pub workspace root (+ hooks.user_defines for sqlite3mc)
analysis_options.yaml
packages/
  sherpa_core/               domain model, interfaces, AgentRunner, context, handoff, testing/ doubles
  sherpa_net/                SSE decoder, URL policy (SSRF), retry/backoff, redaction
  sherpa_providers/          OpenAI Chat, OpenAI Responses, Anthropic, server detection, tool-call repair
  sherpa_data/               Drift schema + SessionStore, settings, model library, MCP servers, downloads
  sherpa_hub/                HF Hub client, name parser, device-fit engine, download planner
  sherpa_mcp/                JSON-RPC, transports, era detection, tool router + hygiene, in-process servers
  sherpa_auth/               OAuth 2.1 for MCP servers and Hugging Face
  sherpa_markdown/           incremental streaming Markdown renderer
  sherpa_inference/          Flutter plugin: engine FFI + Android :inference service, lifecycle, autotune
  sherpa_litert/             Flutter plugin (Android): LiteRT-LM and Gemini Nano providers
  sherpa_apple_ml/           Flutter plugin (iOS): MLX and Apple Foundation Models providers
  sherpa_platform/           Flutter plugin: memory/thermal/device signals, background execution
  sherpa_webview/            Flutter plugin: sandboxed WebView for MCP Apps (shell page + bridge)
  sherpa_evals/              eval harness L0-L4 (scripted, local model, remote) and host benchmarks
app/                         Flutter app: design system, screens, wiring
native/
  engine/                    sherpa_engine C ABI over llama.cpp (+ host CMake build and C++ tests)
  llama/                     pinned commit, fetch/build scripts (LLAMA_CPP_SRC override for offline)
bench/                       perf budgets (JSON baselines per device class), frame-bench scaffolding
tools/                       test_all.sh, perf_gate.dart
docs/                        PLAN.md, research/, milestone notes, ADRs
.github/workflows/           CI
```

---

## 4. Decisions

Reversal cost is "before first store release" — nothing here has users yet.

| Decision | Choice | Alternatives considered | Reversal cost |
|---|---|---|---|
| UI | Flutter 3.47 + `material_ui` / `cupertino_ui`, own token layer | in-SDK Material (being deprecated) | Medium |
| State/DI | Riverpod 3, no codegen, retry disabled globally | provider, signals, plain notifiers | Low (core is UI-agnostic) |
| Monorepo | native pub workspace, one lockfile | melos | Low |
| Persistence | Drift + sqlite3mc (encrypted), key in Keychain/Keystore, fail closed | SQLCipher, plaintext | Medium after release |
| Domain models | hand-written immutable classes + JSON, no freezed | freezed / json_serializable | Low |
| Engine boundary | shared C++ engine + C ABI; FFI on iOS/host, isolated process on Android | per-platform JNI/Swift wrappers | Medium |
| Android min / target / compile | **minSdk 29**, target 36, compile 37 | 24 (Flutter default) | Low |
| iOS deployment target | **17.0** (MLX Swift) | 16.4 (llama.cpp min) | Low |
| ABIs | arm64-v8a only (x86_64 for emulator dev) | +armeabi-v7a | Low |
| MCP protocol | dual-era client; `mcp_dart` behind `McpConnection` pending M4 audit | fully in-house | Low (interface) |
| MCP Apps WebView | own plugin | webview_flutter, flutter_inappwebview | Medium |
| Remote OpenAI | Chat Completions for compatible servers, Responses for api.openai.com | Chat only | Low |
| Downloads | background_downloader + own resolve/verify layer | hand-rolled URLSession/WorkManager | Low |
| App identity | name "Sherpa", id `io.github.mihok.sherpa` | — | **High after publishing** |
| License | MIT (repo), third-party notices generated | — | High |

---

## 5. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Low-RAM devices (4–6 GB) + Android 17 limiter + iOS ~6 GB cap kill the app mid-generation | Admission control from measured headroom; KV sized per device tier; quantized KV; out-of-process engine on Android; kill forensics + automatic downgrade |
| No iPhone background GPU | Pause at a token boundary, persist KV + checkpoint, resume in foreground; optional remote handoff |
| MCP spec churn (stateless era, deprecated sampling/roots) | Era adapters behind one interface; conformance tests per era |
| MCP Apps WebView behaviours unverified on devices (srcdoc CSP inheritance, interception gaps, WebRTC) | Shell-page design that does not rely on interception; device test matrix; network off by default |
| Anthropic prefix binding → hard 400s | Segment model + a debug assertion that diffs consecutive request prefixes |
| Small local models fail tool calls | Native template parsers + lazy grammar, ≤8 tools, schema normalization, repair + 2 retries, approvals for repaired non-read-only calls |
| Unverifiable here: iOS builds/Swift, on-device behaviour | iOS code reviewed against docs; CI on macOS runners; everything testable is pushed into pure Dart / host C++ |
| Supply chain (models, native libs) | Pinned commits, hashed artifacts, pickle formats refused, Hub scan status surfaced |

---

## 6. Milestones

Each milestone ends with: tests passing, Android debug build passing in CI, a README section, known gaps.

- **M1 — Core loop + remote providers + chat UI.** Core contracts and `AgentRunner` (done); `sherpa_net`
  (done); providers (Anthropic, OpenAI Chat with quirk profiles, OpenAI Responses) tested against golden
  SSE fixtures and a local fake server; encrypted Drift store; app shell on `material_ui` with design tokens,
  adaptive layout, streaming chat (incremental Markdown, reasoning region, tool cards, approvals sheet,
  message actions and branches), provider setup with keys in secure storage, privacy indicator, stop-all.
- **M2 — Hub, device-fit, downloads, local inference, optimization.** Hub client, name parser (golden corpus
  from R08), device-fit engine (weights + KV at chosen context + overhead → Fits/Tight/Won't fit), download
  manager, `sherpa_engine` with host tests on a real GGUF, FFI provider, Android isolated service, iOS
  wiring; then autotune, KV quantization, prefix-cache persistence, speculative decoding, perf lab, each with
  a benchmark that proves the gain on the host and a device script.
- **M3 — Context manager.** Token budget with exact local counts, the escalation ladder (prune → truncate →
  compact → handoff → hard stop) under the segment rules, structured summaries (R11 schema), handoff bundle
  v1 (export/import, QR for small ones), memory monitor plugin, context ring / inspector / diff / undo.
- **M4 — MCP client.** Dual-era transports, OAuth 2.1, all primitives, annotation-driven approvals,
  tool budget (search/proxy), namespacing + schema normalization, server directory, logs and debug console.
- **M5 — MCP Apps, elicitation, sampling.** `sherpa_webview`, Apps bridge, inline/fullscreen hosting,
  native elicitation forms, sampling with approval.
- **M6 — Polish.** Accessibility pass, platform polish, background execution, CI perf budgets, evals.

---

## 7. Open questions (defaults in bold; I am proceeding with them)

1. Distribution: **Play + App Store**; an F-Droid flavor later would drop ML Kit (QR) and Play components.
2. Background agent runs: **Android yes (foreground service, `specialUse` for long runs, `shortService` to
   finish a reply); iOS pause-and-resume** (optional remote handoff).
3. `api.openai.com` as a v1 target: **yes** (hence the Responses adapter).
4. Show model reasoning: **collapsed, dimmed, opt-in expand**.
5. Sampling for MCP servers: **off by default**, per-server opt-in with per-request approval (deprecated in
   the spec, so not a priority).
6. MCP Apps network: **none by default**; per-server consent for declared `connectDomains` only.
7. Uncensored/abliterated models in the Hub browser: **hidden by default**, toggle in settings.
8. Encrypt the DB for everyone: **yes**.
9. Compaction may use a remote model when the session is local: **no, unless the user opts in**.
10. OAuth redirect: **custom scheme now**; claimed HTTPS + a Client ID Metadata Document needs a Sherpa domain
    (owner to provide).

## 8. Verification in this environment
- Available: Flutter 3.47.7, Android SDK 36/37 + NDK r29 (debug APK builds), host llama.cpp build, a real
  Qwen3-0.6B GGUF (`ac2d9771…` matches the Hub LFS oid).
- Not available: macOS/Xcode (iOS code is written against docs and compiled in CI only), physical devices,
  emulators (no KVM).
