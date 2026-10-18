# 01 — Model Context Protocol: current spec digest for a client/host implementer

Researched 2026-10-18. Everything below was checked against primary sources: the spec site, the spec repo's `schema.ts` on raw.githubusercontent.com, npm/pub.dev package contents, and the vendored TS SDK. Anything I could not check is marked **UNVERIFIED**.

Abbreviations: **M** = modern era (2026-07-28+, stateless). **L** = legacy era (2025-11-25 and earlier, `initialize` handshake). "Spec" = modelcontextprotocol.io.

---

## 0. Version facts (verified)

| Item | Value | Source |
|---|---|---|
| **Latest released spec revision** | **`2026-07-28`** (`LATEST_PROTOCOL_VERSION = "2026-07-28"`) | https://raw.githubusercontent.com/modelcontextprotocol/modelcontextprotocol/main/schema/2026-07-28/schema.ts (line 30); https://modelcontextprotocol.io/specification/latest names `schema/2026-07-28/schema.ts` |
| Draft vs 2026-07-28 | Identical apart from link paths. The draft changelog only says "Changes since the most recent release will accumulate here." | `schema/draft/schema.ts` diff; https://modelcontextprotocol.io/specification/draft/changelog.md |
| Previous revisions | `2025-11-25`, `2025-06-18`, `2025-03-26`, `2024-11-05` (plus SDK-only `2024-10-07`) | https://modelcontextprotocol.io/llms.txt |
| TS SDK v1 `@modelcontextprotocol/sdk@1.32.1` (npm `latest`, published 2026-10-05) | `LATEST_PROTOCOL_VERSION = '2025-11-25'`; `SUPPORTED_PROTOCOL_VERSIONS = ['2025-11-25','2025-06-18','2025-03-26','2024-11-05','2024-10-07']`; `DEFAULT_NEGOTIATED_PROTOCOL_VERSION = '2025-03-26'`. **No `server/discover`, MRTR or `subscriptions/listen`** (L only). | `/opt/vendor-src/npm/modelcontextprotocol-sdk-1.32.1/package/dist/esm/types.js` lines 2-4 |
| Gotcha in SDK v1 | `dist/esm/spec.types.d.ts` was generated from the *pre-release draft* and declares `LATEST_PROTOCOL_VERSION = "DRAFT-2026-v1"`. Never copy constants from that file. | same package, `spec.types.d.ts` line 18 |
| TS SDK v2 (split packages) `@modelcontextprotocol/client` / `server` / `core` **2.3.1** (2026-10-05; 2.0.0 shipped 2026-07-27) | Dual-era client. `FIRST_MODERN_PROTOCOL_VERSION = "2026-07-28"`, `SUPPORTED_MODERN_PROTOCOL_VERSIONS = ["2026-07-28"]`. The legacy list still has `LATEST_PROTOCOL_VERSION = "2025-11-25"`. `ClientOptions.versionNegotiation.mode` is `'legacy'` (**the default**), `'auto'` (probe `server/discover`, conservative fallback) or `{pin:'2026-07-28'}`. Node >= 20. | npm registry; tarball `dist/src-WCy6ifGf.mjs` ~L474-489, `dist/index.mjs` ~L2394-2560, `dist/index.d.mts` ~L1836-1875 |
| `@modelcontextprotocol/ext-tasks` | 0.2.2 (2026-09-30). Schema snapshot `2026-07-28` is "Stable". | npm; https://raw.githubusercontent.com/modelcontextprotocol/ext-tasks/main/README.md |
| `@modelcontextprotocol/ext-apps` | 2.0.3 (2026-09-25). Dist-tags `latest` **and** `release-2.0` both point to 2.0.3 | npm (`npm view @modelcontextprotocol/ext-apps dist-tags`) |
| Dart `mcp_dart` | **2.4.3** (2026-10-14). `stableProtocolVersion = defaultProtocolVersion = "2026-07-28"`, `latestInitializationProtocolVersion = "2025-11-25"`, `legacyProtocolVersions = [2025-11-25, 2025-06-18, 2025-03-26, 2024-11-05, 2024-10-07]`. The client probes `server/discover` and can fall back to `initialize`. SDK `^3.4.0`; supports android/ios. | https://pub.dev/packages/mcp_dart; archive `lib/src/types/json_rpc.dart` L15-135, `lib/src/client/client.dart` |
| Dart `dart_mcp` (dart-lang/ai) | 0.5.2 (2026-06-29). `ProtocolVersion.latestSupported = v2025_11_25`, so **L only**. | https://pub.dev/packages/dart_mcp; `lib/src/api/api.dart` L25-50 |
| Dart `mcp_client` | 3.0.0 (2026-10-13). The pubspec description claims support for 2024-11-05 through 2026-07-28. However, `McpProtocol.supportedVersions` *excludes* `v2026_07_28` and the code comment says "stateless request path is not implemented". **UNVERIFIED whether it really speaks M.** | pub.dev archive `lib/src/protocol/protocol.dart` L31-52 |

**Bottom line:** today's spec is stateless MCP (`2026-07-28`). It is under three months old, and most deployed servers, plus the default mode of the most popular SDK, are still on the L era (2025-06-18 or 2025-11-25). **A production client must be dual-era.**

---

## 1. What changed in 2026-07-28 (vs 2025-11-25)

Source: https://modelcontextprotocol.io/specification/2026-07-28/changelog.md and https://modelcontextprotocol.io/specification/2026-07-28/deprecated.md

**Removed (breaking):**
1. Protocol-level sessions and the `Mcp-Session-Id` header (SEP-2567). List endpoints must not vary per connection. Cross-call state now lives in server-minted handles passed as tool arguments.
2. The `initialize` request and `notifications/initialized` (SEP-2575). Every request now carries `_meta["io.modelcontextprotocol/protocolVersion"]` and `_meta["io.modelcontextprotocol/clientCapabilities"]`, and SHOULD carry `_meta["io.modelcontextprotocol/clientInfo"]`. Results SHOULD carry `_meta["io.modelcontextprotocol/serverInfo"]`.
3. The HTTP GET SSE endpoint, `resources/subscribe` and `resources/unsubscribe`. These are replaced by **`subscriptions/listen`**.
4. **`ping`**, **`logging/setLevel`** and **`notifications/roots/list_changed`**. The log level is now per request via `_meta["io.modelcontextprotocol/logLevel"]`.
5. Tasks as a core feature. They are now the extension `io.modelcontextprotocol/tasks` (SEP-2663): `tasks/result` and `tasks/list` are gone, `tasks/update` is new, and `Tool.execution.taskSupport` is gone.
6. **Server-initiated JSON-RPC requests** (`sampling/createMessage`, `elicitation/create`, `roots/list`). These are replaced by **Multi Round-Trip Requests (MRTR)**: `InputRequiredResult` plus a client retry carrying `inputResponses` (SEP-2322).
7. SSE resumability: no `Last-Event-ID` and no event-id redelivery. A broken stream means the in-flight request is lost and must be re-issued with a new id.
8. `notifications/elicitation/complete` and the `elicitationId` on URL elicitations. Error code `-32042` (URLElicitationRequired) is retired.

**Added:**
- `server/discover` (servers MUST implement it).
- A required `resultType` on every result (`"complete"`, `"input_required"`, or an extension value such as `"task"`).
- The `CacheableResult` fields `ttlMs` and `cacheScope`, required on `server/discover`, `tools/list`, `prompts/list`, `resources/list`, `resources/templates/list` and `resources/read` (SEP-2549). They are required only on `resultType: "complete"` results; `input_required` results carry no caching hints. *(The changelog bullet lists only the five list/read methods. `server/discover` comes from server/utilities/caching.md §Cacheable Results and from `DiscoverResult extends CacheableResult` in schema.ts.)*
- Required HTTP headers `Mcp-Method` and `Mcp-Name`, plus `x-mcp-header` → `Mcp-Param-{Name}` (SEP-2243).
- New error codes `-32020` HeaderMismatch, `-32021` MissingRequiredClientCapability and `-32022` UnsupportedProtocolVersion.
  - **Renumbered late in the cycle.** Pre-release drafts used `-32001` / `-32003` / `-32004` (changelog Minor change 12). Never emit or match on the old values. `-32001` also collides with TS SDK v1's `"Session not found"`.
  - Recognize these errors **by `error.code`, never by message text.** TS SDK v1 servers answer a modern probe with `-32000` and a message that reads "Unsupported protocol version" (see §2.1 Gotcha).
- An `extensions` field in both capability objects.
- Reserved OpenTelemetry `_meta` keys `traceparent`, `tracestate` and `baggage` (SEP-414).
- A recommendation that servers return `tools/list` in deterministic order.
- `inputSchema` and `outputSchema` may use any JSON Schema 2020-12 keyword, the `outputSchema` root may be non-object, and `structuredContent` may be any JSON value (SEP-2106). The revision also adds `$ref` resolution rules and DoS bounds.
- Resource-not-found changes from `-32002` to **`-32602`**.
- Auth: `iss` validation per RFC 9207 (SEP-2468); DCR must send `application_type` (SEP-837); credentials keyed per issuer (SEP-2352).

**Deprecated** (still functional; earliest removal is "first revision released on or after 2027-07-28"):
- **Roots**, **Sampling** and **Logging** (SEP-2577).
- **Dynamic Client Registration** (in favour of Client ID Metadata Documents, PR #2858).
- `includeContext: "thisServer"` and `"allServers"`.
- The **HTTP+SSE transport** (2024-11-05). Eligible for removal three months after SEP-2596 reaches Final.

Earlier deltas that still matter for L interop:
- **2025-06-18** removed JSON-RPC batching, added structured tool output, elicitation, resource links, the `title` field and `CompletionRequest.context`, required the `MCP-Protocol-Version` header, and introduced the RFC 8707 resource indicator. Source: https://modelcontextprotocol.io/specification/2025-06-18/changelog.md
- **2025-11-25** added icons, URL-mode elicitation, tools in sampling, CIMD, experimental tasks, titled and multi-select enums, SSE polling via server disconnect plus the `retry` field, and the JSON Schema 2020-12 default. Source: https://modelcontextprotocol.io/specification/2025-11-25/changelog.md

---

## 2. Base protocol: JSON-RPC rules (M; L differences noted)

Source: https://modelcontextprotocol.io/specification/2026-07-28/basic/index.md, `schema.ts`

- **JSON-RPC 2.0, UTF-8.** Request `id` is `string | number`, MUST NOT be `null`, and MUST NOT equal any id the sender has in flight. Notifications have no `id`, and the receiver MUST NOT respond to them.
- **Direction (M):** only the client sends **requests**. The client sends requests and (only on stdio) the `notifications/cancelled` notification, and never sends responses. The server sends responses plus notifications: request-scoped notifications, `subscriptions/listen` stream notifications, and on stdio `notifications/cancelled` to end a listen stream. Spec quote: "Servers **MUST NOT** initiate JSON-RPC requests, and clients do not send JSON-RPC responses" (https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/index.md). In L, the server *does* send requests (`ping`, `sampling/createMessage`, `elicitation/create`, `roots/list`, task methods) and the client must answer them.
- **Batching:** removed since 2025-06-18. **Never send arrays.** The TS SDK v1 server still parses arrays (`MAX_BATCH_SIZE`, see `server/webStandardStreamableHttp.js` ~L504). A 2025-03-26 peer might batch, so a client parser should tolerate an array body from such a peer. **UNVERIFIED how common that is.**
- **Result envelope (M):** `{"jsonrpc":"2.0","id":…,"result":{"resultType":"complete"|"input_required"|<ext>, "_meta"?:{…}, …}}`.
  - An absent `resultType` MUST be treated as `"complete"` (L servers never send it).
  - An unrecognized `resultType` MUST be treated as **invalid**. Only extension values whose extension was negotiated are allowed, for example `"task"`.
- **Error envelope:** `{"jsonrpc":"2.0","id"?:…,"error":{"code":int,"message":str,"data"?:any}}`. The `id` may be absent only if the request id was unreadable.

### 2.1 Error codes (M)

| Code | Name | When | HTTP status (Streamable HTTP) |
|---|---|---|---|
| -32700 | Parse error | | |
| -32600 | Invalid Request | | |
| -32601 | Method not found | Unknown method, or a capability-gated method that was not advertised | **404** + JSON-RPC body (M) |
| -32602 | Invalid params | Unknown tool or prompt, bad args, invalid cursor, invalid log level, **missing required `_meta` fields** (→ 400), **resource not found** (M) | 400 for missing `_meta` |
| -32603 | Internal error | | |
| **-32020** | HeaderMismatch | HTTP header/body mismatch, or missing or malformed `MCP-Protocol-Version` / `Mcp-Method` / `Mcp-Name` / `Mcp-Param-*` | **400** |
| **-32021** | MissingRequiredClientCapability | `data.requiredCapabilities: ClientCapabilities` | **400** |
| **-32022** | UnsupportedProtocolVersion | `data: {supported: string[], requested: string}` | **400** |
| -32002 | (L only) Resource not found | Clients SHOULD still accept it from L servers | |
| -32042 | (2025-11-25 only) URLElicitationRequired | `data.elicitations: ElicitRequestURLParams[]` (each has `elicitationId`) | |

Error-range rules:
- `-32000` to `-32019` is legacy and implementation-defined. Receivers MUST NOT assume any meaning for these codes except `-32002`.
- `-32020` to `-32099` is reserved for the spec.
- App-defined codes go outside `-32768` to `-32000`.
- SDK-local errors such as timeouts must not be mistakable for peer errors.
- **Gotcha:** TS SDK v1 servers emit `-32000` for many HTTP rejections, and `404` + `-32001 "Session not found"` (`server/webStandardStreamableHttp.js` L172, L388, L757). The TS v2 client deliberately does not treat `-32001`, `-32020` or `-32021` as era evidence (`NOT_PROBE_RECOGNIZED`, `dist/index.mjs` ~L2397-2406).
  - Concretely, a TS SDK v1 server answers a modern POST (no `initialize`, `MCP-Protocol-Version: 2026-07-28`) like this:
    - Stateful mode: `400` + `-32000` `"Bad Request: Server not initialized"`, or `"…Mcp-Session-Id header is required"`.
    - Stateless mode (`sessionIdGenerator` undefined): `400` + `-32000` `"Bad Request: Unsupported protocol version: 2026-07-28 (supported versions: 2025-11-25, …)"`.

    Both cases mean **legacy**: the code is not `-32022`, even though the message text looks modern. Source: `/opt/vendor-src/npm/modelcontextprotocol-sdk-1.32.1/package/dist/esm/server/webStandardStreamableHttp.js` L550-562, L737-781.

**Exact modern error bodies** (official examples, `schema/2026-07-28/examples/*/…json` on raw.githubusercontent.com). On HTTP, each of these is sent with status `400`:

```json
{"jsonrpc":"2.0","id":1,"error":{"code":-32022,"message":"Unsupported protocol version",
  "data":{"supported":["2026-07-28","2025-11-25"],"requested":"1900-01-01"}}}
{"jsonrpc":"2.0","id":1,"error":{"code":-32021,"message":"Server requires the elicitation capability for this request",
  "data":{"requiredCapabilities":{"elicitation":{}}}}}
{"jsonrpc":"2.0","id":1,"error":{"code":-32020,
  "message":"Header mismatch: Mcp-Name header value 'foo' does not match body value 'bar'"}}
```

The `supported` list of a dual-era server can include **legacy** versions (`"2025-11-25"` above). A modern-era retry must pick only a version `>= "2026-07-28"`. If only legacy versions are offered, the server must be reached through `initialize` with one of them (see §11).

### 2.2 `_meta`

- **Key format:** an optional prefix of dot-separated labels followed by `/`, then a name. Prefixes whose *second* label is `modelcontextprotocol` or `mcp` are reserved (for example `io.modelcontextprotocol/` and `dev.mcp/`; `com.example.mcp/` is not reserved). Use reverse DNS, for example `ai.sherpa/…`.
- **Per-request fields (M)**, in `params._meta`:

| Key | Type | Required |
|---|---|---|
| `io.modelcontextprotocol/protocolVersion` | string, e.g. `"2026-07-28"` | **Yes** |
| `io.modelcontextprotocol/clientCapabilities` | `ClientCapabilities` (`{}` = none) | **Yes** |
| `io.modelcontextprotocol/clientInfo` | `Implementation` | SHOULD on every request |
| `io.modelcontextprotocol/logLevel` | `LoggingLevel` | No (deprecated with Logging) |
| `progressToken` | string \| number | No |
| `traceparent` / `tracestate` / `baggage` | W3C strings | No |

  - A missing required field → `-32602`, and on HTTP `400`.
  - Servers MUST NOT infer capabilities from earlier requests. If they need one you did not declare they return `-32021`.
- **Result `_meta`:** `io.modelcontextprotocol/serverInfo` (an `Implementation`; SHOULD).
- **Notification `_meta`:** `io.modelcontextprotocol/subscriptionId` (MUST on `subscriptions/listen` stream notifications).
- Both `clientInfo` and `serverInfo` are self-reported. They must not drive behaviour or security decisions.
- `Implementation` = `{name, version, title?, description?, websiteUrl?, icons?}`.

### 2.3 JSON Schema rules (applies to `inputSchema`, `outputSchema`, `requestedSchema`)

- With no `$schema`, the dialect is **2020-12**. Implementations MUST support 2020-12 and MUST error gracefully on unsupported dialects. The spec examples use draft-07 via `$schema`.
- **MUST NOT auto-dereference network `$ref`.** An opt-in fetch must be off by default, use an allowlist, reject loopback/link-local/private addresses, and apply timeouts and size limits. A schema with an unresolved external `$ref` SHOULD be *rejected*, not treated as permissive.
- SHOULD bound validator cost: maximum depth, maximum number of subschemas, and a time budget.

### 2.4 Icons (`Icon {src, mimeType?, sizes?: string[] /*"48x48"|"any"*/, theme?: "light"|"dark"}`)

Icons appear on `Implementation`, `Tool`, `Prompt`, `Resource` and `ResourceTemplate`.
- A client that renders icons **MUST** support `image/png` and `image/jpeg`, and SHOULD support `image/svg+xml` and `image/webp`.
- **MUST** reject any scheme other than `https:` or `data:`, including `javascript:`, `file:`, `ftp:`, `ws:` and app schemes.
- Disallow cross-origin redirects and scheme changes.
- Fetch **without credentials** (no cookies or Authorization).
- Verify same origin as the server.
- Sniff magic bytes, keep a strict allowlist, and guard against huge images and frame counts.
- Treat SVG as potentially executable.

Source: basic/index.md §icons.

---

## 3. Version negotiation and era detection

### 3.1 Modern (M)

Source: https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning.md, https://modelcontextprotocol.io/specification/2026-07-28/server/discover.md

- There is no handshake. Each request declares its version and the server accepts or rejects each request independently. An unsupported version gets `-32022` with `data.supported`. The client SHOULD retry with a mutually supported version or surface an error.
- **`server/discover`** (servers MUST implement it; clients MAY call it):

```json
→ {"jsonrpc":"2.0","id":"discover-1","method":"server/discover",
   "params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",
     "io.modelcontextprotocol/clientInfo":{"name":"Sherpa","version":"1.0.0"},
     "io.modelcontextprotocol/clientCapabilities":{}}}}
← {"jsonrpc":"2.0","id":"discover-1","result":{"resultType":"complete",
   "supportedVersions":["2026-07-28"],
   "capabilities":{"tools":{},"resources":{}},
   "_meta":{"io.modelcontextprotocol/serverInfo":{"name":"ExampleServer","version":"1.0.0"}},
   "instructions":"…","ttlMs":3600000,"cacheScope":"public"}}
```

  `DiscoverResult extends CacheableResult { supportedVersions: string[]; capabilities: ServerCapabilities; instructions?: string }`. The `instructions` field replaces `InitializeResult.instructions` and is meant for the system prompt.

- **Era verdicts are per server, not per request.** Cache the verdict for the server process lifetime (stdio) or the origin (HTTP). It MAY be persisted per server configuration; re-probe when the cached assumption fails.

### 3.2 Compatibility matrix (verbatim summary)

| Client | Server | Outcome |
|---|---|---|
| Modern | Legacy | Fails. The server may reject, stay silent, or **process an era-ambiguous method such as `tools/call` under legacy semantics**. |
| Dual-era | Legacy | stdio: the probe returns a non-modern error or times out, so fall back to `initialize`. HTTP: a `4xx` without a recognized modern error body means fall back to `initialize`, and possibly further to HTTP+SSE. |
| Legacy | Modern | Fails. There is no fall-forward. A modern-only server SHOULD list its supported versions in the error it returns to `initialize`. |

### 3.3 Era detection rules

- **stdio** (transports/stdio.md §Backward Compatibility): send `server/discover` first, with the preferred modern version in `_meta`.
  - A `DiscoverResult` means modern.
  - A recognized modern error (`-32022`) means modern; pick a version from `supported` and **do not** fall back.
  - Any other error, **or no response within a timeout**, means legacy, so send `initialize`.
  - The fallback **MUST NOT** be keyed to one specific error code.
  - Probing is RECOMMENDED even for modern-only clients.
- **HTTP** (streamable-http.md §Backward Compatibility): attempt a modern request.
  - On `400`, inspect the body. A recognized modern JSON-RPC error means modern: retry or correct.
  - An empty body or an unrecognized error means fall back to `initialize`.
  - For the HTTP+SSE fallback, see §4.4.
- **TS SDK v2 reference classifier.** Source: `@modelcontextprotocol/client@2.3.1` `dist/index.mjs` L2390-2550 (`classifyProbeOutcome`, `classifyResult`, `classifyRpcError`, `classifyHttpError`), re-read from a fresh registry tarball at `/opt/vendor-src/npm/verify-mcp-client-2.3.1/`.
  - HTTP `401`/`403` → typed auth error. **Not** an era verdict; run auth, then re-probe.
  - HTTP `>=500` → hard error, no verdict.
  - Any other HTTP error status: if the body parses as a JSON-RPC error, classify it by code (rules below). An empty or non-JSON-RPC body → **legacy**.
  - A JSON-RPC error inside a normal response (e.g. `200` + `-32601` from a legacy server that does not check headers), or on stdio → classified by code: **only `-32022` can yield modern**. Every other code → legacy, including `-32001`, `-32020` and `-32021`.
  - `-32022` handling:
    - No usable `data.supported` (missing, empty or non-string entries) → **legacy**.
    - `supported` ∩ client's modern versions is non-empty → **modern ("corrective")**: continue with the mutual version.
    - `supported` has modern versions but none in common → **hard error**, no fallback.
    - `supported` has only legacy versions → **legacy** (fall back to `initialize`) if fallback is enabled, otherwise error.
  - A `200` result:
    - It does not validate as `DiscoverResult` → **legacy**.
    - It validates, and `supportedVersions` overlaps the client's modern versions → modern.
    - It validates, but there is no overlap → legacy if fallback is enabled, otherwise `UnsupportedProtocolVersionError`.
  - Network error → hard error, except an opaque `TypeError` in a browser (CORS) → legacy.
  - HTTP timeout or close → error. stdio timeout or close → **legacy**.
  - Default mode is `'legacy'` (no probe at all; `DEFAULT_VERSION_NEGOTIATION_MODE = "legacy"`). `'auto'` probes. `{pin}` allows no fallback.
  - On the SDK's own `StdioClientTransport` the probe runs on a **disposable sibling process**, because some L servers *exit* on any pre-`initialize` request. Subclasses and custom stdio-shaped transports probe in place.
  - The Inspector docs add that a probe "stalls against silent legacy stdio servers" (https://modelcontextprotocol.io/docs/2026-07-28/tools/inspector/protocol-eras.md), so a short, explicit probe timeout is required on stdio.

---

## 4. Transports

### 4.1 Streamable HTTP (M, 2026-07-28)

Source: https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http.md

**Endpoint and methods**
- There is a single MCP endpoint, for example `https://host/mcp`, and it takes **POST only**.
- When older clients send legacy traffic, a modern-only server **SHOULD** (not MUST) answer `GET` and `DELETE` with **405**, ignore `Mcp-Session-Id` and `Last-Event-ID`, and never mint or echo session ids. A dual-era server may instead serve both eras on the same endpoint.

**Every POST (client side):**
- **`Accept: application/json, text/event-stream`** (both are MUST).
- `Content-Type: application/json`.
- `MCP-Protocol-Version: 2026-07-28`. This MUST equal `_meta.io.modelcontextprotocol/protocolVersion`; otherwise `400`/`-32020`.
  - An unsupported version gets `400` + `-32022`.
  - Without the header, a server that still supports pre-2025-06-18 clients MAY treat the request as `2025-03-26`. Any other server MUST reject it (`400`/`-32020`).
- **`Mcp-Method: <method>`** on all requests (REQUIRED).
- **`Mcp-Name: <params.name | params.uri>`** on `tools/call`, `prompts/get` and `resources/read` (REQUIRED).
- **`Mcp-Param-{Name}: <value>`** for every `x-mcp-header`-annotated argument that is present (MUST; see below).
- `Authorization: Bearer <token>` on every request when the server uses auth (authorization/index.md). The token must never go in the query string.
- The body is exactly **one** JSON-RPC request or notification. The client **MUST NOT send JSON-RPC responses** (there are none in M).

**Server responses:**
- Notification POST → **`202 Accepted`**, no body. A rejection is a 4xx, optionally with an id-less JSON-RPC error.
- Request POST → `Content-Type: application/json` (a single object) **or** `text/event-stream` (a request-scoped SSE stream). The client MUST support both.
- **On an SSE response stream:**
  - The server MAY send notifications related to that request, such as `notifications/progress` and `notifications/message`.
  - It **MUST NOT send JSON-RPC requests**.
  - The final response SHOULD end the stream.
  - Servers SHOULD send `X-Accel-Buffering: no` and are encouraged to send SSE comment keep-alives (`:\r\n`). Clients **must ignore comment lines**.
- **No resumability.** `Last-Event-ID` is unsupported. If a stream breaks, re-issue the request with a **new id**.
- **Cancellation = close the SSE response stream** (or abort the HTTP request). The server MUST treat the disconnect as cancellation. No `notifications/cancelled` is sent on HTTP.
- The only client notification defined in M is `notifications/cancelled`, which is used **only on stdio**. Header rules for notification POSTs are not defined in this revision.

**Status code map for a client:**

| Status | Meaning (M) |
|---|---|
| 200 | JSON or SSE response |
| 202 | Notification accepted |
| 400 | `-32020` / `-32021` / `-32022` / `-32602` (missing `_meta`). An L server returns 400 with no modern body → fall back. |
| 401 / 403 | Auth (WWW-Authenticate, insufficient_scope step-up). Also 403 for an invalid `Origin`. |
| 404 | With a `-32601` body: unknown method (modern). Without a JSON-RPC body: possibly an L HTTP+SSE server, or the wrong URL. |
| 405 | A modern-only server rejecting GET/DELETE. On an initial POST, possible HTTP+SSE legacy. |

**`x-mcp-header`** (tools.md §x-mcp-header, streamable-http.md §Custom Headers). The client **MUST support** it on HTTP.

Validity rules. A tool violates them if its value:
- is empty;
- is not an RFC 9110 `tchar` token;
- contains CR, LF or other control characters;
- is not case-insensitively unique within the `inputSchema`;
- is on a non-primitive type (allowed: `integer`, `string`, `boolean`; **`number` is forbidden**; integers must be in ±(2^53−1));
- is not reachable from the root purely through a chain of `properties` keys (not via `items`, `oneOf`/`anyOf`/`allOf`/`not`, `if`/`then`/`else` or `$ref`).

If a tool violates any rule, the client **MUST drop that tool** from its `tools/list` view and SHOULD log a warning naming the tool and the reason. Other tools stay usable. On stdio, clients MAY ignore `x-mcp-header`.

Value encoding:
- string → as is; integer → decimal; boolean → `true`/`false`; `null` or absent → omit the header.
- A value that is non-ASCII, contains control characters, has leading or trailing whitespace, or itself matches `=?base64?…?=` must be sent as `=?base64?<base64(utf8)>?=`. The markers are lowercase and case-sensitive.
- The same encoding applies to **`Mcp-Name`**.
- Examples: `Mcp-Param-Greeting: =?base64?SGVsbG8sIOS4lueVjA==?=`; a literal `"=?base64?literal?="` becomes `=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?=`.

**Spec header table and complete encoding test vectors** (verbatim from streamable-http.md §Standard Request Headers and §Value Encoding; base64 values re-computed locally with `base64`, all match):

| Header | Source field | Required for |
|---|---|---|
| `MCP-Protocol-Version` | `params._meta["io.modelcontextprotocol/protocolVersion"]` | every POST |
| `Mcp-Method` | `method` | all requests |
| `Mcp-Name` | `params.name` or `params.uri` | `tools/call`, `resources/read`, `prompts/get` |
| `Mcp-Param-{x-mcp-header}` | argument at the annotated `properties` path | `tools/call`, when that value is present and not `null` |

| Original value | Reason | Encoded header |
|---|---|---|
| `"us-west1"` | plain ASCII | `Mcp-Param-Region: us-west1` |
| `"Hello, 世界"` | non-ASCII | `Mcp-Param-Greeting: =?base64?SGVsbG8sIOS4lueVjA==?=` |
| `" padded "` | leading/trailing space | `Mcp-Param-Text: =?base64?IHBhZGRlZCA=?=` |
| `"line1\nline2"` | control char | `Mcp-Param-Text: =?base64?bGluZTEKbGluZTI=?=` |
| `"=?base64?literal?="` | matches sentinel (starts `=?base64?`, ends `?=`) | `Mcp-Param-Val: =?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?=` |

- The encoding uses standard base64 with padding, applied to the UTF-8 bytes.
- `Mcp-Name` uses the same sentinel encoding. Resource URIs and tool names outside the header-safe set must be encoded.
- Nested object properties are allowed as `x-mcp-header` targets, as long as every step of the path is a `properties` key. Extraction reads the value at that exact path.
- Server-side integer comparison is numeric (`42.0` == `42`). Even so, the client should emit canonical decimal.

On a `-32020` header mismatch, the client SHOULD re-fetch `tools/list` and retry. Header names are case-insensitive; values (for example method names) are case-sensitive.

**Security (server side, but relevant for any localhost server Sherpa might host):** validate `Origin` and return 403 when it is invalid; bind to 127.0.0.1.

### 4.2 Streamable HTTP (L, 2025-03-26 through 2025-11-25)

Needed to talk to most deployed servers. Source: https://modelcontextprotocol.io/specification/2025-11-25/basic/transports.md

**Endpoint and POST**
- A single MCP endpoint that supports **POST and GET**.
- POST carries one request, notification **or response**. The client answers server-initiated requests by POSTing a JSON-RPC response, and the server replies `202`.
- POST `Accept` must list both `application/json` and `text/event-stream`. A request returns JSON or SSE.
- **The SSE stream on a POST** may carry server→client **requests** (sampling, elicitation, `roots/list`, `ping`) and notifications related to the originating request, before the final response.

**Priming and polling (2025-11-25)**
- The server SHOULD send an initial event that has an `id` and an empty `data`.
- After that it MAY close the *connection* without ending the *stream* (polling). It SHOULD send `retry: <ms>` before closing, and the client **MUST** honour `retry` before reconnecting.

**Disconnect and cancellation**
- A disconnect **SHOULD NOT** be read as cancellation.
- To cancel, POST a `notifications/cancelled` with `requestId`.

**GET listening stream**
- `GET` with `Accept: text/event-stream` opens a stream for server messages unrelated to any current request.
- The server answers with SSE or **405** (meaning no GET stream).
- The server MUST NOT send responses on it, except when resuming.
- TS SDK v1 servers allow only **one** GET stream per session (`409 Conflict`, `server/webStandardStreamableHttp.js` L251).
- The server MUST NOT broadcast one message across several streams.

**Resumability**
- SSE `id`s are unique per session, and SHOULD encode stream identity.
- Resume with **GET** plus `Last-Event-ID: <last id>`, whatever the original stream was (POST or GET). The server replays only that stream.

**Sessions**
- The server MAY return `Mcp-Session-Id` (visible ASCII 0x21-0x7E) on the HTTP response carrying `InitializeResult`. The client **MUST** echo it on every later request, including GET and DELETE.
- A missing session id may get `400`.
- **`404` on a request that carried a session id means the session expired. The client MUST start over with a new `initialize` and no session header.**
- The client SHOULD send `DELETE` with `Mcp-Session-Id` when done. The server MAY answer `405`; treat that as OK.

**Protocol version header and Accept**
- `MCP-Protocol-Version: <negotiated>` on all requests after `initialize` (2025-06-18+).
- A server that sees no header assumes `2025-03-26`, and returns `400` for an invalid or unsupported value.
- TS SDK v1 servers return `406` if `Accept` lacks either type, and `415` if `Content-Type` is not JSON.

**TS SDK v1 client behaviour (reference)**
- Reconnection backoff defaults: `{initialReconnectionDelay:1000, maxReconnectionDelay:30000, reconnectionDelayGrowFactor:1.5, maxRetries:2}`.
- It opens the GET stream after a `202` to `notifications/initialized`.
- `terminateSession()` sends DELETE and tolerates `405`.
- It does **not** auto-reinitialize on `404`; it throws `StreamableHTTPError(404)`.

Source: `/opt/vendor-src/npm/modelcontextprotocol-sdk-1.32.1/package/dist/esm/client/streamableHttp.js` L6-12, L300-470.

### 4.3 L lifecycle (`initialize`) for the fallback path

Source: https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle.md, `schema/2025-11-25/schema.ts`

```json
→ {"jsonrpc":"2.0","id":1,"method":"initialize","params":{
    "protocolVersion":"2025-11-25",
    "capabilities":{"roots":{"listChanged":true},"sampling":{"tools":{}},
                    "elicitation":{"form":{},"url":{}},
                    "tasks":{"requests":{"elicitation":{"create":{}},"sampling":{"createMessage":{}}}}},
    "clientInfo":{"name":"Sherpa","title":"Sherpa","version":"1.0.0"}}}
← {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25",
    "capabilities":{"logging":{},"prompts":{"listChanged":true},
      "resources":{"subscribe":true,"listChanged":true},"tools":{"listChanged":true},
      "tasks":{"list":{},"cancel":{},"requests":{"tools":{"call":{}}}}},
    "serverInfo":{"name":"…","version":"…"},"instructions":"…"}}
→ {"jsonrpc":"2.0","method":"notifications/initialized"}
```

- Send your **latest** supported L version. The server echoes it or counter-offers. If you do not support the counter-offer, disconnect.
- Before `initialize` completes, send nothing except `ping`.
- The client MUST NOT cancel `initialize`.
- L capabilities:
  - Client: `roots.listChanged`, `sampling{context?,tools?}`, `elicitation{form?,url?}`, `tasks{list?,cancel?,requests{sampling.createMessage, elicitation.create}}`, `experimental`.
  - Server: `logging`, `completions`, `prompts.listChanged`, `resources{subscribe,listChanged}`, `tools.listChanged`, `tasks{list,cancel,requests.tools.call}`, `experimental`.
- L-only methods to implement in the fallback path:
  - `ping` (both directions; answer `{}` promptly).
  - `logging/setLevel {level}`.
  - `resources/subscribe {uri}` and `resources/unsubscribe {uri}`.
  - `notifications/roots/list_changed`.
  - `notifications/elicitation/complete {elicitationId}`.
  - Tasks: `tasks/get`, `tasks/result` (blocking), `tasks/list`, `tasks/cancel`, `notifications/tasks/status`.
  - The `task` param (`{ttl?}`) on requests, and the `_meta["io.modelcontextprotocol/related-task"] = {taskId}` key.
- L shape differences:
  - `outputSchema` root must be `type:"object"`, and `structuredContent` is an object.
  - `Tool.execution.taskSupport` is `"forbidden"` (the default), `"optional"` or `"required"`. With `"required"` the client MUST call the tool as a task.
  - `CancelledNotificationParams.requestId` is optional because of tasks.
  - `URLElicitationRequiredError` is `-32042`.
  - Results have no `resultType` and no `ttlMs`.

### 4.4 HTTP+SSE (2024-11-05; Deprecated)

Source: https://modelcontextprotocol.io/specification/2024-11-05/basic/transports.md and the 2026-07-28 streamable-http §HTTP+SSE

How it works:
- Two endpoints. `GET <sseUrl>` opens SSE, and the **first event is `event: endpoint`** whose data is the URI to POST to.
- Server messages arrive as `event: message` with JSON data.

Client fallback (M wording):
1. POST to the user-supplied URL.
2. If it fails with **400, 404 or 405 *and* the body is not a recognized modern JSON-RPC error**, issue `GET` to the same URL.
3. If an `endpoint` event arrives, switch to HTTP+SSE.

### 4.5 stdio

Source: https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio.md

**Framing and streams**
- Newline-delimited JSON-RPC, one message per line, with **no embedded newlines**.
- The server writes only MCP messages to stdout. stderr is free-form logs and is **not** an error signal.
- The client writes only MCP messages to stdin.
- M: the server never writes requests. A single channel carries responses, notifications about in-flight requests, and `subscriptions/listen` notifications, which you demultiplex by `_meta["io.modelcontextprotocol/subscriptionId"]`.

**Cancellation**
- The client **MUST** send `notifications/cancelled {requestId, reason?}`.
- The server sends `notifications/cancelled` **only** to end a `subscriptions/listen` stream.

**Shutdown and restart**
- Close stdin, wait, then SIGTERM, then SIGKILL (on Windows, TerminateProcess or Job Objects). The server SHOULD exit on stdin EOF.
- After an unexpected exit, restart the server, retry the lost requests, and **re-issue `subscriptions/listen`**.
- M statelessness: a connection is **not** a session. Clients SHOULD NOT tie the stdio process lifetime to one conversation.
- The same framing is RECOMMENDED for custom byte-stream transports (UDS, TCP).

**Mobile reality (Sherpa)**
- **iOS:** App Store Guideline 2.5.2 forbids downloading or executing code that changes app functionality (https://developer.apple.com/app-store/review/guidelines/). In practice there is no subprocess stdio server on iOS (spawning subprocesses at all on iOS is **UNVERIFIED** as an API question).
- **Android 10+ (targetSdk 29+):** "Untrusted apps … cannot invoke `execve()` directly on files within the app's home directory" (https://developer.android.com/about/versions/10/behavior-changes-10). Only binaries packaged in the APK (for example under `nativeLibraryDir`) can be exec'd.
- So **stdio is effectively in-process** for Sherpa. Reuse the stdio framing over an in-process pipe or isolate for built-in servers, and use Streamable HTTP for everything remote.

---

## 5. Message patterns (M)

### 5.1 Multi Round-Trip Requests (MRTR): replaces server→client requests

Source: https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/mrtr.md, `schema.ts` (`InputRequests`, `InputResponses`, `InputRequiredResult`, `InputResponseRequestParams`)

- **Allowed only on `tools/call`, `prompts/get` and `resources/read`.** Servers MUST NOT return `InputRequiredResult` on any other request.
- Interim result (HTTP 200, a normal result):

```json
{"jsonrpc":"2.0","id":1,"result":{"resultType":"input_required",
  "inputRequests":{
    "github_login":{"method":"elicitation/create","params":{"mode":"form",
       "message":"Please provide your GitHub username",
       "requestedSchema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}}},
    "capital_of_france":{"method":"sampling/createMessage","params":{
       "messages":[{"role":"user","content":{"type":"text","text":"What is the capital of France?"}}],
       "maxTokens":100}}},
  "requestState":"<opaque>"}}
```

- `InputRequest` = `CreateMessageRequest | ListRootsRequest | ElicitRequest`. These are **de-JSON-RPC'd**: just `{method, params}`, with no `jsonrpc`, no `id` and no `_meta` requirement.
- At least one of `inputRequests` and `requestState` is present.
- `requestState` alone means "retry now", for example under load shedding: `{"resultType":"input_required","requestState":"eyJ…"}`.
- **Retry** with a *new* JSON-RPC id, the original params, plus:

```json
"inputResponses":{"github_login":{"action":"accept","content":{"name":"octocat"}},
                  "capital_of_france":{"role":"assistant","content":{"type":"text","text":"Paris."},
                                       "model":"…","stopReason":"endTurn"}},
"requestState":"<echo exactly>"
```

  `InputResponse` values are **bare** `ElicitResult`, `CreateMessageResult` or `ListRootsResult` objects (no `resultType`).

Client MUSTs:
- Fulfil every `inputRequests` key before retrying.
- Echo `requestState` byte-exact. Never parse it. Omit it if it was absent.
- Use a different id on the retry.
- Use `inputResponses` and `requestState` only for that retry, never for parallel requests.
- Results of retries that carry `inputResponses` or `requestState` **MUST NOT be cached**.

Other behaviour:
- The server may answer a retry with another `InputRequiredResult` (repeat until satisfied), and SHOULD re-ask for missing inputs rather than error.
- Servers MUST NOT include input requests whose capability the client did not declare in that request's `clientCapabilities`.
- If the user declines a sampling or roots request, the client simply does not retry ("the server is not waiting").

### 5.2 `subscriptions/listen`: replaces the GET stream and `resources/subscribe`

Source: https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/subscriptions.md

```json
→ {"jsonrpc":"2.0","id":1,"method":"subscriptions/listen","params":{"_meta":{…required…},
    "notifications":{"toolsListChanged":true,"promptsListChanged":true,
                     "resourcesListChanged":true,"resourceSubscriptions":["file:///project/config.json"]}}}
← (SSE) {"jsonrpc":"2.0","method":"notifications/subscriptions/acknowledged",
          "params":{"_meta":{"io.modelcontextprotocol/subscriptionId":1},
                    "notifications":{"toolsListChanged":true,"resourceSubscriptions":["file:///project/config.json"]}}}
← (SSE) {"jsonrpc":"2.0","method":"notifications/tools/list_changed","params":{"_meta":{"io.modelcontextprotocol/subscriptionId":1}}}
← (SSE) {"jsonrpc":"2.0","method":"notifications/resources/updated","params":{"_meta":{"io.modelcontextprotocol/subscriptionId":1},"uri":"file:///project/config.json"}}
```

- All filter fields are optional. The server MUST NOT send unrequested types.
- The **ack is the first message carrying that subscriptionId**. It echoes only the subset the server honours, so the client SHOULD diff it against what was requested.
- `subscriptionId` equals the listen request's JSON-RPC id.
- Multiple concurrent listens are allowed.
- Progress and log notifications **never** go on the listen stream.

How it ends:
- **Client:** closes the SSE stream (HTTP), or sends `notifications/cancelled` with the listen id (stdio).
- **Server, gracefully:** SHOULD send a final response `{"resultType":"complete","_meta":{"io.modelcontextprotocol/subscriptionId":1}}`.
- **Transport drop:** no response. The client MAY reconnect. On stdio it MUST re-send listen after a reconnect.
- **Spec inconsistency:** cancellation.md says the server "MUST send `notifications/cancelled`" to tear down a listen, while subscriptions.md describes a graceful *response*. Handle both as end of stream.

Filter fields by capability. This is **an inference, not spec text**: subscriptions.md only says that unsupported types are left out of the ack. The capability descriptions in server/tools.md, prompts.md and resources.md tie list-changed notifications to `listChanged` and per-resource updates to `subscribe`.
- `toolsListChanged`, `promptsListChanged` and `resourcesListChanged` are meaningful only if the server capability has `listChanged:true`.
- `resourceSubscriptions` presumably needs `resources.subscribe:true`.
- In every case, trust the **ack**, not the capability.

### 5.3 Cancellation, timeouts, progress

Sources: patterns/cancellation.md, patterns/progress.md

**Cancellation**
- `notifications/cancelled {requestId: RequestId, reason?: string}`. It may only reference requests that are believed to still be in flight.
- Ignore late responses to a cancelled request, and ignore invalid cancels.
- **Timeouts:** SHOULD apply to all requests and be configurable per request. MAY reset on progress, but enforce a hard maximum. A timeout means cancel via the transport mechanism.

**Progress**
- Request `_meta.progressToken` (string or int, unique across active requests).
- `notifications/progress {progressToken, progress:number, total?:number, message?:string}`. `progress` MUST increase; floats are allowed.
- Only for in-flight requests. Rate-limit it.

**Removed in M:** `ping`. Use transport health and timeouts instead. L servers may still send `ping` to the client, so answer it.

---

## 6. Server primitives (client view)

### 6.1 Capabilities (M)

Source: `schema.ts` `ServerCapabilities`, `ClientCapabilities`

```ts
ServerCapabilities { experimental?; logging?: {} /*deprecated*/; completions?: {};
  prompts?: {listChanged?: boolean}; resources?: {subscribe?: boolean; listChanged?: boolean};
  tools?: {listChanged?: boolean}; extensions?: {[id: string]: JSONObject} }
ClientCapabilities { experimental?; roots?: {} /*deprecated*/;
  sampling?: {context?: {} /*deprecated*/; tools?: {}} /*deprecated*/;
  elicitation?: {form?: {}; url?: {}}; extensions?: {[id: string]: JSONObject} }
```

- `elicitation: {}` means form-only.
- `roots` no longer has `listChanged`.
- Extension ids use the `_meta` key rules with a mandatory prefix.

### 6.2 Tools

Source: https://modelcontextprotocol.io/specification/2026-07-28/server/tools.md

- **`tools/list`** (`params.cursor?`) returns `{resultType, tools: Tool[], nextCursor?, ttlMs, cacheScope}`.
  - The list MUST NOT vary per connection, but MAY vary by authorization.
  - Order SHOULD be deterministic.
- **`Tool`**:

```ts
{ name; title?; description?; icons?;
  inputSchema: {$schema?; type:"object"; …any 2020-12 keywords…};  // MUST be object root, never null
  outputSchema?: {$schema?; …any 2020-12…};                        // root may be non-object in M
  annotations?: ToolAnnotations; _meta? }
```

  - No-arg tools: use `{"type":"object","additionalProperties":false}` (recommended) or `{"type":"object"}`.
  - Display name precedence: `title`, then `annotations.title`, then `name`.
- **Names:** SHOULD be 1-128 characters, case-sensitive, from `[A-Za-z0-9_.-]`, and unique per server.
  - Aggregating hosts SHOULD disambiguate collisions, for example with a server prefix.
  - `serverInfo.name` is **not** unique and must not be used for that.
  - Remember to map back to the original names on the wire.
- **`ToolAnnotations`**, all hints and **untrusted unless the server is trusted**:

| Field | Default | Note |
|---|---|---|
| `title` | — | |
| `readOnlyHint` | false | |
| `destructiveHint` | **true** | Meaningful only when `readOnlyHint == false` |
| `idempotentHint` | false | Meaningful only when `readOnlyHint == false` |
| `openWorldHint` | **true** | |

- **`tools/call`** params: `{name, arguments?: object, inputResponses?, requestState?, _meta}`. The result is `CallToolResult | InputRequiredResult`.
- **`CallToolResult`**: `{resultType:"complete", content: ContentBlock[], structuredContent?: <any JSON>, isError?: boolean (default false), _meta?}`.
  - If `outputSchema` exists, the server MUST conform and clients SHOULD validate.
  - For backward compatibility the server SHOULD also serialize `structuredContent` into a `TextContent` block.
  - TS SDK v1 throws if a tool with `outputSchema` returns no `structuredContent` and is not an error (`client/index.js` ~L485-500). That is SDK policy, not spec.
- **Errors:** an unknown tool or malformed request is a JSON-RPC `-32602`. API, validation and business failures are `isError: true` with readable content, and SHOULD be fed back to the model for self-correction.
- **`ContentBlock`** = `TextContent | ImageContent | AudioContent | ResourceLink | EmbeddedResource`:

```json
{"type":"text","text":"…","annotations"?:{…},"_meta"?:{…}}
{"type":"image","data":"<base64>","mimeType":"image/png","annotations"?:{…}}
{"type":"audio","data":"<base64>","mimeType":"audio/wav"}
{"type":"resource_link","uri":"file:///…","name":"main.rs","title"?:"…","description"?:"…","mimeType"?:"…","size"?:123,"icons"?:[…],"annotations"?:{…}}
{"type":"resource","resource":{"uri":"…","mimeType"?:"…","text":"…"} | {"uri":"…","blob":"<base64>"},"annotations"?:{…}}
```

  Resource links returned by tools need not appear in `resources/list`.

- **`Annotations`**: `{audience?: ("user"|"assistant")[], priority?: 0..1, lastModified?: ISO-8601}`. Use them to route content to the UI or the model, and for context-budget priority.
- **Stateful tools (non-normative):** servers return explicit handles (for example `basket_id`) in `structuredContent`, and the model carries them forward. Expired handles return `isError`.
- **Client SHOULDs:**
  - Confirm sensitive operations with the user.
  - **Show tool inputs before sending them.**
  - Validate results before handing them to the LLM.
  - Use timeouts.
  - Keep an audit log.
  - Keep a human in the loop who can deny invocations.
- **Change notifications:** `notifications/tools/list_changed` arrives via `subscriptions/listen` (M) or unsolicited after `initialize` (L, if `tools.listChanged`).

### 6.3 Resources

Source: https://modelcontextprotocol.io/specification/2026-07-28/server/resources.md

- `resources/list` (`cursor?`) returns `{resources: Resource[], nextCursor?, ttlMs, cacheScope}`. `Resource = {uri, name, title?, description?, mimeType?, size?, icons?, annotations?, _meta?}`.
- `resources/templates/list` returns `{resourceTemplates: [{uriTemplate /*RFC 6570*/, name, title?, description?, mimeType?, icons?, annotations?}], nextCursor?, ttlMs, cacheScope}`.
- `resources/read {uri}` returns `{contents: (TextResourceContents{uri,mimeType?,text} | BlobResourceContents{uri,mimeType?,blob})[], ttlMs, cacheScope}` **or an `InputRequiredResult`**.
  - It may return several contents, for example for a directory.
  - An `https://` URI means the client MAY fetch the resource directly from the web.
- **Not found:** M uses `-32602` with `data.uri`. Also accept `-32002` from L servers. An empty `contents` array MUST NOT mean "not found".
- **Subscriptions:**
  - M: `subscriptions/listen` with `resourceSubscriptions:[uri…]` delivers `notifications/resources/updated {uri}`. The uri may be a sub-resource.
  - L: `resources/subscribe {uri}` / `resources/unsubscribe {uri}`.
- `notifications/resources/list_changed`.
- **URI schemes:** `https://` (only if the client can fetch it itself), `file://` (may be virtual; `inode/directory` for directories), `git://`, and custom schemes (RFC 3986).

### 6.4 Prompts

Source: https://modelcontextprotocol.io/specification/2026-07-28/server/prompts.md

- Prompts are user-controlled (for example slash commands).
- `prompts/list` returns `{prompts: [{name, title?, description?, icons?, arguments?: [{name, title?, description?, required?}], _meta?}], nextCursor?, ttlMs, cacheScope}`.
- `prompts/get {name, arguments?: {[k]: string}}` returns `{description?, messages: [{role:"user"|"assistant", content: ContentBlock}]}` **or `InputRequiredResult`**. Note that each message has a *single* content block.
- Errors: an unknown prompt or missing required arguments is `-32602`.
- `notifications/prompts/list_changed`.

### 6.5 Completion

Source: server/utilities/completion.md

- Capability: `completions: {}`.
- `completion/complete {ref: {type:"ref/prompt", name} | {type:"ref/resource", uri}, argument: {name, value}, context?: {arguments?: {[k]: string}}}` returns `{completion: {values: string[] /*≤100*/, total?, hasMore?}}`.
- Clients SHOULD debounce. There is no MRTR or caching for this method.

### 6.6 Logging (Deprecated in M)

Source: server/utilities/logging.md

- M: the request `_meta["io.modelcontextprotocol/logLevel"]` is one of `debug | info | notice | warning | error | critical | alert | emergency`.
  - Without it, the server **MUST NOT** emit `notifications/message` for that request.
  - Messages arrive on that request's stream only.
- `notifications/message {level, logger?, data: any}`.
- L uses `logging/setLevel {level}` per session instead.
- Do not show log `data` to the model; it is untrusted.

### 6.7 Pagination

Source: server/utilities/pagination.md

- Applies to `tools/list`, `prompts/list`, `resources/list` and `resources/templates/list` (and L `tasks/list`).
- `nextCursor` is opaque. **An empty string is a valid cursor**; only an absent cursor means the end.
- Page size is server-chosen.
- An invalid cursor gives `-32602`; then discard cached pages and restart.

### 6.8 Caching (M)

Source: server/utilities/caching.md

- `ttlMs` (integer ms, >= 0):
  - Fresh while `now < t_received + ttlMs`.
  - `0` means immediately stale. Treat absent (L servers) or negative values as `0`.
  - **Not** a polling interval. Anyone who does poll MUST use jitter and backoff.
- `cacheScope`:
  - `"public"` may be shared across users.
  - `"private"` is cached **per authorization context**; a different token needs a different cache.
- Cache key = method + result-affecting params (`uri`, `cursor`).
- **Never** cache MRTR retries or `input_required` results.
- A list-changed notification invalidates the cache immediately.
- Each page has its own TTL, but all pages share one scope.
- Clients MAY serve stale data on re-fetch error, and MAY re-fetch early on `-32601`/`-32602` from a call.

---

## 7. Client features

### 7.1 Elicitation (Active; the only non-deprecated client feature)

Source: https://modelcontextprotocol.io/specification/2026-07-28/client/elicitation.md, `schema.ts`

- **Capability:** `elicitation: {form?: {}, url?: {}}`. An empty object means form only. If declared, at least one mode must be supported. Servers MUST NOT use undeclared modes; in L the client answers such a request with `-32602`.
- **Form mode:** `{mode?: "form", message, requestedSchema: {$schema?, type:"object", properties: {[k]: PrimitiveSchemaDefinition}, required?: string[]}}`. The schema is **flat**: no nesting and no arrays of objects. Allowed property schemas:
  - `StringSchema {type:"string", title?, description?, minLength?, maxLength?, format?: "email"|"uri"|"date"|"date-time", default?}`
  - `NumberSchema {type:"number"|"integer", title?, description?, minimum?, maximum?, default?}`
  - `BooleanSchema {type:"boolean", title?, description?, default?}`
  - Enums:
    - untitled single `{type:"string", enum:[…], default?}`
    - titled single `{type:"string", oneOf:[{const,title}], default?}`
    - untitled multi `{type:"array", minItems?, maxItems?, items:{type:"string", enum:[…]}, default?: string[]}`
    - titled multi `{type:"array", items:{anyOf:[{const,title}]}, …}`
    - `LegacyTitledEnumSchema {type:"string", enum, enumNames?}` (deprecated, but accept it)
  - Clients that support defaults SHOULD pre-fill them.
- **URL mode (M):** `{mode:"url", message, url}`. `elicitationId` was **removed** in M (it is present in L), and the outcome is learned by retrying the original request.
- **Result:** `ElicitResult {action: "accept"|"decline"|"cancel", content?: {[k]: string|number|boolean|string[]}}`.
  - `content` only on accept in form mode.
  - URL accept means "user consented to open the URL", not that the interaction is done.
  - Clients SHOULD offer manual retry and cancel controls.
- **Client MUSTs:**
  - Show which server is asking.
  - Offer decline and cancel.
  - Form mode: let the user review and edit the answer before sending.
  - URL mode: show the full URL and the domain, and get consent first.
  - **Never prefetch** the URL or its metadata.
  - Open it in a way the app or LLM cannot inspect. The spec says SFSafariViewController is OK and WKWebView is not. The Android analogue is Custom Tabs, which is my inference and **UNVERIFIED** in spec text.
  - SHOULD highlight the domain, warn on punycode, and not linkify URLs in form fields.
- **Servers MUST NOT** request secrets via form mode (passwords, API keys, tokens, payment details). Those must go through URL mode.
- **L specifics (2025-11-25):**
  - Delivered as a server→client JSON-RPC request `elicitation/create` (form or URL with `elicitationId`).
  - Optional `notifications/elicitation/complete {elicitationId}`.
  - The server may return error `-32042` with `data.elicitations[]` (URL mode only). The client presents those elicitations and then retries.

### 7.2 Sampling (Deprecated in M; functional until at least 2027-07-28)

Source: https://modelcontextprotocol.io/specification/2026-07-28/client/sampling.md

**Capability and request**
- Capability: `sampling: {}`, plus `tools: {}` for tool use, plus (deprecated) `context: {}`.
- The request is delivered via MRTR (M) or as a server→client request (L):

```ts
CreateMessageRequestParams { messages: SamplingMessage[]; modelPreferences?: ModelPreferences;
  systemPrompt?: string; includeContext?: "none"|"thisServer"|"allServers" /*default none; last two deprecated*/;
  temperature?: number; maxTokens: number /*REQUIRED; client MUST respect*/; stopSequences?: string[];
  metadata?: JSONObject; tools?: Tool[]; toolChoice?: {mode?: "auto"|"required"|"none"} }
SamplingMessage { role: "user"|"assistant"; content: Block | Block[]; _meta? }
  Block = TextContent | ImageContent | AudioContent | ToolUseContent | ToolResultContent
ToolUseContent { type:"tool_use"; id; name; input: object; _meta? }
ToolResultContent { type:"tool_result"; toolUseId; content: ContentBlock[]; structuredContent?; isError?; _meta? }
CreateMessageResult extends SamplingMessage { model: string; stopReason?: "endTurn"|"stopSequence"|"maxTokens"|"toolUse"|string }
ModelPreferences { hints?: {name?: string}[] /*ordered substring hints*/; costPriority?; speedPriority?; intelligencePriority? /*0..1*/ }
```

**Tools in sampling**
- The client **MUST error** if `tools` or `toolChoice` is sent without `sampling.tools` declared. This rule comes from schema.ts `CreateMessageRequestParams.tools`/`toolChoice` doc comments, and sampling.md also says "Servers **MUST NOT** send tool-enabled sampling requests" to such clients.
  - In M there is no per-input error channel: an `InputResponse` must be a `CreateMessageResult`.
  - So "erroring" in M means: do **not** retry, and surface a protocol-violation error locally. sampling.md §Error Handling: "the client does not need to replay the initial call with an error message, as the server is not waiting."
  - In L, answer the server's JSON-RPC request with an error (e.g. `-32602`).
- A user message containing `tool_result` must contain **only** tool results.
- Every assistant `tool_use` must be matched by a `tool_result` in the next user message.
- Iteration limits are SHOULD.
- Preserve `_meta` on tool_use and tool_result blocks for caching.

**Client behaviour**
- The client MAY ignore or alter `systemPrompt`, `temperature`, `stopSequences`, `metadata` and `includeContext`.
- Hints are advisory and may be mapped across providers.
- The human-in-the-loop SHOULDs: review and edit the prompt before sending, and review the response before returning it.

### 7.3 Roots (Deprecated in M)

- Capability `roots: {}`.
- MRTR input `{"method":"roots/list"}` returns `{roots: [{uri:"file:///…", name?, _meta?}]}`. The `uri` MUST be `file://`.
- L adds `roots.listChanged` and `notifications/roots/list_changed`.
- On mobile, prefer not to declare roots; pass paths through tool args or config.

---

## 8. Tasks

**M: extension `io.modelcontextprotocol/tasks`.** Source: https://modelcontextprotocol.io/extensions/tasks/overview.md, https://raw.githubusercontent.com/modelcontextprotocol/ext-tasks/main/schema/2026-07-28/schema.ts

Opt-in and task creation:
- The client sends `clientCapabilities.extensions["io.modelcontextprotocol/tasks"] = {}` on each request, and the server advertises the same in `server/discover`.
- The server decides per request whether to create a task. There is no per-request or per-tool opt-in.
- **`CreateTaskResult`** = `Result & Task & {resultType:"task"}`:

```ts
Task { taskId: string; status: "working"|"input_required"|"completed"|"failed"|"cancelled";
  statusMessage?: string; createdAt: ISO; lastUpdatedAt: ISO; ttlMs: number|null; pollIntervalMs?: number }
```

Methods:
- `tasks/get {taskId}` returns `Result & DetailedTask & {resultType:"complete"}`. The detailed variants are:
  - `input_required` adds `inputRequests: InputRequests`;
  - `completed` adds `result: {…original result…}`;
  - `failed` adds `error: {code, message, data?}`.
- `tasks/update {taskId, inputResponses}` returns an empty ack (`resultType:"complete"`).
- `tasks/cancel {taskId}` returns an empty ack. Cancellation is cooperative and eventually consistent.
- `notifications/tasks` (full `DetailedTask`) arrives via `subscriptions/listen` with a `taskIds: string[]` filter (acked as `taskIds`).

Rules:
- Terminal states (`completed`, `failed`, `cancelled`) never change.
- Clients SHOULD honour `pollIntervalMs` and **persist task IDs durably** so they can resume after a restart, which is a good fit for mobile.
- `tasks/list` and `tasks/result` do not exist in M.

**L (2025-11-25, experimental core)**:
- Capabilities live under `tasks` (§4.3). The requestor opts in per request with `params.task = {ttl?}`. `Tool.execution.taskSupport` gates the opt-in.
- `CreateTaskResult = {task: Task}` with `ttl`/`pollInterval` (no `Ms` suffix).
- `tasks/result` **blocks** until the task is terminal and returns exactly what the original request would have.
- Related messages carry `_meta["io.modelcontextprotocol/related-task"] = {taskId}`.
- `notifications/tasks/status`. `tasks/cancel` on a terminal task gives `-32602`.
- Source: https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/tasks.md

---

## 9. Extensions relevant to Sherpa

Source: https://modelcontextprotocol.io/extensions/overview.md, https://modelcontextprotocol.io/extensions/client-matrix.md

- Ids follow `{vendor-prefix}/{name}`. Official ids use `io.modelcontextprotocol/`. Extensions are disabled by default.
- If only one side supports an extension, the supporting side MUST revert to core behaviour or reject. Breaking changes get a new id (for example `…-v2`).
- **MCP Apps:** `io.modelcontextprotocol/ui`. The client declares `{"mimeTypes":["text/html;profile=mcp-app"]}`. Example: `schema/2026-07-28/examples/ClientCapabilities/extensions-ui-mime-types.json`. Details belong to a separate digest (ext-apps 2.0.3 is vendored at `/opt/vendor-src/npm/modelcontextprotocol-ext-apps-2.0.3/package`).
- Others:
  - `io.modelcontextprotocol/tasks`
  - `io.modelcontextprotocol/skills` (Skills over MCP)
  - `io.modelcontextprotocol/oauth-client-credentials`
  - `io.modelcontextprotocol/enterprise-managed-authorization`

---

## 10. Authorization deltas (pointer only; a separate OAuth digest should own this)

Source: https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/index.md

- Applies to HTTP only. stdio takes credentials from the environment.
- **Server-side requirements:** OAuth 2.1; Protected Resource Metadata (RFC 9728), which clients MUST use for AS discovery; AS metadata via RFC 8414 **or** OIDC Discovery, and clients MUST support both.
- **Client-side requirements:**
  - The RFC 8707 `resource` parameter in both the authorize and token requests, set to the canonical server URI.
  - A token on every HTTP request.
  - `iss` validation per RFC 9207 against the recorded issuer, with no URL normalisation.
  - Client credentials keyed by issuer.
  - DCR (deprecated) must send `application_type`.
  - CIMD (Client ID Metadata Documents) is the preferred registration method.
- Scope step-up uses `WWW-Authenticate` with `insufficient_scope`.

---

## 11. Dual-era client algorithm (synthesized from the sections above)

```
connect(serverConfig):
  verdict = cache.get(origin|processKey)          # §3.1
  if transport == http:
     resp = POST server/discover (MCP-Protocol-Version + Mcp-Method headers + _meta, Accept both)
       401/403 → run OAuth (PRM/AS discovery) → re-probe        # not an era verdict
       200 + valid DiscoverResult:
            supportedVersions ∩ ourModern ≠ ∅ → MODERN(version, caps, instructions, ttlMs/cacheScope)
            no overlap                        → LEGACY path (or error if we are modern-only)
       200 + body not a valid DiscoverResult → LEGACY path
       any status + JSON-RPC error body:      # key on error.code ONLY, never on message text
            -32022, data.supported ∩ ourModern ≠ ∅ → MODERN(corrective: switch version, continue)
            -32022, supported has modern but none mutual → hard error (no fallback)
            -32022, supported only legacy (e.g. ["2025-11-25"]) or unusable → LEGACY path
            anything else (-32000, -32001, -32601, -32602, -32020, -32021, …) → LEGACY path
       4xx (not 401/403) with empty / non-JSON-RPC body → LEGACY path
       5xx / network / HTTP timeout → error (retry w/ backoff), no verdict
     LEGACY path: POST initialize (protocolVersion "2025-11-25"; accept counter-offer 2025-06-18 / 2025-03-26)
            initialize 200 (+Mcp-Session-Id?) → LEGACY_STREAMABLE
            initialize 400/404/405 w/o modern body → GET url, expect first SSE event `endpoint` → LEGACY_HTTP_SSE
  if transport == in-process stdio-framed:
     send server/discover with short timeout T
       DiscoverResult → MODERN; -32022 → rules above
       any other error, timeout, or channel close → initialize   # MUST NOT key fallback to one code
  cache verdict per origin (HTTP) / process (stdio); on later failure that contradicts it → re-probe once
```

Sources:
- Spec: streamable-http.md §Backward Compatibility, stdio.md §Backward Compatibility, versioning.md §Compatibility Matrix.
- TS v2 `classifyProbeOutcome` (§3.3), which covers the `200`-with-error and `-32022`-legacy-only rows the spec prose leaves implicit.

Per-era adapters behind one internal interface:

| Concern | MODERN adapter | LEGACY adapter |
|---|---|---|
| Server input requests | `InputRequiredResult` | server→client JSON-RPC requests on SSE |
| Change notifications | `subscriptions/listen` | GET stream / unsolicited notifications |
| Cancellation | close the stream (HTTP) / `notifications/cancelled` (stdio) | POST `notifications/cancelled` |
| Logging | per-request `logLevel` | `logging/setLevel` |
| Session headers | none | `Mcp-Session-Id`; 404 → re-initialize; DELETE on close |
| Resumability | re-issue the request | GET + `Last-Event-ID` |

Both adapters feed one host-side `InputRequestHandler`:
- `elicit(params, server)` → `ElicitResult`
- `sample(params, server)` → `CreateMessageResult`
- `listRoots()` → `ListRootsResult`

So UI, approval and consent logic is written once.

---

## Recommendations for Sherpa

1. **Implement dual-era from day one, and make `2026-07-28` the target.** Default to probing `server/discover` (equivalent to TS v2 `mode:'auto'` / mcp_dart's default). Fall back to `initialize` at `2025-11-25`, then down to `2025-06-18` and `2025-03-26` as counter-offered, and finally to HTTP+SSE.
   - Cache the era verdict per origin, and persist it next to the server config.
   - On HTTP, use `server/discover` (side-effect-free, era-unambiguous) as the first modern request rather than `tools/call`. The spec warns that some legacy servers execute era-ambiguous methods without `initialize`.
2. **Pick a Dart MCP core deliberately.**
   - `mcp_dart` 2.4.3 is the only Dart package verified here to default to 2026-07-28 with legacy fallback.
   - `dart_mcp` 0.5.2 is legacy-only.
   - `mcp_client` 3.0.0's 2026 support looks incomplete.
   - Either adopt `mcp_dart` behind an internal interface, or write a thin in-house pure-Dart client against `schema/2026-07-28/schema.json` and `2025-11-25/schema.json` (generated types). A hand-written client is tractable because M is just stateless POST + SSE.
   - Use the TS SDK v2 `probeClassifier` and `versionNegotiation` as the behavioural reference.
3. **One `InputRequestHandler` for elicitation, sampling and roots across both eras** (§11). MRTR retries must use new ids, echo `requestState` verbatim, never cache retries, and never share `inputResponses` across parallel calls.
4. **Elicitation UX on mobile:**
   - Form mode: render a native form from the flat-schema subset; support the five enum shapes plus `enumNames`; pre-fill defaults; offer explicit Decline and Cancel.
   - URL mode: show the full URL and highlighted domain, ask for consent, and open in **SFSafariViewController / ASWebAuthenticationSession (iOS)** or **Custom Tabs (Android)**, never a WebView. Never prefetch.
   - After the user accepts, re-issue the original request with the `ElicitResult` in `inputResponses` (M), or wait for `notifications/elicitation/complete` and retry (L).
5. **Sampling is deprecated but useful for on-device models.** If Sherpa supports it, declare `sampling:{tools:{}}` only when the tool loop is implemented, enforce `maxTokens`, keep human review, and route to the local or remote provider by `modelPreferences`. Do **not** declare `sampling.context`. **Do not declare `roots`** (deprecated; little value on mobile).
6. **Tool safety:**
   - Treat `ToolAnnotations` as untrusted.
   - Default approval policy keyed on `destructiveHint` (default true) and `openWorldHint` (default true), but verified by user choice rather than annotation.
   - Show arguments before a call.
   - Namespace tool names per server (`<serverSlug>__<tool>`) within LLM-safe character and length limits, and map back on the wire.
   - Drop tools whose `x-mcp-header` is invalid (MUST on HTTP), and log why.
7. **HTTP client details (Dart `HttpClient`/`package:http`):**
   - Stream responses (no buffering) and parse SSE incrementally. Ignore `:` comment lines; tolerate `id:`/`retry:` (L).
   - Set `Accept: application/json, text/event-stream` on every POST.
   - Implement `Mcp-Method`, `Mcp-Name` and `Mcp-Param-*` with the exact `=?base64?…?=` encoding (unit-test the spec's encoding table).
   - Per-request timeouts with a hard maximum; reset on progress.
   - Cancel by aborting the request (M), or by POSTing `notifications/cancelled` (L).
   - Dart `HttpClient.maxConnectionsPerHost` defaults to `null` (unlimited), so long-lived `subscriptions/listen` streams will not starve request connections. Even so, open **at most one** listen per server and only while the app is in the foreground (`/opt/flutter-sdk/flutter/bin/cache/dart-sdk/lib/_http/http.dart` L1311).
8. **Mobile lifecycle:** M statelessness fits app suspend and resume. On resume, re-issue `subscriptions/listen` and re-validate caches using `ttlMs`; in L, re-initialize after a `404`. If the Tasks extension is supported, persist task ids durably and poll `tasks/get` (honouring `pollIntervalMs`) after resume, instead of holding SSE in the background.
9. **Caching:** cache `tools/list`, prompts, resources and discover by `ttlMs`/`cacheScope`, keyed by server, auth context, method and params. Invalidate on list_changed. Treat `ttlMs` absent (L) as 0. Keep tool-list order stable for prompt-cache hits.
10. **Security hygiene:**
    - Icon fetching: https/data only, no credentials, same-origin, SVG sanitised or disallowed.
    - JSON Schema validator: no remote `$ref`, depth and subschema caps.
    - Treat all server-supplied text (descriptions, `instructions`, logs, tool output) as untrusted prompt-injection surface.
11. **Local/built-in servers:** iOS forbids subprocess servers in practice, and Android forbids exec of non-APK binaries. Ship built-in tools as in-process MCP servers using stdio framing over Dart streams or isolates, so they exercise the same protocol path. Remote servers use Streamable HTTP only.
12. **Conformance testing:** run against the TS SDK v2 server (2026-07-28), a TS SDK v1 server (2025-11-25 stateful *and* stateless modes), and a 2024-11-05 HTTP+SSE server. Test the 404-session-expiry, 405-GET, 406/415 and -32022 corrective paths.

## Risks

- **Ecosystem split.** 2026-07-28 is under 3 months old. The flagship TS SDK v1 (npm `latest` 1.32.1) is legacy-only, and v2's default negotiation mode is `'legacy'`, so most servers in the wild will be L for a long time. Shipping M-only would break most servers; shipping L-only goes stale. Dual-era roughly doubles the protocol surface and the test matrix.
- **Ambiguous era detection.** Legacy servers return arbitrary 400/404/405 bodies (TS v1 uses `-32000` and `-32001`), some process `tools/call` without `initialize`, and some stdio servers exit on a probe. A wrong verdict causes silent mis-execution or connection loops. A conservative classifier and verdict caching are essential.
- **Spec churn and inconsistencies.**
  - URL elicitation changed shape twice (introduced in 2025-11-25, `elicitationId` removed in 2026-07-28).
  - The spec says "design may change".
  - Cancellation vs subscriptions pages disagree on how a server ends a listen stream.
  - Deprecated sampling, roots, logging and DCR become **eligible for removal in the "first revision released on or after 2027-07-28"**. Actual removal is a Core Maintainer decision and "may happen later" (deprecated.md). Features built on them carry an expiry date.
- **Dart library maturity.** Only `mcp_dart` was verified to speak M by default. Its quality and spec fidelity are **UNVERIFIED** beyond constant inspection, and `mcp_client`'s M support appears incomplete despite its description.
- **Mobile networking.** Long-lived SSE breaks under backgrounding, network handoff and buffering proxies (servers SHOULD send `X-Accel-Buffering: no`). M has no resumability, so any interrupted long tool call is lost unless the server uses the Tasks extension. Non-idempotent tools re-issued after a drop risk duplicate side effects; never auto-retry when `destructiveHint`/`idempotentHint` is unknown.
- **Security surface.** `x-mcp-header` mirrors arguments into headers visible to intermediaries. Servers SHOULD NOT mark secrets this way, but Sherpa cannot enforce that. Malicious tool descriptions, icons (SVG) and schemas (DoS via composition, SSRF via `$ref`) are attack vectors. URL elicitation enables phishing if the URL is shown poorly.
- **Header-mismatch brittleness.** Clients MUST mirror `Mcp-Name` and `Mcp-Param-*` exactly, including integer formatting and base64 sentinel edge cases. Bugs surface as 400 `-32020` only against M servers.

## Open questions for the product owner

1. **Support floor:** should Sherpa support the deprecated **HTTP+SSE (2024-11-05)** transport at all, or only Streamable HTTP for 2025-03-26 and later plus 2026-07-28? Each extra era costs code and tests.
2. **Sampling:** expose the client LLM (local on-device or the user's remote provider) to MCP servers via sampling, even though it is deprecated and slated for removal in about 2027 or later? If yes, what is the default approval policy (always ask, or per-server allowlist), and which model serves sampling requests?
3. **Elicitation:** support **URL mode** (third-party OAuth and payments through external browser flows) in v1, or only form mode? URL mode needs careful consent UI.
4. **Tasks extension:** support `io.modelcontextprotocol/tasks` in v1, both M and L 2025-11-25 experimental? It is the only robust answer to long-running tools on mobile, but it is optional and the L and M shapes differ.
5. **Library strategy:** adopt `mcp_dart` (MIT licence, single maintainer "Jhin Lee", 51 releases since 2025-03-23; long-term maintenance **UNVERIFIED**), or own a minimal in-house Dart MCP client generated from the official JSON schemas?
6. **Background behaviour:** may Sherpa keep `subscriptions/listen` or L GET streams open while backgrounded (battery and OS limits), or only refresh list changes on foreground using TTL caches?
7. **Trust model:** should tool annotations from servers the user explicitly marks "trusted" be allowed to reduce approval prompts (for example auto-approve `readOnlyHint:true`)? The spec allows trusting annotations only from trusted servers.
8. **Built-in tools:** should Sherpa's own on-device tools be exposed as in-process MCP servers (uniform UX and approvals) or as native function tools outside MCP?
9. **Logging and telemetry:** surface server `notifications/message` logs in a developer panel (deprecated feature), and propagate OpenTelemetry `traceparent` in `_meta` to remote servers (a privacy consideration)?

---

## Verification log (independent)

Fact-checked 2026-10-18 by a second agent. I re-fetched every primary source fresh rather than reusing the first agent's copies.
- **Schemas:** `schema/2026-07-28/schema.ts`, `schema/draft/schema.ts` and `schema/2025-11-25/schema.ts` from `https://raw.githubusercontent.com/modelcontextprotocol/modelcontextprotocol/main/…`, plus official example JSON under `schema/2026-07-28/examples/`.
- **Spec pages:** every `https://modelcontextprotocol.io/specification/2026-07-28/**.md` page listed in `https://modelcontextprotocol.io/llms.txt`.
- **Tasks extension:** `ext-tasks` `schema/2026-07-28/schema.ts`.
- **Packages:** fresh registry tarballs of `@modelcontextprotocol/client` and `core@2.3.1` in `/opt/vendor-src/npm/verify-mcp-client-2.3.1/`, and pub.dev archives in `/opt/vendor-src/npm/verify-pub-dart-mcp/`.
- **Vendored SDK v1:** checked against the registry. Its tarball sha512 equals the registry `dist.integrity` (`sha512-2DdE+SJD…ichPkdw==`).
- No package code was executed.

Verdicts: **C** = confirmed, **X** = corrected in place above, **A** = critical fact added, **U** = unverifiable as stated.

| # | Claim | Verdict | Source and quote |
|---|---|---|---|
| 1 | Latest revision is `2026-07-28` | C | schema.ts L30: `export const LATEST_PROTOCOL_VERSION = "2026-07-28";`. `GET https://modelcontextprotocol.io/specification/latest` → `307` to `/specification/2026-07-28`. `diff` of draft vs 2026-07-28 `schema.ts`: only `/specification/draft/` vs `/specification/2026-07-28/` link lines differ. |
| 2 | No `initialize`; every request carries `_meta` `protocolVersion` + `clientCapabilities` (required) and `clientInfo` (SHOULD) | C | https://modelcontextprotocol.io/specification/2026-07-28/changelog.md: "Make MCP stateless: remove the `initialize`/`notifications/initialized` handshake. Every request now carries its protocol version and client capabilities in `_meta`". https://modelcontextprotocol.io/specification/2026-07-28/basic/index.md: "A request missing any required field is malformed; the server **MUST** reject it with JSON-RPC error code `-32602` (Invalid params). On HTTP, the response status **MUST** be `400 Bad Request`." |
| 3 | `Mcp-Session-Id` and protocol sessions removed | C | changelog.md Major 1: "Remove protocol-level sessions and the `Mcp-Session-Id` header from the Streamable HTTP transport." |
| 4 | `server/discover` MUST be implemented; `DiscoverResult` JSON and shape | C | https://modelcontextprotocol.io/specification/2026-07-28/server/discover.md: "Servers **MUST** implement it." The JSON in §3.1 matches the page's example except that `clientInfo` is renamed to Sherpa and the `instructions` text is elided. schema.ts: `interface DiscoverResult extends CacheableResult { supportedVersions: string[]; capabilities: ServerCapabilities; instructions?: string }`. |
| 5 | `resultType` is required; absent → `"complete"`; unknown → invalid | C | basic/index.md: "A `resultType` of any value unrecognized by the client **MUST** be considered invalid." and "clients **MUST** treat an absent `resultType` as `"complete"`." |
| 6 | MRTR: `InputRequiredResult {inputRequests?, requestState?}`, allowed only on `tools/call`, `prompts/get`, `resources/read` | C | https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/mrtr.md: "Servers **MUST NOT** send `InputRequiredResult` responses on any other client requests." schema.ts: "At least one of `inputRequests` or `requestState` MUST be present." Note: a schema.ts comment on `InputResponseRequestParams` says "may be included in any client-initiated request", but only the three Params types extend it. Follow the mrtr.md table. Official load-shedding example: `{"resultType":"input_required","requestState":"eyJwcm9ncmVzcyI6IjUwJSIsInN0YXRlIjoicHJvY2Vzc2luZyJ9"}`. The §5.1 interim-result JSON is abridged; the spec version also has `systemPrompt` and `modelPreferences`. |
| 7 | MRTR client MUSTs: new id, echo `requestState` exactly, never reuse for parallel requests, never cache retries | C | mrtr.md: "The JSON-RPC `id` **MUST** be different between the initial request and the retry"; "the client **MUST** echo back the exact value of that field"; "They **MUST NOT** be used for any other request that the client may be sending in parallel." https://modelcontextprotocol.io/specification/2026-07-28/server/utilities/caching.md: "requests carrying `inputResponses` or `requestState`—**MUST NOT** be cached". |
| 8 | `subscriptions/listen` replaces the GET stream and `resources/subscribe`; ack first; `subscriptionId` = listen request id | C | https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/subscriptions.md: "It replaces the former `resources/subscribe` RPC and the HTTP GET endpoint."; "The server **MUST** send `notifications/subscriptions/acknowledged` as the first message carrying the subscription's ID"; "The value is the JSON-RPC ID of the `subscriptions/listen` request." |
| 9 | Spec inconsistency on how a server ends a listen stream | C (still present) | https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/cancellation.md: "A server **MUST** send `notifications/cancelled` referencing a `subscriptions/listen` request ID when it tears down that subscription stream". subscriptions.md: "it **SHOULD** send a successful `subscriptions/listen` response to signal a graceful end". schema.ts `CancelledNotification` narrows the first rule to stdio: "On stdio, the server also sends this notification, solely to terminate a subscriptions/listen stream". |
| 10 | Streamable HTTP is POST-only, `Accept` lists both types, one message per POST, `202` for notifications | C | https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http.md: "The client **MUST** include an `Accept` header listing both `application/json` and `text/event-stream`"; "The body of the HTTP POST **MUST** be a single JSON-RPC *request* or *notification*."; "the server **MUST** return HTTP status code `202 Accepted` with no body." |
| 11 | Modern server "answers GET/DELETE with 405" | X | streamable-http.md: "A server that supports only this revision and receives such traffic from an older client **SHOULD** respond as follows: HTTP GET or DELETE to the MCP endpoint: respond with `405 Method Not Allowed`." It is a SHOULD, not a MUST. |
| 12 | `MCP-Protocol-Version` must equal `_meta` version, else `400` + `-32020`; `Mcp-Method` on all requests; `Mcp-Name` on `tools/call`, `resources/read`, `prompts/get` | C, A | streamable-http.md: "If the values do not match, the server **MUST** reject the request with `400 Bad Request` and a `HeaderMismatch` JSON-RPC error". Header table: "`Mcp-Method` / `method` / All requests"; "`Mcp-Name` / `params.name` or `params.uri` / `tools/call`, `resources/read`, `prompts/get` requests". Added the missing-header rule: "**MAY** treat a request that omits the header as protocol version `2025-03-26`. A server that does not support such clients **MUST** reject a request without the header". |
| 13 | `Mcp-Param-{Name}` value encoding and the `=?base64?…?=` sentinel | C, A | streamable-http.md: "These markers are case-sensitive and **MUST** appear exactly as shown (lowercase)."; "clients **MUST** also Base64-encode any plain-ASCII value that matches the sentinel pattern (i.e., starts with `=?base64?` and ends with `?=`)." I recomputed all five spec test vectors with `base64` and they match. Added the full vector table in §4.1. |
| 14 | An invalid `x-mcp-header` means drop the tool (MUST, on HTTP) | C | streamable-http.md: "Rejection means the client **MUST** exclude the invalid tool from the result of `tools/list`."; "Clients using other transports (e.g., stdio) **MAY** ignore `x-mcp-header` annotations entirely." |
| 15 | Error codes `-32020` / `-32021` / `-32022`, HTTP `400`, `data` shapes | C, A | schema.ts L434-450: `HEADER_MISMATCH = -32020`, `MISSING_REQUIRED_CLIENT_CAPABILITY = -32021`, `UNSUPPORTED_PROTOCOL_VERSION = -32022`; "For HTTP, the response status code MUST be `400 Bad Request`." Added: changelog.md Minor 12, "Renumber the error codes introduced in this draft accordingly — `HeaderMismatch` `-32001` → `-32020`, `MissingRequiredClientCapability` `-32003` → `-32021`, `UnsupportedProtocolVersion` `-32004` → `-32022`". Added the exact official error JSON in §2.1. |
| 16 | `ping`, `logging/setLevel` and `notifications/roots/list_changed` removed; `logLevel` set per request | C | changelog.md Major 5: "Remove `ping`, `logging/setLevel`, and `notifications/roots/list_changed`. Log level is now set per-request via `io.modelcontextprotocol/logLevel` in `_meta`". |
| 17 | SSE resumability removed; re-issue with a new id | C | changelog.md Major 9: "A broken response stream loses the in-flight request; clients **MUST** re-issue it as a new request with a new request ID". streamable-http.md: "Resumable SSE streams via `Last-Event-ID` are not supported." |
| 18 | `ttlMs` / `cacheScope` required on discover and the list/read results | C (source clarified) | caching.md: "Servers MUST include caching hints on results with `resultType: "complete"` returned by the following operations: `server/discover`, `tools/list`, `prompts/list`, `resources/list`, `resources/templates/list`, `resources/read`". The changelog Minor 5 list omits `server/discover`. |
| 19 | Tasks moved to extension `io.modelcontextprotocol/tasks`; `tasks/update` added; `tasks/list` and `tasks/result` removed; `CreateTaskResult` is flat with `resultType:"task"` | C | changelog.md Major 6: "replaces the blocking `tasks/result` method with polling via `tasks/get` and a new `tasks/update` … removes `tasks/list`". https://raw.githubusercontent.com/modelcontextprotocol/ext-tasks/main/schema/2026-07-28/schema.ts: `export type CreateTaskResult = Result & Task & { resultType: "task"; }`; `ttlMs: number \| null`; `pollIntervalMs?: number`. The ext-tasks README lists `2026-07-28` as "Stable". |
| 20 | Deprecations (Roots, Sampling, Logging, DCR, `includeContext` values, HTTP+SSE) and earliest removal | C; Risks wording X | https://modelcontextprotocol.io/specification/2026-07-28/deprecated.md: "Earliest removal: First revision released on or after 2027-07-28"; "The earliest removal marks when a feature becomes *eligible* for removal; the actual removal is a Core Maintainer decision … and may happen later." HTTP+SSE: "Three months after SEP-2596 reaches Final". |
| 21 | stdio era detection | C | https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio.md: "Do **not** fall back to `initialize`."; "The server returns any other error, or does not respond within a reasonable timeout: the server is legacy."; "The fallback **MUST NOT** be keyed to one specific error code"; "probing is still **RECOMMENDED**". |
| 22 | HTTP era detection and HTTP+SSE fallback | C | streamable-http.md: "If the body is empty or is not a recognized modern JSON-RPC error, fall back to `initialize`"; "If it fails with HTTP status code `400 Bad Request`, `404 Not Found`, or `405 Method Not Allowed` **and** the response body is not a recognized modern JSON-RPC error … Issue a GET request … expecting … an `endpoint` event as the first event." |
| 23 | Cache the era verdict per server process or origin | C | https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning.md: "Clients **SHOULD** cache the result for the lifetime of the server process (stdio) or origin (HTTP), and **MAY** persist it across restarts of the same server configuration". |
| 24 | Unknown method → `404` + `-32601` | C | streamable-http.md: "it **MUST** respond with `404 Not Found` and a JSON-RPC error with code `-32601`". |
| 25 | Resource not found → `-32602` with `data.uri`; accept `-32002` from L servers | C | https://modelcontextprotocol.io/specification/2026-07-28/server/resources.md: "servers **MUST** return a JSON-RPC error with code `-32602`"; "clients **SHOULD** also accept `-32002`". The example has `"data": {"uri": "file:///nonexistent.txt"}`. |
| 26 | "Only the client sends requests and notifications" | X | It contradicted the next sentence. https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/index.md: "Servers **MUST NOT** initiate JSON-RPC requests, and clients do not send JSON-RPC responses." Servers do send notifications. |
| 27 | TS SDK v2 constants, default mode and probe classifier | C (constants); X (classifier detail) | `client@2.3.1` `dist/src-WCy6ifGf.mjs` L474/L481: `FIRST_MODERN_PROTOCOL_VERSION = "2026-07-28"`, `SUPPORTED_MODERN_PROTOCOL_VERSIONS = [FIRST_MODERN_PROTOCOL_VERSION]`. `dist/index.mjs`: `DEFAULT_VERSION_NEGOTIATION_MODE = "legacy"`. `classifyRpcError`: `-32022` with modern-but-not-mutual `supported` → error, and legacy-only `supported` → legacy. `classifyHttpError`: a parsed JSON-RPC body is classified by code. Published 2.0.0 2026-07-27T23:55Z and 2.3.1 2026-10-05; `engines.node >=20`. |
| 28 | TS SDK v1 1.32.1 constants; `spec.types.d.ts` says `"DRAFT-2026-v1"` | C | `dist/esm/types.js` L2-4 as quoted in §0. `spec.types.d.ts` L18: `LATEST_PROTOCOL_VERSION = "DRAFT-2026-v1"`. npm `latest` = 1.32.1 (2026-10-05T11:47Z). |
| 29 | ext-apps "dist-tag `release-2.0`" | X | `npm view @modelcontextprotocol/ext-apps dist-tags` → `{"latest":"2.0.3","release-2.0":"2.0.3"}`; published 2026-09-25T16:01Z. ext-tasks 0.2.2: 2026-09-30 (confirmed). |
| 30 | Dart packages (`mcp_dart` 2.4.3, `dart_mcp` 0.5.2, `mcp_client` 3.0.0) and their constants | C | https://pub.dev/api/packages/{mcp_dart,dart_mcp,mcp_client}: latest 2.4.3 (2026-10-14), 0.5.2 (2026-06-29), 3.0.0 (2026-10-13). `mcp_dart` `json_rpc.dart` L19-29: `latestInitializationProtocolVersion = "2025-11-25"`, `stableProtocolVersion = "2026-07-28"`, `defaultProtocolVersion = stableProtocolVersion`. `dart_mcp` `api.dart` L46: `latestSupported = ProtocolVersion.v2025_11_25`. `mcp_client` `protocol.dart` L29-44: "NOT yet in [supportedVersions] until the stateless request path lands". |
| 31 | Sampling: client MUST error on `tools`/`toolChoice` without `sampling.tools` | C (clarified for M) | schema.ts (2026-07-28 and 2025-11-25): "The client MUST return an error if this field is provided but ClientCapabilities.sampling.tools is not declared." https://modelcontextprotocol.io/specification/2026-07-28/client/sampling.md: "Servers **MUST NOT** send tool-enabled sampling requests to Clients that have not declared support". In M there is no error slot in `InputResponses`, so the client declines by not retrying ("the server is not waiting"). |
| 32 | Listen filter fields gated by `listChanged` / `resources.subscribe` | U (relabelled as inference) | subscriptions.md only says: "Notification types the server does not support are omitted" from the ack. There is no explicit gating rule. |
| 33 | Extension ids `ui`, `tasks`, `skills`, `oauth-client-credentials`, `enterprise-managed-authorization` | C | https://modelcontextprotocol.io/extensions/overview.md, `/extensions/skills/overview.md` (`io.modelcontextprotocol/skills`), `/extensions/auth/enterprise-managed-authorization.md` (`io.modelcontextprotocol/enterprise-managed-authorization`), versioning.md (`io.modelcontextprotocol/ui`, `"mimeTypes": ["text/html;profile=mcp-app"]`). |
| 34 | How legacy TS v1 servers answer a modern probe | A | `modelcontextprotocol-sdk-1.32.1/package/dist/esm/server/webStandardStreamableHttp.js` L746: `createJsonErrorResponse(400, -32000, 'Bad Request: Server not initialized')`. L779: ``createJsonErrorResponse(400, -32000, `Bad Request: Unsupported protocol version: ${protocolVersion} …`)``. Message text looks modern but the code is `-32000`, which means legacy. |
| 35 | Auth: token on every HTTP request, never in the query string; `iss` validation | C | https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/index.md: "authorization **MUST** be included in every HTTP request from client to server"; "Access tokens **MUST NOT** be included in the URI query string"; changelog Minor 7: "MCP clients **MUST** validate a present `iss` against the recorded issuer". |

Not re-verified, because these are outside the load-bearing set and the first agent's text was left unchanged:
- the 2025-06-18 and 2025-11-25 changelog bullet lists in §1;
- the iOS and Android platform claims in §4.5;
- the TS v1 client reconnection constants in §4.2;
- the Dart `HttpClient.maxConnectionsPerHost` claim.

Separately, I did spot-check the L Streamable HTTP claims in §4.2 against https://modelcontextprotocol.io/specification/2025-11-25/basic/transports.md: session id range `0x21`-`0x7E`, `404` → new `InitializeRequest`, priming event with an empty `data`, `retry` MUST be respected, disconnect SHOULD NOT mean cancel, and the HTTP+SSE fallback on 400/404/405 of the POSTed `InitializeRequest`. All confirmed.
