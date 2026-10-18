# 03 — MCP Apps (SEP-1865, `io.modelcontextprotocol/ui`): host implementer digest + mobile WebView plan

Researched 2026-10-18. Every claim below was checked against a primary source: the ext-apps spec on raw.githubusercontent.com, the vendored npm package `@modelcontextprotocol/ext-apps@2.0.3`, the ext-apps `examples/basic-host` reference host, modelcontextprotocol.io, developer.android.com, developer.apple.com (doc JSON), and pub.dev/npm registries. Anything I could not check is marked **UNVERIFIED**.

Abbreviations:
- **Stable**: the ext-apps spec `specification/2026-01-26/apps.mdx`.
- **Draft**: the ext-apps spec `specification/draft/apps.mdx`.
- **SDK**: `@modelcontextprotocol/ext-apps@2.0.3`.
- **View**: the untrusted HTML app.
- **Host**: Sherpa.
- **L / M eras**: see `01-mcp-spec.md`. L is core MCP ≤ 2025-11-25 with the `initialize` handshake; M is core MCP 2026-07-28, stateless.

Local paths used throughout:
- `EXT` = `/opt/vendor-src/npm/modelcontextprotocol-ext-apps-2.0.3/package`
- `SDK1` = `/opt/vendor-src/npm/modelcontextprotocol-sdk-1.32.1/package`

---

## 0. Version facts (verified)

| Item | Value | Source |
|---|---|---|
| Extension identifier | `io.modelcontextprotocol/ui` (reserved), plus the reserved resource prefix `ui://` | Stable §"Extension Identifier" (L40) and §"Reservations in MCP" (L1765-1768): https://raw.githubusercontent.com/modelcontextprotocol/ext-apps/main/specification/2026-01-26/apps.mdx; `EXT/dist/src/server/index.js` (`EXTENSION_ID`) |
| Spec versions | **`2026-01-26` = Stable**; `draft` = in development. SEP-1865 status is **Final** (Extensions Track). | `EXT/README.md` §Specification; https://modelcontextprotocol.io/seps/1865-mcp-apps-interactive-user-interfaces-for-mcp.md |
| View↔Host protocol version | `LATEST_PROTOCOL_VERSION = "2026-01-26"`; AppBridge `SUPPORTED_PROTOCOL_VERSIONS = ["2026-01-26"]` | `EXT/dist/src/spec.types.d.ts`; `EXT/dist/src/app-bridge.js` (`var CF=[J]`, `J="2026-01-26"`) |
| npm `@modelcontextprotocol/ext-apps` | **2.0.3** (`latest`, 2026-09-25). 2.0.0 shipped 2026-09-08; the last 1.x is 1.7.5 (2026-07-23). Peer deps: `@modelcontextprotocol/client`/`core`/`server` `^2.0.0`, `zod ^4.2.0`. **Wire protocol unchanged 1.x↔2.x.** | https://registry.npmjs.org/@modelcontextprotocol/ext-apps; `EXT/package.json`; `EXT/README.md` ("The wire protocol is unchanged between ext-apps 1.x and 2.x") |
| `@mcp-ui/client` (3rd-party host SDK, "used by a few hosts") | 7.1.1 (2026-05-09) | npm registry; `EXT/README.md` |
| Core MCP | Latest release **2026-07-28** (stateless). It adds `extensions` to `ClientCapabilities`/`ServerCapabilities`, which **2025-11-25 does not have**. | https://modelcontextprotocol.io/specification/2026-07-28/changelog.md (Minor change 1); `schema/2025-11-25/schema.ts` has no `extensions` field; `schema/2026-07-28/schema.ts` L785 and L882 |
| TS SDK v1 1.32.1 | Declares `extensions?: {[key:string]: object}` on Client/ServerCapabilities, even in L era | `SDK1/dist/esm/spec.types.d.ts` L356-361, L441-446 |
| Dart `mcp_dart` 2.4.3 (2026-10-14) | Has typed MCP-UI helpers: `mcpUiExtensionId`, `mcpUiResourceMimeType`, `mcpUiLegacyResourceUriMetaKey='ui/resourceUri'`, `McpUiExtensionCapability`, `withMcpUiExtension()`, `McpUiToolMeta`, `McpUiCsp`, `McpUiPermissions`, `McpUiResourceMeta`. **There is no host-side bridge (no `ui/initialize` handling).** | pub.dev archive `lib/src/types/mcp_ui.dart`, `lib/src/server/mcp_ui.dart` |
| Supported clients (community matrix) | Claude web and Desktop, VS Code Copilot, M365 Copilot, Goose, Postman, MCPJam, ChatGPT, Cursor, Archestra, PostHog Code | https://modelcontextprotocol.io/extensions/client-matrix.md |
| androidx.webkit | latest stable **1.17.1**, `1.18.0-rc01` in RC | https://dl.google.com/android/maven2/androidx/webkit/webkit/maven-metadata.xml |
| Flutter webview plugins | `webview_flutter_android` 4.14.1 (2026-08-28), `webview_flutter_wkwebview` 3.27.0 (2026-10-01), `flutter_inappwebview` 6.1.5 (**last published 2024-10-08**, so stale) | pub.dev API |

---

## 1. TL;DR for a host implementer

1. **Negotiate.** Advertise `capabilities.extensions["io.modelcontextprotocol/ui"] = {"mimeTypes":["text/html;profile=mcp-app"]}`. In the L era this goes in `initialize`; in the M era it goes in **every request's** `_meta["io.modelcontextprotocol/clientCapabilities"]`. Servers may register different tools depending on this (§2).
2. **Link tools to UI.** Read `tool._meta.ui.resourceUri` first, then fall back to the deprecated `tool._meta["ui/resourceUri"]`. The URI must start with `ui://`. Honour `tool._meta.ui.visibility` (default `["model","app"]`). Hide a tool from the model unless its visibility includes `"model"`. Reject View→Host `tools/call` unless the visibility includes `"app"` **and** the tool belongs to the same server (§3).
3. **Fetch the UI.** Call `resources/read(uri)`. Expect exactly one content item with `mimeType === "text/html;profile=mcp-app"` and either `text` or base64 `blob`. Security metadata `_meta.ui` comes from the **content item first**, falling back to the `resources/list` entry (Draft). Then build the CSP from `csp.{connectDomains,resourceDomains,frameDomains,baseUriDomains}`. The host must **never** allow undeclared domains (§4, §5).
4. **Render.** Render inside a **sandboxed iframe**. Web hosts MUST use a separate-origin "sandbox proxy" outer iframe. Native hosts render "in an iframe" (§8). On mobile, use one WebView with a trusted shell page plus one sandboxed inner iframe (§11).
5. **Handshake.** The View sends `ui/initialize` (`appInfo`, `appCapabilities`, `protocolVersion`). The Host answers with `{protocolVersion, hostInfo, hostCapabilities, hostContext}`. The View then sends `ui/notifications/initialized`. **The Host MUST NOT send anything to the View before `initialized`** (§6.1, §7).
6. **Feed data.** Send 0..n `ui/notifications/tool-input-partial`, then exactly one `ui/notifications/tool-input`, then `ui/notifications/tool-result` (a `CallToolResult`) **or** `ui/notifications/tool-cancelled`.
7. **Serve the View's requests:**
   - `tools/call` and `resources/read`, proxied to the same server
   - `ui/open-link`, `ui/message`, `ui/update-model-context`, `ui/request-display-mode`
   - Draft additions: `ui/download-file` and `sampling/createMessage`
   - `notifications/message` (logs), `ui/notifications/size-changed`, `ui/notifications/request-teardown` (Draft), `ping`
8. **Push context changes** with `ui/notifications/host-context-changed`. It carries a partial `HostContext` (theme, display mode, container dimensions, and so on).
9. **Tear down.** Send the request `ui/resource-teardown`, wait for the response, then destroy the frame.
10. **Fallback.** If UI is unsupported, disabled or fails, show the tool's `content` blocks. Servers MUST return meaningful `content` even when they have a UI. Keep hiding app-only tools from the model regardless.

---

## 2. Capability negotiation (Host ↔ MCP server)

**L era (≤ 2025-11-25, `initialize`):**
```json
{"jsonrpc":"2.0","id":0,"method":"initialize","params":{
  "protocolVersion":"2025-11-25",
  "capabilities":{"extensions":{"io.modelcontextprotocol/ui":{"mimeTypes":["text/html;profile=mcp-app"]}}},
  "clientInfo":{"name":"sherpa","version":"1.0.0"}}}
```
Source: Stable §"Client<>Server Capability Negotiation" (L1492-1560). The spec example shows `"protocolVersion":"2024-11-05"`, which is irrelevant: the extension rides on any version.
- `mimeTypes` is **REQUIRED** and must include `"text/html;profile=mcp-app"`. Future settings `features` and `sandboxPolicies` are mentioned but undefined.
- The server-side check is `getUiCapability(clientCapabilities)`, which returns `clientCapabilities.extensions?.["io.modelcontextprotocol/ui"]`. Servers then test `uiCap?.mimeTypes?.includes(RESOURCE_MIME_TYPE)` (`EXT/dist/src/server/index.js`).
- **Gotcha:** many servers decide **at registration / `tools/list` time** whether to expose UI tools or text-only variants. If Sherpa toggles UI support (a user setting, low-memory mode), it must **re-negotiate**: reconnect in L, or send different per-request caps in M. Re-fetch `tools/list` afterwards.
- **Gotcha:** `extensions` is not in the 2025-11-25 core schema. A strict L-era server or SDK might strip it. TS SDK v1 1.32.1 and `mcp_dart` 2.4.3 both carry it (§0).

**M era (2026-07-28, stateless):**
- Clients put the capability in each request's `_meta["io.modelcontextprotocol/clientCapabilities"].extensions`.
- Servers advertise `capabilities.extensions["io.modelcontextprotocol/ui"] = {}` in the `server/discover` result.
- Example JSON: https://modelcontextprotocol.io/extensions/overview.md §Negotiation. The client matrix page (https://modelcontextprotocol.io/extensions/client-matrix.md) says the same.
- Under M, results carry `resultType`, and a server can answer `tools/call` with `resultType:"input_required"` (MRTR). The Host must resolve MRTR before it sends `ui/notifications/tool-result`. ext-apps 2.0.3's `ToolCallback` type already includes `InputRequiredResult` (`EXT/dist/src/server/index.d.ts`).

**Server-side helper behaviour worth knowing:** `registerAppTool()` normalizes `_meta` so that **both** `_meta.ui.resourceUri` and the legacy `_meta["ui/resourceUri"]` are present. `registerAppResource()` defaults `mimeType` to `text/html;profile=mcp-app` (`EXT/dist/src/server/index.js`). Hosts will therefore commonly see both keys.

---

## 3. Tool ↔ UI linkage and visibility

```ts
interface McpUiToolMeta {            // tool._meta.ui
  resourceUri?: string;              // "ui://..."
  visibility?: Array<"model"|"app">; // default ["model","app"]
  csp?: never; permissions?: never;  // SDK: belong on the RESOURCE, hosts ignore them here
}
// deprecated: tool._meta["ui/resourceUri"]  ("Will be removed before GA")
```
Sources: Stable §"Resource Discovery" (L319-402); `EXT/dist/src/spec.types.d.ts` (`McpUiToolMeta`); `EXT/dist/src/constants.d.ts` (`RESOURCE_URI_META_KEY = "ui/resourceUri"`, which **is the legacy flat key**).

**Reference resolution (`getToolUiResourceUri`, `EXT/dist/src/app-bridge.js`):**
```js
let uri = tool._meta?.ui?.resourceUri;
if (uri === undefined) uri = tool._meta?.["ui/resourceUri"];
if (typeof uri === "string" && uri.startsWith("ui://")) return uri;
else if (uri !== undefined) throw Error(`Invalid UI resource URI: ...`);
```

**Host MUST rules (Stable L395-402):**
- `visibility` defaults to `["model","app"]`.
- **tools/list:** do not include a tool in the agent's tool list when its visibility lacks `"model"`.
- **tools/call:** reject View-originated `tools/call` for tools lacking `"app"`.
- `"app"` means callable by the app **from the same server connection only**. Cross-server calls are always blocked for app-only tools.
- The Host MUST use `resources/read` for the URI. It MAY prefetch and cache. Servers MAY omit UI-only resources from `resources/list`.

**Gotchas:**
- The SDK helpers `isToolVisibilityAppOnly` and `isToolVisibilityModelOnly` return true **only** for exactly `["app"]` or exactly `["model"]`. A tool with `visibility: []` is neither, yet the spec rule hides it from the model **and** blocks it from apps. Implement the spec predicate directly:
  - `modelVisible = !vis || vis.includes("model")`
  - `appCallable = !vis || vis.includes("app")`
- **The SDK AppBridge does NOT enforce visibility or same-server rules.** When constructed with an MCP `Client`, `connect()` sets `oncalltool = (p) => client.request({method:"tools/call", params:p})` for every call (`EXT/dist/src/app-bridge.js`, `connect`). Sherpa must enforce these rules itself.
- By default **any ordinary tool of the same server** (no `_meta.ui`, visibility undefined) is app-callable. A View can therefore trigger destructive tools without the model. Apply the same approval policy as model calls (annotations such as `destructiveHint`/`readOnlyHint`), and attribute the call ("requested by <App name>").
- Legacy OpenAI Apps SDK keys exist in the wild. The mappings are:
  - `_meta["openai/outputTemplate"]` → `ui.resourceUri`
  - `openai/widgetAccessible` → `"app"` in visibility
  - `openai/visibility: "private"` → no `"model"`
  - `openai/widgetCSP` uses `resource_domains`/`connect_domains`/`frame_domains`/`redirect_domains`
  - `openai/widgetDomain`, `openai/widgetPrefersBorder`
  - mime type `text/html+skybridge`

  Source: https://raw.githubusercontent.com/modelcontextprotocol/ext-apps/main/docs/migrate_from_openai_apps.md. Supporting these is optional (see open questions).

---

## 4. UI resource shape

**Declared resource (`resources/list` entry):** `uri` (`ui://…`, MUST), `name`, `description?`, `mimeType` (SHOULD be `text/html;profile=mcp-app`), and `_meta?.ui?: UIResourceMeta`.

**`resources/read` result:**
```json
{"contents":[{"uri":"ui://weather-server/dashboard-template",
  "mimeType":"text/html;profile=mcp-app",
  "text":"<!DOCTYPE html><html>...</html>",
  "_meta":{"ui":{
    "csp":{"connectDomains":["https://api.openweathermap.org"],"resourceDomains":["https://cdn.jsdelivr.net"],
           "frameDomains":[],"baseUriDomains":[]},
    "permissions":{"camera":{},"microphone":{},"geolocation":{},"clipboardWrite":{}},
    "domain":"a904794854a047f6.claudemcpcontent.com",
    "prefersBorder":true}}}]}
```

**Content requirements (Stable L265-270):**
- The URI MUST start with `ui://`.
- `mimeType` MUST be `text/html;profile=mcp-app`.
- Content comes via `text` **or** `blob` (base64).
- The content MUST be a valid HTML5 document.

**`UIResourceMeta` fields (`EXT/dist/src/spec.types.d.ts`, `McpUiResourceMeta`):**
- `csp`:
  - `connectDomains` maps to `connect-src` (fetch, XHR, WebSocket).
  - `resourceDomains` maps to `script-src`, `style-src`, `img-src`, `font-src` and `media-src`. Wildcard subdomains `https://*.example.com` are supported.
  - `frameDomains` maps to `frame-src`; empty gives `'none'`.
  - `baseUriDomains` maps to `base-uri`; empty gives `'self'`.
  - SDK note: "**All** origins must be declared — including where your bundled JS/CSS is served from".
- `permissions`: `camera`, `microphone`, `geolocation` and `clipboardWrite`, each `{}`. They map to Permission Policy features `camera`, `microphone`, `geolocation` and `clipboard-write`. Hosts **MAY** honour them, and apps must feature-detect.
- `domain`: a **host-dependent** dedicated sandbox origin for OAuth callbacks, CORS, or API-key allowlists. Claude's format is `sha256(serverUrl).hex[0:32] + ".claudemcpcontent.com"` (https://raw.githubusercontent.com/modelcontextprotocol/ext-apps/main/docs/csp-cors.md). When omitted, the host default applies (typically per-conversation).
- `prefersBorder`: `true` requests a host border and background, `false` requests none, and omitted lets the host decide.

**Metadata location (Draft §"Metadata Location", L263-272):** `_meta.ui` may sit on the `resources/list` entry, on the `resources/read` content item, or both. **The content item wins.** "Hosts MUST check both locations, preferring the content item and falling back to the listing entry." The Stable spec only shows the content item. basic-host implements the fallback: `uiMeta = contentMeta?.ui ?? listingMeta?.ui`.

**Gotchas:**
- basic-host also reads `content.meta` because of a "Python SDK quirk" (`(content as any)._meta || (content as any).meta`). Source: https://raw.githubusercontent.com/modelcontextprotocol/ext-apps/main/examples/basic-host/src/implementation.ts.
- basic-host rejects `contents.length !== 1` and any mimeType other than `RESOURCE_MIME_TYPE`. Do the same: on mismatch, fall back to text.
- Decode `blob` as base64 **UTF-8**. basic-host's `atob()` yields a Latin-1 string, which is a bug for non-ASCII HTML. Use `utf8.decode(base64.decode(blob))` in Dart.

---

## 5. CSP and Permission Policy construction

**Restrictive default when `ui.csp` is omitted (MUST):**

The Stable list (L275-284):
```
default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline';
img-src 'self' data:; media-src 'self' data:; connect-src 'none';
```
The Draft (L284-294) adds `object-src 'none';`.

**Construction from metadata (Stable L1727-1752; the Draft is identical but reads `uiMeta = content._meta?.ui ?? listing._meta?.ui`):**
```
default-src 'none';
script-src 'self' 'unsafe-inline' {resourceDomains};
style-src  'self' 'unsafe-inline' {resourceDomains};
connect-src 'self' {connectDomains};
img-src  'self' data: {resourceDomains};
font-src 'self' {resourceDomains};
media-src 'self' data: {resourceDomains};
frame-src {frameDomains || 'none'};
object-src 'none';
base-uri {baseUriDomains || 'self'};
```

**Rules:**
- The Host "MAY further restrict but MUST NOT allow undeclared domains".
- It SHOULD log CSP configurations.
- It MUST block connections to undeclared domains.
- It SHOULD warn users when the UI requires external domain access.

**Permission Policy (iframe `allow`):** use the SDK's `buildAllowAttribute(permissions)`, which returns e.g. `"microphone; clipboard-write"` joined by **`"; "`** (`EXT/dist/src/app-bridge.js`). The spec's sample code joins with spaces and omits `clipboard-write`. The SDK form is the correct Permissions Policy syntax.

**Report back what was granted:** `hostCapabilities.sandbox = {permissions, csp}` carries the "CSP domains approved by the host" and the permissions granted (Stable L644-665).

**Gotchas:**
1. The two default paths differ:
   - `csp` omitted gives `connect-src 'none'` and no `font-src`.
   - `csp` present with empty lists gives `connect-src 'self'`.

   On mobile there is no same-origin server ("MCP App HTML runs in a sandboxed iframe with no same-origin server": `EXT/dist/src/spec.types.d.ts`, `McpUiResourceCsp`). Sherpa should **drop `'self'`** everywhere, which is a permitted further restriction.
2. The reference host's CSP is **looser than the spec**. Its `buildCspHeader` in https://raw.githubusercontent.com/modelcontextprotocol/ext-apps/main/examples/basic-host/serve.ts uses:
   ```
   default-src 'self' 'unsafe-inline'
   script-src 'self' 'unsafe-inline' 'unsafe-eval' blob: data: …
   worker-src 'self' blob: …
   img/font/media-src 'self' data: blob: …
   base-uri 'none'
   ```
   Its stated reason: WebGL apps (CesiumJS, Three.js) need blob workers, and "some libs need eval". Expect real Views to depend on `blob:` workers and `'unsafe-eval'`. This is a product decision (§15).
3. **CSP injection.** basic-host's `sanitizeCspDomains` drops entries matching `/[;\r\n'" ]/`. Sherpa should go further and accept only origin patterns:
   - `^(https|wss)://(\*\.)?[a-z0-9-]+(\.[a-z0-9-]+)*(:\d{1,5})?$`, after IDNA/punycode normalization
   - `http://localhost` and `ws://localhost` only in dev mode
   - reject bare `*`, keywords, `data:`, `blob:`, and IP literals or private ranges by default
4. The spec CSP lacks `form-action` (not covered by `default-src`) and `worker-src`. Add `form-action 'none'` as hardening.
5. CSP does not cover **WebRTC** (an exfiltration channel via ICE/STUN) or **top-level navigation**. The `sandbox` attribute and native navigation hooks must cover these (§11.6).
6. The SDK `App` sets `z.config({ jitless: true })` unless `allowUnsafeEval: true`. **SDK Views work without `'unsafe-eval'`** (`EXT/dist/src/app.d.ts`, `allowUnsafeEval`).

---

## 6. View ↔ Host protocol (JSON-RPC 2.0 over `postMessage`)

**Transport facts:**
- The View is conceptually an MCP client and the Host acts as an MCP server that proxies the real one.
- The SDK `PostMessageTransport(eventTarget, eventSource)` sends with `eventTarget.postMessage(msg, "*")`. It accepts only events where `event.source === eventSource` and parses with `JSONRPCMessageSchema`; non-JSON-RPC messages are ignored. The View uses `new PostMessageTransport(window.parent, window.parent)`. Source: `EXT/dist/src/message-transport.d.ts` and `EXT/dist/src/app-bridge.js` (class `c`).
- **Consequence:** the View must have a `window.parent` that is not itself. In a top-level WebView `window.parent === window`, so the SDK would receive its own messages. This is a key mobile design driver (§11.1).
- JSON-RPC ids are per sender. The Host must map View request ids to its own server request ids when proxying.
- The SDK's `Protocol` default request timeout is 60 s: `DEFAULT_REQUEST_TIMEOUT_MSEC = 60000` in `SDK1/dist/esm/shared/protocol.js`. The View bundle appears to use `60000` too (`EXT/dist/src/app-with-deps.js`, `IO=60000`), which is **UNVERIFIED** as the exact binding.
- `App.callServerTool` sends with `onprogress` and `resetTimeoutOnProgress: true`. A View's long `tools/call` therefore survives only if the Host relays `notifications/progress` for the View's `progressToken`.

### 6.0 Message catalog

| Method | Dir | Kind | Params → Result | Host obligations | Source |
|---|---|---|---|---|---|
| `ui/initialize` | V→H | req | `{appInfo:Implementation, appCapabilities:{experimental?, tools?:{listChanged?}, availableDisplayModes?:("inline"\|"fullscreen"\|"pip")[]}, protocolVersion:string}` → `{protocolVersion, hostInfo, hostCapabilities, hostContext, ...}` | Answer even before `initialized`. Echo the version if supported, else return `"2026-01-26"`. | `spec.types.d.ts` `McpUiInitializeRequest/Result`; app-bridge.js `_onAppsInitialize` |
| `ui/notifications/initialized` | V→H | notif | `{}` | Gate: nothing goes H→V before this. | Stable L485, L1310-1312 |
| `ui/notifications/tool-input-partial` | H→V | notif | `{arguments?:Record}`. This is "healed" partial JSON (unclosed brackets closed). | Optional, 0..n, only before `tool-input`. | Stable L1120-1143 |
| `ui/notifications/tool-input` | H→V | notif | `{arguments?:Record}` | MUST, once ("at most once"), after init and before `tool-result`. | Stable L1106-1118 |
| `ui/notifications/tool-result` | H→V | notif | `CallToolResult` `{content, structuredContent?, isError?, _meta?}` | MUST when the tool completes, if the View is displayed. | Stable L1145-1155 |
| `ui/notifications/tool-cancelled` | H→V | notif | `{reason?:string}` | MUST on any cancellation (user, sampling error, classifier, …). | Stable L1157-1169; schema: `reason` optional |
| `ui/notifications/host-context-changed` | H→V | notif | `Partial<HostContext>` | MAY; the View merges it. | Stable L1219-1229 |
| `ui/notifications/size-changed` | V→H | notif | `{width?:number, height?:number}` (px) | MUST track it when dimensions are flexible. | Stable L718-731, L1204-1217; schema: both optional |
| `ui/notifications/request-teardown` | V→H | notif | `{}` | **Draft.** MAY ignore or defer; if accepted, send `ui/resource-teardown`. | Draft L1445-1459 |
| `ui/resource-teardown` | H→V | **req** | SDK `{}` (spec prose shows `{reason}`) → `{}` | MUST send before teardown and SHOULD await the response. | Stable L1171-1202; schema.json |
| `ui/open-link` | V→H | req | `{url}` → `{}` or `{isError?:true}`, or JSON-RPC error `-32000` | SHOULD open in the browser. Validate the URL. | Stable L965-996; `McpUiOpenLinkResult` |
| `ui/message` | V→H | req | `{role:"user", content: ContentBlock[]}` → `{}` or `{isError?}` | SHOULD add to the conversation; MAY ask consent. | Stable L998-1034; **SDK uses an array** |
| `ui/update-model-context` | V→H | req | `{content?:ContentBlock[], structuredContent?:Record}` → `{}` | Overwrite semantics; send only the last update before the next user turn. | Stable L1061-1102 |
| `ui/request-display-mode` | V→H | req | `{mode}` → `{mode}` (the actual mode) | MUST return the resulting mode. MUST NOT switch to a mode the View didn't declare. | Stable L1036-1059, L778-789 |
| `ui/download-file` | V→H | req | `{contents:(EmbeddedResource\|ResourceLink)[]}` → `{}` or `{isError?}` | **Draft.** SHOULD confirm and sanitize the filename (last segment of `resource.uri`). | Draft L1066-1131 |
| `tools/call` | V→H→S | req | `CallToolRequest.params` → `CallToolResult` | Enforce visibility and same-server rules (§3). | Stable L493-495 |
| `resources/read` | V→H→S | req | standard | Same server only. | Stable L497-499 |
| `resources/list`, `resources/templates/list`, `prompts/list` | V→H→S | req | standard | AppBridge forwards these when the server has the capability; not in the spec's list. | app-bridge.js `connect` |
| `notifications/message` | V→H | notif | `{level, logger?, data}` | Log only, rate-limit, never to the model. | Stable L501-503 |
| `ping` | both | req | `{}` → `{}` | Auto-respond. | Stable L507-508 |
| `sampling/createMessage` | V→H | req | core `CreateMessageRequest` (incl. SEP-1577 tools) | **Draft.** Only if `hostCapabilities.sampling` is set. Rate-limit and require HITL. | Draft L532-534 |
| `tools/list`, `tools/call` (app tools) | H→V | req | standard MCP | **Draft.** Only if `appCapabilities.tools`. App tools are ephemeral and untrusted. | Draft L1239-1326, L1739-2177 |
| `notifications/tools/list_changed` | both | notif | `{}` | Server→Host→View when `serverTools.listChanged`; View→Host for app tools (Draft). | Draft L524-526 |
| `ui/notifications/sandbox-proxy-ready` | Proxy→H | notif | `{}` | Web double-iframe only (reserved). | Stable L1235-1243 |
| `ui/notifications/sandbox-resource-ready` | H→Proxy | notif | `{html, sandbox?, csp?, permissions?}` | Web double-iframe only (reserved). | Stable L1245-1270 |

Method-name constants are exported from `EXT/dist/src/spec.types.d.ts`: `INITIALIZE_METHOD`, `INITIALIZED_METHOD`, `TOOL_INPUT_METHOD`, `TOOL_INPUT_PARTIAL_METHOD`, `TOOL_RESULT_METHOD`, `TOOL_CANCELLED_METHOD`, `HOST_CONTEXT_CHANGED_METHOD`, `SIZE_CHANGED_METHOD`, `REQUEST_TEARDOWN_METHOD`, `RESOURCE_TEARDOWN_METHOD`, `OPEN_LINK_METHOD`, `DOWNLOAD_FILE_METHOD`, `MESSAGE_METHOD`, `REQUEST_DISPLAY_MODE_METHOD`, `SANDBOX_PROXY_READY_METHOD` and `SANDBOX_RESOURCE_READY_METHOD`.

### 6.1 `ui/initialize` result: `hostCapabilities` and `hostContext`

**`McpUiHostCapabilities`** (`EXT/dist/src/spec.types.d.ts`; Draft L657-735):
```ts
{ experimental?: Record<string, object>;
  openLinks?: {};
  downloadFile?: {};                                   // Draft
  serverTools?: { listChanged?: boolean };
  serverResources?: { listChanged?: boolean };
  logging?: {};
  sandbox?: { permissions?: {camera?,microphone?,geolocation?,clipboardWrite?}; csp?: McpUiResourceCsp };
  updateModelContext?: SupportedContentBlockModalities; // Draft: {text?,image?,audio?,resource?,resourceLink?,structuredContent?}
  message?: SupportedContentBlockModalities;            // Draft
  sampling?: { tools?: {} } }                           // Draft
```

**`McpUiHostContext`** (all fields optional, with an index signature `[key:string]: unknown` for forward compatibility):

| Field | Type / notes |
|---|---|
| `toolInfo` | `{id?: RequestId /* JSON-RPC id of the host→server tools/call */, tool: Tool /* full definition */}` |
| `theme` | `"light"\|"dark"` |
| `styles` | `{variables?: Record<McpUiStyleVariableKey, string\|undefined>, css?: {fonts?: string /* @font-face or @import */}}`. There are **76** standardized variable keys (counted in `McpUiStyleVariableKey`): `--color-{background,text,border,ring}-*`, `--font-sans/mono`, `--font-weight-*`, `--font-{text,heading}-*-{size,line-height}`, `--border-radius-{xs..xl,full}`, `--border-width-regular`, `--shadow-{hairline,sm,md,lg}`. Hosts should use CSS `light-dark()` values. |
| `displayMode` | `"inline"\|"fullscreen"\|"pip"` |
| `availableDisplayModes` | modes the host supports |
| `containerDimensions` | `({height} \| {maxHeight?}) & ({width} \| {maxWidth?})`. Fixed means the host controls the size; `max*` means the View controls it up to the cap; omitted means unbounded. |
| `locale` | BCP 47, e.g. `"en-US"` |
| `timeZone` | IANA, e.g. `"America/New_York"` |
| `userAgent` | **host application identifier** (not a browser UA) |
| `platform` | `"web"\|"desktop"\|"mobile"` |
| `deviceCapabilities` | `{touch?: boolean, hover?: boolean}` |
| `safeAreaInsets` | `{top,right,bottom,left}` px |

Sources: Stable L531-620; `EXT/dist/src/spec.types.d.ts`, `McpUiHostContext`. The Stable example result shows `"protocolVersion":"2026-01-26"`. The Draft examples still show the stale `"2025-06-18"`; ignore that.

**AppBridge reference behaviour** (`EXT/dist/src/app-bridge.js`):
- `_onAppsInitialize` stores `appCapabilities` and `appInfo`. It warns on a second `ui/initialize` (React StrictMode double-mount) but answers normally.
- It returns `{protocolVersion: SUPPORTED.includes(v) ? v : "2026-01-26", hostCapabilities, hostInfo, hostContext}`.
- The default `ui/request-display-mode` handler returns `{mode: hostContext.displayMode ?? "inline"}`.
- `setHostContext(ctx)` deep-compares each key with `JSON.stringify` and sends `host-context-changed` with only the changed keys.
- Handlers called before `initialized` only `console.warn`. They are not rejected.

### 6.2 Spec prose vs SDK wire format (be liberal on input)

| Item | Spec prose (Stable) | SDK 2.0.3 types / schema | Sherpa should |
|---|---|---|---|
| `ui/message.params.content` | single `{type:"text",text}` | `ContentBlock[]` (zod `F.array(x)`, schema.json `"type":"array"`) | Accept both, emit arrays. |
| `ui/resource-teardown.params` | `{reason: string}` | `{}`. schema.json says `additionalProperties:false`, but the runtime zod `F.object({})` is non-strict (strips extras). | Send `{}`; a `reason` is tolerated by SDK Views. |
| `size-changed` params | `width`, `height` required | both optional | Treat missing as "unchanged". |
| `tool-cancelled.reason` | `string` | optional | Always send one. |
| `tool-input.arguments` | required | optional | Always send (`{}` if none). |
| Error signalling | JSON-RPC error `-32000` | Results also allow `{isError:true}` (`McpUiOpenLinkResult` etc.) | Accept both from SDK Views; return `isError` results for policy denials. |
| `sandbox-proxy-ready` | Stable MUST; Draft SHOULD | n/a | n/a on mobile (internal reuse only). |
| Default CSP | without `object-src` (Stable) | n/a | Always add `object-src 'none'`. |
| Permissions `allow` | space-joined, no clipboard-write | `"; "`-joined, includes `clipboard-write` | Use the SDK form. |

---

## 7. Lifecycle and ordering (host state machine)

Spec sources: Stable §Lifecycle L1272-1389, §Data Passing L1391-1490; Draft §4 Teardown L1613-1630.

```
DISCOVER      tools/list (+ resources/list for listing-level _meta.ui); MAY prefetch and cache ui:// HTML
CALL          model emits tools/call(T) where T has ui.resourceUri
  ├─ in parallel: host→server tools/call (id=K)
  └─ in parallel: resources/read(uri) → validate mime → build CSP → create frame
LOAD          (web: proxy-ready → resource-ready) / (mobile: shell-ready → html)
HANDSHAKE     V→H ui/initialize ; H→V result(hostContext.toolInfo={id:K, tool:T}) ; V→H initialized
STREAM        H→V tool-input-partial* (only if args are still streaming)
INPUT         H→V tool-input (exactly once; buffer until after `initialized`)
RESULT        H→V tool-result  |  tool-cancelled   (buffer if the tool finished before INPUT)
INTERACTIVE   V→H tools/call, resources/read, ui/*, size-changed, logs ; H→V host-context-changed
TEARDOWN      [V→H request-teardown] ; H→V ui/resource-teardown (request) ; await {} (timeout) ; destroy
```

**Rules:**
- Teardown "may be triggered at any point following View initialization", and the Host MUST send `ui/resource-teardown` "for any reason".
- The Host "MUST NOT send any request or notification to the View before it receives an `initialized` notification" (Stable L485). This sentence is written inside the sandbox-proxy rules. The `tool-input` prose instead says "after the View's initialize request completes" (L1118). AppBridge docs say "after `oninitialized` callback fires … sent exactly once" (`EXT/dist/src/app-bridge.d.ts` L947-948). **Use the strict reading:** wait for `ui/notifications/initialized` on every platform.
- `tool-input` "is sent at most once and is required before sending `ui/notifications/tool-result`" (Stable L1118).
- Partial input "MUST stop sending once `ui/notifications/tool-input` is sent" (Stable L1136).
- basic-host order: `appBridge.connect()` → `sendSandboxResourceReady({html,csp,permissions})` → await `oninitialized` → `sendToolInput({arguments})` → on result `sendToolResult(result)`, on error `sendToolCancelled({reason})`. Source: https://raw.githubusercontent.com/modelcontextprotocol/ext-apps/main/examples/basic-host/src/implementation.ts, `initializeApp`. **Register all handlers before connect** ("handlers registered after connect() might miss early requests").

**Model-context semantics:**
- `content` is the text for the model and for text-only hosts.
- `structuredContent` is "optimized for UI rendering (not added to model context)".
- `_meta` is "not intended for model context" (Stable L1471-1475).
- `ui/update-model-context` overwrites the previous context. The host SHOULD send only the last update before the next user message, and MAY defer and dedupe (Stable L1093-1102).

---

## 8. Sandbox requirements (web hosts) and the double-iframe pattern

Source: Stable §"Sandbox proxy" L470-487 (MUST for web pages).
1. Host and Sandbox MUST have **different origins**.
2. The Sandbox iframe MUST have `allow-scripts allow-same-origin`.
3. The Sandbox sends `ui/notifications/sandbox-proxy-ready`. The Host sends the raw HTML in `ui/notifications/sandbox-resource-ready`.
4. The Sandbox loads the HTML with a CSP that:
   - enforces the declared domains;
   - uses `frame-src 'none'` and `base-uri 'self'` unless domains are declared;
   - sets `object-src 'none'`;
   - applies the restrictive defaults.

   It MAY set the inner `allow`.
5. The Sandbox forwards everything except `ui/notifications/sandbox-*` in both directions. It SHOULD NOT originate requests.
6. The Host MAY forward any non-`ui/` method to the server, and MAY block or require approval.

**Reference implementation** (https://raw.githubusercontent.com/modelcontextprotocol/ext-apps/main/examples/basic-host/src/sandbox.ts and `serve.ts`):
- The outer proxy is served from another port (8081) with the **CSP as an HTTP header** built from `?csp=<json>` ("tamper-proof unlike meta tags"), plus `Cache-Control: no-store`.
- The outer iframe is `sandbox="allow-scripts allow-same-origin allow-forms"` with `allow=buildAllowAttribute(permissions)`.
- The proxy validates `document.referrer` against an allowlist and derives `EXPECTED_HOST_ORIGIN` from it.
- Self-test: `window.top.alert(...)` must throw a SecurityError.
- The inner iframe is `sandbox="allow-scripts allow-same-origin allow-forms"`. The HTML goes in via `doc.open(); doc.write(html); doc.close()` because "CesiumJS won't work with srcdoc", with a fallback to `srcdoc`. The inner frame therefore **inherits the proxy's origin and CSP**.
- Messages from the parent are accepted only when `event.origin === EXPECTED_HOST_ORIGIN`. Messages from the inner frame are accepted only when `event.source === inner.contentWindow && event.origin === OWN_ORIGIN`. The relay posts to the parent with the explicit origin, and to the inner frame with `"*"`.

**Spec for native hosts:** the lifecycle diagram says "alt Desktop/Native hosts: Render View in an iframe (HTML from the ui:// resource)" and Mitigation 1 says "All View content MUST be rendered in sandboxed iframes with restricted permissions" (Stable L1301-1302, L1696-1700). The double-iframe proxy is mandated only for **web pages**.

---

## 9. When UI is unsupported or unavailable

- If the host doesn't advertise the extension, servers SHOULD register text-only tools. A tool with `_meta.ui` must still "behave as a standard tool (text-only fallback)" (Stable L386-390, L1556-1560).
- "Tools MUST return meaningful content array even when UI is available." Sherpa should always store and show `content` and treat the UI as progressive enhancement (https://raw.githubusercontent.com/modelcontextprotocol/ext-apps/main/docs/overview.md §"Progressive Enhancement").
- Runtime fallbacks Sherpa needs even when advertising support:
  - the resource fetch fails, has the wrong mime, or has `contents.length != 1`;
  - the WebView is missing or outdated (Android System WebView disabled);
  - the renderer crashed;
  - the user disabled interactive UI;
  - headless or background agent runs;
  - memory pressure.

  In all of these, render `content` blocks and never surface `structuredContent` as model context.
- App-only tools stay hidden from the model even when UI is off.

---

## 10. What to port into the Dart core (AppBridge parity checklist)

AppBridge surface (`EXT/dist/src/app-bridge.d.ts`):
- **Construction and connection:** `new AppBridge(client|null, hostInfo, hostCapabilities, {hostContext})`, `connect(transport)`.
- **Getters:** `getAppCapabilities()`, `getAppVersion()`, `getCapabilities()`.
- **Host-side senders:** `setHostContext(ctx)` (diff and notify), `sendHostContextChange(partial)`, `sendToolInput`, `sendToolInputPartial`, `sendToolResult`, `sendToolCancelled`, `sendSandboxResourceReady`, `teardownResource({})`, plus `sendResourceTeardown` (a deprecated alias).
- **Draft app tools:** `callTool` and `listTools`.
- **List-changed notifications:** `sendToolListChanged`, `sendResourceListChanged`, `sendPromptListChanged`.
- **Handler setters:** `onmessage`, `onopenlink`, `ondownloadfile`, `onrequestdisplaymode`, `onupdatemodelcontext`, `oncalltool`, `onlistresources`, `onlistresourcetemplates`, `onreadresource`, `onlistprompts`, `oncreatesamplingmessage`, `onping`.
- **Events:** `addEventListener("sizechange"|"sandboxready"|"initialized"|"requestteardown"|"loggingmessage")`. The `on*` event setters are deprecated in favour of these.

**Gaps Sherpa must fill (not in AppBridge):**
1. Visibility and same-server enforcement on `tools/call` (§3).
2. Progress relaying: the auto-forward calls `client.request({method:"tools/call", params})` with only `{signal}`, so server `notifications/progress` aren't relayed. **UNVERIFIED** what happens to the View's `progressToken`. Rewrite tokens and relay them.
3. **Sanitize the View-supplied `params._meta`** before forwarding. Strip `io.modelcontextprotocol/*` keys (M-era capability/protocol keys), `progressToken` (re-mint it) and any `traceparent`. Re-add the host's own per-request `_meta`.
4. MRTR (`resultType:"input_required"`) handling for View-originated calls.
5. Buffering `tool-input`/`tool-result` until `initialized`.
6. Teardown timeout.
7. Rate limits.
8. Audit log of every View-initiated RPC (spec: "Log View-initiated RPC calls"), plus a content hash of the UI HTML for allowlists ("Generate hash/signature for resources", Stable L1712-1721).

---

## 11. Mobile plan (Flutter UI, Kotlin/Swift native WebView plugins)

### 11.1 Architecture: is an inner iframe still needed? **Yes: one WebView, a trusted shell, and one sandboxed inner iframe.**

The WebView process boundary already isolates the View from native memory. Even so, keep the inner iframe for four reasons:
1. **Spec compliance:** "All View content MUST be rendered in sandboxed iframes", and native hosts "render the View in an iframe" (§8).
2. **SDK compatibility:** SDK Views talk to `window.parent` and filter on `event.source === window.parent`. As a top-level document `window.parent === window`, so the unmodified SDK breaks (§6).
3. **Bridge isolation:** the native bridge object lives only in the host-owned shell frame. The View, in an opaque-origin child frame, cannot reach shell globals and does not match the bridge's origin rules (Android) or frame checks (iOS).
4. **Free hardening from the `sandbox` attribute:** no popups, no top navigation, no downloads, no modals, no pointer lock, no same-origin.

The web-only "sandbox proxy" protocol messages are not needed, but Sherpa can reuse them internally on the shell↔native leg (§11.4).

```
Flutter widget (PlatformView: AndroidView / UiKitView)
 └─ WebView  [non-persistent store/profile, no file/content access, network-restricted]
     └─ Shell document  (host-generated, origin https://<id>.mcp-view.sherpa.invalid or appassets)   ← trusted
         • CSP <meta> built from ui.csp (first element in <head>)
         • relay script: iframe <-> native bridge (string JSON)
         └─ <iframe sandbox="allow-scripts allow-forms" allow="…" srcdoc=VIEW_HTML>  ← untrusted, opaque origin
```

**Why `srcdoc` plus no `allow-same-origin`:**
- A `srcdoc` iframe with `allow-same-origin` would be same-origin with the shell. On Android it would then **also receive the injected bridge object**, because the origin matches the rule.
- An opaque origin gives "no storage" for free. `localStorage` access throws a SecurityError. The ext-apps persistence pattern wraps storage in `try/catch`, so SDK-style Views degrade gracefully (https://raw.githubusercontent.com/modelcontextprotocol/ext-apps/main/docs/patterns.md §"Persisting view state").
- Cost: libraries that need same-origin `document.write` or real storage may break (basic-host notes CesiumJS fails with srcdoc). A "compat tier" is an open question (§15).

**Policy inheritance:** `srcdoc` documents inherit the creator's policy container (CSP, referrer policy). This is the HTML spec's behaviour. **UNVERIFIED on the exact Android System WebView and WKWebView versions**, so add an automated test. For belt and braces, also inject a `<meta http-equiv="Content-Security-Policy">` into the View HTML **immediately after the doctype** (before any other markup), so the parser puts it first in `<head>`.

### 11.2 Android (Kotlin, `android.webkit.WebView` + androidx.webkit 1.17.x)

**Bridge:** `WebViewCompat.addWebMessageListener(webView, "__sherpaHost", setOf(SHELL_ORIGIN), listener)` (feature `WebViewFeature.WEB_MESSAGE_LISTENER`). Facts from https://developer.android.com/reference/androidx/webkit/WebViewCompat:
- It injects the object "in any frame whose origin matches allowedOriginRules".
- Rules are `SCHEME "://" [HOSTNAME_PATTERN [":" PORT]]`, a wildcard `https://*.example.com`, a custom scheme `my-app-scheme://`, or `"*"`. There is **no rule that matches opaque `null` origins except `"*"`**, so the opaque View frame never gets the object.
- The callback is `onPostMessage(view, WebMessageCompat, Uri sourceOrigin, boolean isMainFrame, JavaScriptReplyProxy replyProxy)`. **Require `isMainFrame && sourceOrigin == SHELL_ORIGIN`.**
- **JS must post first** ("In order to send message from the app to JavaScript, it needs to post a message from JavaScript first"). The shell sends `shell-ready`, and native keeps that `replyProxy` for H→V traffic.
- Messages are String or ArrayBuffer, so use `JSON.stringify`.
- An optional overload takes a `JavaScriptExecutionWorld` (`JS_INJECTION_IN_FRAME_AND_WORLD`, 1.16.0+).

**Do NOT use `addJavascriptInterface`**. It "is injected into all frames of the web page, including all the iframes" (https://developer.android.com/reference/android/webkit/WebView#addJavascriptInterface). **`webview_flutter_android` 4.14.1's `JavaScriptChannel` is implemented with `addJavascriptInterface`** (`WebViewProxyApi.java:249` in the pub.dev archive). Sherpa's own Kotlin plugin is therefore required.

**Loading the shell:** `loadDataWithBaseURL("https://appassets.androidplatform.net/mcp-view/", shellHtml, "text/html", "utf-8", null)`.
- "If a valid HTTP or HTTPS base URL is not specified … window.origin value of 'null' … must not be considered a trusted origin."
- "baseUrl is sent in the 'Referer' HTTP header". Add `<meta name="referrer" content="no-referrer">` to the shell.
- `appassets.androidplatform.net` is "an unused domain reserved for Android applications to intercept requests" (`WebViewAssetLoader.DEFAULT_DOMAIN`).
- Alternative: `loadUrl` to an intercepted URL and set CSP as a real response header via `WebResourceResponse(mime, enc, 200, "OK", headers, stream)`.

**Settings (all from https://developer.android.com/reference/android/webkit/WebSettings unless noted):**
- `javaScriptEnabled = true`.
- `domStorageEnabled = false`. Default false; leave it.
- `allowFileAccess = false` (assets via `file:///android_asset` remain reachable regardless; don't load file URLs). `allowContentAccess = false` (default **enabled**).
- `setGeolocationEnabled(false)` (default **true**) unless the permission was granted.
- `setSupportMultipleWindows(false)`. With this, `window.open`/`target=_blank` "will instead be treated as top-level navigations", so you also need the navigation block below.
- `javaScriptCanOpenWindowsAutomatically = false`.
- `mixedContentMode = MIXED_CONTENT_NEVER_ALLOW`.
- `mediaPlaybackRequiresUserGesture = true`.
- `setBlockNetworkLoads(true)` when the resource declares no domains. **UNVERIFIED** whether `shouldInterceptRequest` is still consulted while network loads are blocked; test.
- `CookieManager.setAcceptThirdPartyCookies(webView,false)`.
- **Profiles:** `WebViewCompat.setProfile(webView, "mcp-<serverHash>")` (`WebViewFeature.MULTI_PROFILE`, androidx.webkit 1.9.0+) keeps cookies, cache and storage separate from any OAuth or login WebView Sherpa uses. Delete the profile's data on teardown.

**Navigation and network defence in depth (https://developer.android.com/reference/android/webkit/WebViewClient):**
- `shouldOverrideUrlLoading`: return `true` (block) for everything. Note: "may be called for subframes" and "not called for POST requests".
- `shouldInterceptRequest(view, request)`: allowlist the declared origins and return a 403 `WebResourceResponse` for the rest. It is "not called for javascript: URLs, blob: URLs" and runs only for the initial URL of redirects. **WebSocket is not covered (UNVERIFIED but widely reported)**, so CSP `connect-src` remains the primary control.

**Renderer robustness:**
- `onRenderProcessGone(view, detail)` **must return true** and destroy the WebView. Otherwise the "application will crash if render process crashed". Multiple WebViews may share one renderer.
- Optionally use `WebViewCompat.setWebViewRenderProcessClient` (`WEB_VIEW_RENDERER_CLIENT_BASIC_USAGE`) to detect hangs and call `terminate()`.

**Permissions:**
- `WebChromeClient.onPermissionRequest`: deny unless the resource declared it, Sherpa granted it, and the app holds the runtime permission.
- Set the inner `allow` from `buildAllowAttribute`.
- Ignore downloads (`setDownloadListener` no-op). The View must use `ui/download-file`.

**Hardening script:** `WebViewCompat.addDocumentStartJavaScript(webView, script, rules)` (`DOCUMENT_START_SCRIPT`, 1.9.0+) runs "in any frame whose origin matches" before page JS. To neuter `RTCPeerConnection` in the opaque View frame you need rules = `"*"`. That is acceptable for a script that exposes nothing. **UNVERIFIED** that this injects into opaque-origin `srcdoc` frames.

### 11.3 iOS (Swift, `WKWebView`)

**Data store:** `WKWebViewConfiguration.websiteDataStore = .nonPersistent()` per View or per server. It "stores website data in memory, and doesn't write that data to disk" (https://developer.apple.com/documentation/webkit/wkwebsitedatastore/nonpersistent()).

**Bridge:**
- Use `userContentController.add(handler, contentWorld: .page, name: "sherpaHost")`, or `addScriptMessageHandler(_:contentWorld:name:)` with `WKScriptMessageHandlerWithReply`. Both are iOS 14+.
- **Apple: the controller defines the JS function "in all frames in the specified content world"** (https://developer.apple.com/documentation/webkit/wkusercontentcontroller/add(_:contentworld:name:)). The View frame **can call it too**.
- **Validate every message:** require `message.frameInfo.isMainFrame == true` and `message.frameInfo.securityOrigin` == shell origin (`WKScriptMessage.frameInfo` iOS 8+, `WKFrameInfo.securityOrigin` iOS 9+).
- Hardening option: install the handler **and** the relay script in a private `WKContentWorld.world(name:)` (iOS 14+), so page-world JS (the View) can't see `window.webkit.messageHandlers.sherpaHost` at all. **UNVERIFIED** that `postMessage` issued from an isolated world produces `event.source === window.parent` in the child. Default to the page world plus frame checks.

**Native→JS:** `webView.callAsyncJavaScript("window.__sherpaFromNative(m)", arguments: ["m": jsonString], in: nil, in: .page)` (iOS 14+). Passing the payload as an argument avoids string-escaping injection bugs.

**Loading the shell:**
- `loadHTMLString(shellHtml, baseURL: URL(string: "https://<id>.mcp-view.sherpa.invalid/"))`. The https base gives a real origin and probably a secure context (**UNVERIFIED**). Use meta CSP in the shell.
- `WKURLSchemeHandler` cannot take `https`. It is "a programmer error to register a handler for a scheme WebKit already handles, such as https" (https://developer.apple.com/documentation/webkit/wkwebviewconfiguration/seturlschemehandler(_:forurlscheme:)). A custom scheme (`sherpa-view://`) works, but **UNVERIFIED** whether WebKit treats it as a secure context or applies CSP response headers from scheme-handler responses.

**Network blocking:** `WKContentRuleListStore` (iOS 11+) compiles a per-View rule list: `{"trigger":{"url-filter":".*"},"action":{"type":"block"}}` followed by `ignore-previous-rules` for each declared origin.
- `resource-type` values include `fetch`, `websocket`, `raw`, `media`, `ping`, `csp-report`, `child-document` (https://developer.apple.com/documentation/safariservices/creating-a-content-blocker).
- **UNVERIFIED:** the minimum iOS version that has `fetch`/`websocket` resource types.

**Navigation and UI:**
- `WKNavigationDelegate.webView(_:decidePolicyFor:decisionHandler:)`: allow only the initial shell load and `about:srcdoc`; cancel everything else, including subframe navigations (`navigationAction.targetFrame?.isMainFrame == false`).
- `WKUIDelegate.webView(_:createWebViewWith:…)`: return `nil`.
- `javaScriptCanOpenWindowsAutomatically = false`.
- `mediaTypesRequiringUserActionForPlayback = .all`.
- Media capture: `webView(_:requestMediaCapturePermissionFor:initiatedByFrame:type:decisionHandler:)` (iOS 15+) answers `.deny` unless granted.
- Block `WKDownload`.
- `isInspectable = false` in release builds.

**Crash:** `webViewWebContentProcessDidTerminate(_:)`. Show a "View crashed — tap to reload" placeholder and re-run the lifecycle from stored input and result.

### 11.4 Shell page and native envelope (sketch)

```html
<!doctype html><html><head>
<meta http-equiv="Content-Security-Policy" content="{SHERPA_CSP}">
<meta name="referrer" content="no-referrer">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<style>html,body{margin:0;height:100%;background:transparent}iframe{display:block;border:0;width:100%;height:100%}</style>
</head><body>
<iframe id="v" sandbox="allow-scripts allow-forms" allow="{ALLOW_ATTR}"></iframe>
<script>
(() => {
  const f = document.getElementById('v');
  const send = (s) => window.__sherpaHost            // Android addWebMessageListener object
      ? window.__sherpaHost.postMessage(s)
      : window.webkit.messageHandlers.sherpaHost.postMessage(s);   // iOS
  window.addEventListener('message', (e) => {        // View -> native
    if (e.source !== f.contentWindow) return;        // only our child frame
    const m = e.data;
    if (!m || m.jsonrpc !== '2.0') return;
    if (typeof m.method === 'string' && m.method.startsWith('ui/notifications/sandbox-')) return;
    send(JSON.stringify(m));
  });
  const onNative = (s) => {                          // native -> View
    const m = JSON.parse(s);
    if (m.method === 'ui/notifications/sandbox-resource-ready') { f.srcdoc = m.params.html; return; }
    f.contentWindow.postMessage(m, '*');             // '*' required: child origin is opaque ("null")
  };
  if (window.__sherpaHost) window.__sherpaHost.onmessage = (e) => onNative(e.data);
  window.__sherpaFromNative = onNative;              // iOS callAsyncJavaScript entry
  send(JSON.stringify({jsonrpc:'2.0', method:'ui/notifications/sandbox-proxy-ready', params:{}}));
})();
</script></body></html>
```

Notes:
- The relay is **not** the security boundary. The Dart core validates every frame: JSON-RPC shape, method allowlist, size limit (e.g. 4 MB), rate limit.
- The CSP `frame-src` applies to the shell too. **UNVERIFIED** that `frame-src 'none'` does not block the `about:srcdoc` child on all target engines. Test it. If it does block, add `about:` handling or set the child via `contentDocument` before applying a stricter policy.

### 11.5 Sherpa CSP on mobile

Built from the validated domain lists C, R, F and B:
```
default-src 'none';
script-src 'unsafe-inline' {R};        style-src 'unsafe-inline' {R};
img-src data: {R};  font-src {R};       media-src data: {R};
connect-src {C or 'none'};             frame-src {F or 'none'};
base-uri {B or 'none'};                object-src 'none';   form-action 'none';
[worker-src blob: {R}]   [script-src += 'wasm-unsafe-eval' | 'unsafe-eval']   ← product decisions
```

- Dropping `'self'` and using `base-uri 'none'` are permitted tightenings.
- Report the approved subset in `hostCapabilities.sandbox.csp`.
- **Network off by default:** with no declared domains, everything external is blocked by CSP, by `setBlockNetworkLoads`/interception on Android, and by the content rule list on iOS.
- **Consent:** the first time a server+resource-hash pair requests any external domain, show a sheet listing the connect, resource and frame domains. The spec says SHOULD warn.
- **Fonts:** don't send `styles.css.fonts` that point at host font URLs. They would be blocked by `font-src` (no `data:` in the spec formula). Use system stacks such as `--font-sans: system-ui, -apple-system, "Roboto", sans-serif`.

### 11.6 Mobile security gotchas (checklist)

1. Origin and frame checks on **every** inbound message: Android `isMainFrame && sourceOrigin`, iOS `frameInfo.isMainFrame && securityOrigin`. In the shell, check `e.source === iframe.contentWindow`.
2. Never put `allow-same-origin` on a `srcdoc` iframe. On Android it would expose the bridge (origin match), and on iOS it would expose shell globals.
3. Never `allow-popups` or `allow-top-navigation*`. Block all main-frame and sub-frame navigations natively. With `setSupportMultipleWindows(false)`, popups turn into top-level navigations on Android.
4. CSP does not cover:
   - **WebRTC.** Neuter `RTCPeerConnection` via a document-start script in all frames (Android rules `"*"`, iOS `forMainFrameOnly:false`), and deny media permissions.
   - **DNS prefetch** (`<link rel=dns-prefetch>`), which can leak minor data. **UNVERIFIED** per engine.
   - **Navigation-based exfiltration**, which the sandbox and navigation hooks block.
5. `ui/open-link`:
   - Allow `https:` only, optionally `mailto:`/`tel:` behind confirmation.
   - Reject `javascript:`, `intent:`, `file:`, `content:` and app deep links.
   - Show the host before opening, and open in Custom Tabs / `SFSafariViewController`.
6. `ui/message` (user role) and `ui/update-model-context` are **prompt-injection vectors** from untrusted code:
   - Render them visibly attributed to the App.
   - Require a tap-to-send for `ui/message` by default.
   - Cap the size, and wrap model context in "untrusted app context" delimiters.
   - Never include `structuredContent` unless the spec field says so.
7. `ui/download-file`:
   - Sanitize the filename (path traversal) and cap the size.
   - A `resource_link` makes the **host** fetch an arbitrary URL, which is an SSRF risk against the LAN on mobile. Allow https only, confirm with the user, and never attach credentials.
   - Deliver via the Android SAF/share sheet or `UIActivityViewController`.
8. App tools (Draft):
   - Namespace them (`app:<server>:<name>`).
   - Default to user confirmation unless `readOnlyHint:true`.
   - Limits: 50 tools, 30 s timeout, 10 MB results (the spec's recommended values, Draft L2611-2615).
   - Never persist them across sessions.
9. DoS: busy loops and WebGL can pin the CPU and GPU.
   - Cap live WebViews.
   - Pause or tear down off-screen Views. `IntersectionObserver` inside the View **cannot see native scrolling**, so the host must pause; the spec has no "visibility" context field.
   - Handle renderer death.
10. A shared renderer process means one View's crash or hang can affect sibling WebViews (Android docs). Isolate via profiles and process handling.
11. **Social engineering:** always draw host chrome (server name, "interactive content", a close button) outside the WebView. Never let the View render inside a frame that looks like Sherpa UI without a boundary (Stable L1762).
12. Strip View-supplied reserved `_meta` keys before proxying (§10). Never forward the View's request to a different server than its own.

### 11.7 Host context mapping on mobile

| Field | Sherpa value |
|---|---|
| `platform` | `"mobile"` |
| `deviceCapabilities` | `{touch:true, hover:<pointer device present>}` |
| `userAgent` | e.g. `"Sherpa/1.0.0 (Android 16)"` (host identifier) |
| `theme` | from Flutter `ThemeMode`/platform brightness. On change send `host-context-changed {theme}`. If `styles.variables` use `light-dark()`, the View flips via `color-scheme` (`applyDocumentTheme`). |
| `styles.variables` | Map `ColorScheme`/typography tokens to the 76 keys using `light-dark(<light>,<dark>)`. Provide **all** colour keys or none: partial sets clash with View fallbacks (Stable L893-895). |
| `locale` | `Localizations.localeOf(ctx).toLanguageTag()` |
| `timeZone` | **IANA id from native**: Android `java.util.TimeZone.getDefault().id`, iOS `TimeZone.current.identifier`. Dart `DateTime.timeZoneName` returns abbreviations such as "CET", not IANA. |
| `containerDimensions` | inline `{width: <bubble width in logical px>, maxHeight: <≈0.7×screen height>}`; fullscreen `{width, height}` |
| `displayMode` / `availableDisplayModes` | inline / `["inline","fullscreen"]`; pip optional (see open questions) |
| `safeAreaInsets` | inline `{0,0,0,0}`; fullscreen `MediaQuery.viewPadding` (logical px). Update on rotation and IME changes. |
| `toolInfo` | `{id: <host→server tools/call id>, tool: <full Tool>}` |

**Sizing:**
- CSS px equal Flutter logical px (dp/pt). The SDK's auto-resize sends `width = ceil(window.innerWidth)` and `height = ceil(documentElement height at max-content)`. It observes `documentElement` and `body`, debounces via rAF, and sends only on change (`EXT/dist/src/app.js`, `setupSizeChangedNotifications`).
- With a fixed width, ignore `width`, clamp `height` to `maxHeight`, and animate the platform-view height.
- Avoid nested-scroll traps: inline Views should be sized to content, so pass only tap and horizontal-drag gesture recognizers to the PlatformView. **UNVERIFIED** perf characteristics of Android hybrid composition with many WebViews.

**Display mode:**
- `ui/request-display-mode {mode:"fullscreen"}` → push a fullscreen route hosting the **same** WebView instance (reparenting) or a fresh one that replays state.
- Respond `{mode}`, then send `host-context-changed {displayMode, containerDimensions, safeAreaInsets}`.
- Never switch to a mode absent from `appCapabilities.availableDisplayModes`.

### 11.8 Lifecycle management on mobile

- **Persist per tool call:** `{serverId, tool, arguments, CallToolResult, resourceUri, htmlHash, csp}`. To re-render from chat history, replay handshake → `tool-input` → `tool-result`. View state is ephemeral by design (no storage).
- **Pool:**
  - Keep at most N (e.g. 2–3) live inline WebViews.
  - Show a static placeholder (or snapshot) for off-screen ones.
  - Before destroying, always send `ui/resource-teardown` with a timeout (e.g. 1–2 s; the spec says SHOULD wait).
  - Prewarm one shell WebView at app start to hide creation latency (**UNVERIFIED** magnitude).
- **App backgrounding:** keep the WebViews but stop delivering non-essential notifications. Under OS memory pressure, tear down off-screen Views.
- **Caching:** cache `ui://` HTML by `(serverId, uri)`, respecting M-era `ttlMs`/`cacheScope` (01-mcp-spec §1). Re-hash on every fetch and re-prompt consent if the hash or CSP changed.

---

## 12. Complete example message sequence (JSON)

Legs:
- **H↔S** is MCP over the server transport (L era shown, with M-era notes).
- **N↔Shell** is Sherpa-internal over the native bridge, as JSON strings.
- **H↔V** is JSON-RPC that the Dart core exchanges with the View through the shell relay.

Ids:
- `1xx` are Host→Server.
- `v1`, `v2`… are the View's own ids. The SDK uses numbers; shown as strings here for clarity.
- `h1`… are Host→View ids.

**Phase A: discovery (H↔S)**

1. **H→S** `initialize`. Under M there is no `initialize`; the same `capabilities` object goes in `_meta["io.modelcontextprotocol/clientCapabilities"]` on every request.
```json
{"jsonrpc":"2.0","id":100,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"extensions":{"io.modelcontextprotocol/ui":{"mimeTypes":["text/html;profile=mcp-app"]}}},"clientInfo":{"name":"sherpa","version":"1.0.0"}}}
```
2. **S→H** `tools/list` result. Both keys are present because `registerAppTool` emits both. `refresh_weather` is app-only, so it is hidden from the model.
```json
{"jsonrpc":"2.0","id":101,"result":{"tools":[
 {"name":"get_weather","description":"Get current weather","inputSchema":{"type":"object","properties":{"location":{"type":"string"}},"required":["location"]},
  "_meta":{"ui":{"resourceUri":"ui://weather/dashboard.html"},"ui/resourceUri":"ui://weather/dashboard.html"}},
 {"name":"refresh_weather","description":"Refresh dashboard data","inputSchema":{"type":"object","properties":{"location":{"type":"string"}}},
  "_meta":{"ui":{"resourceUri":"ui://weather/dashboard.html","visibility":["app"]}}}]}}
```

**Phase B: model calls the tool, host fetches the resource**

3. **H→S** `tools/call` (model-initiated; id 102 becomes `toolInfo.id`)
```json
{"jsonrpc":"2.0","id":102,"method":"tools/call","params":{"name":"get_weather","arguments":{"location":"Lisbon"}}}
```
4. **H→S** `resources/read`, sent in parallel with step 3
```json
{"jsonrpc":"2.0","id":103,"method":"resources/read","params":{"uri":"ui://weather/dashboard.html"}}
```
5. **S→H** `resources/read` result
```json
{"jsonrpc":"2.0","id":103,"result":{"contents":[{"uri":"ui://weather/dashboard.html","mimeType":"text/html;profile=mcp-app","text":"<!DOCTYPE html><html><head>...</head><body><div id=app></div><script type=module>/* bundled App SDK */</script></body></html>","_meta":{"ui":{"csp":{"connectDomains":["https://api.open-meteo.com"]},"prefersBorder":true}}}]}}
```
Host actions:
- validate the mime type and content count;
- compute the SHA-256 of the HTML;
- show the consent sheet for `api.open-meteo.com`;
- build the CSP `default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src 'none'; media-src data:; connect-src https://api.open-meteo.com; frame-src 'none'; base-uri 'none'; object-src 'none'; form-action 'none'` (an explicit `'none'` replaces each empty source list);
- create the WebView with the shell.

**Phase C: shell bootstrap (N↔Shell, Sherpa-internal, reusing the reserved names)**

6. **Shell→N**
```json
{"jsonrpc":"2.0","method":"ui/notifications/sandbox-proxy-ready","params":{}}
```
7. **N→Shell** (the shell sets `iframe.srcdoc`)
```json
{"jsonrpc":"2.0","method":"ui/notifications/sandbox-resource-ready","params":{"html":"<!DOCTYPE html><meta http-equiv=\"Content-Security-Policy\" content=\"...same CSP...\"><html>...</html>","sandbox":"allow-scripts allow-forms","csp":{"connectDomains":["https://api.open-meteo.com"]}}}
```

**Phase D: View handshake (H↔V)**

8. **V→H** `ui/initialize`
```json
{"jsonrpc":"2.0","id":"v1","method":"ui/initialize","params":{"appInfo":{"name":"Weather Dashboard","version":"1.2.0"},"appCapabilities":{"availableDisplayModes":["inline","fullscreen"]},"protocolVersion":"2026-01-26"}}
```
9. **H→V** result
```json
{"jsonrpc":"2.0","id":"v1","result":{"protocolVersion":"2026-01-26","hostInfo":{"name":"sherpa","version":"1.0.0"},
 "hostCapabilities":{"openLinks":{},"serverTools":{},"serverResources":{},"logging":{},"updateModelContext":{"text":{}},"message":{"text":{}},
   "sandbox":{"csp":{"connectDomains":["https://api.open-meteo.com"]}}},
 "hostContext":{"toolInfo":{"id":102,"tool":{"name":"get_weather","description":"Get current weather","inputSchema":{"type":"object","properties":{"location":{"type":"string"}},"required":["location"]},"_meta":{"ui":{"resourceUri":"ui://weather/dashboard.html"}}}},
   "theme":"dark","styles":{"variables":{"--color-background-primary":"light-dark(#ffffff, #121212)","--color-text-primary":"light-dark(#111111, #f2f2f2)","--font-sans":"system-ui, -apple-system, Roboto, sans-serif"}},
   "displayMode":"inline","availableDisplayModes":["inline","fullscreen"],"containerDimensions":{"width":360,"maxHeight":560},
   "locale":"pt-PT","timeZone":"Europe/Lisbon","userAgent":"Sherpa/1.0.0 (Android 16)","platform":"mobile",
   "deviceCapabilities":{"touch":true,"hover":false},"safeAreaInsets":{"top":0,"right":0,"bottom":0,"left":0}}}}
```
10. **V→H** (the gate opens)
```json
{"jsonrpc":"2.0","method":"ui/notifications/initialized","params":{}}
```

**Phase E: data delivery**

11. **H→V** partial input (optional, only while the model is still streaming args)
```json
{"jsonrpc":"2.0","method":"ui/notifications/tool-input-partial","params":{"arguments":{"location":"Lis"}}}
```
12. **H→V** complete input (exactly once)
```json
{"jsonrpc":"2.0","method":"ui/notifications/tool-input","params":{"arguments":{"location":"Lisbon"}}}
```
13. **S→H** result for 102, followed by **H→V** `tool-result`. The model context gets only `content`.
```json
{"jsonrpc":"2.0","id":102,"result":{"content":[{"type":"text","text":"Lisbon: 21°C, clear"}],"structuredContent":{"tempC":21,"conditions":"clear","hourly":[20,21,22]},"_meta":{"viewUUID":"5c0e..."}}}
```
```json
{"jsonrpc":"2.0","method":"ui/notifications/tool-result","params":{"content":[{"type":"text","text":"Lisbon: 21°C, clear"}],"structuredContent":{"tempC":21,"conditions":"clear","hourly":[20,21,22]},"_meta":{"viewUUID":"5c0e..."}}}
```

**Phase F: the View calls an app-only tool**

14. **V→H** `tools/call` (SDK `callServerTool` adds a progress token)
```json
{"jsonrpc":"2.0","id":"v2","method":"tools/call","params":{"name":"refresh_weather","arguments":{"location":"Lisbon"},"_meta":{"progressToken":"v-pt-1"}}}
```
Host checks:
- the tool exists on **this View's server**;
- `visibility` includes `"app"`;
- the approval policy passes.

Then sanitize `_meta` (re-mint the progress token) and record the audit log.

15. **H→S**
```json
{"jsonrpc":"2.0","id":104,"method":"tools/call","params":{"name":"refresh_weather","arguments":{"location":"Lisbon"},"_meta":{"progressToken":"h-pt-104"}}}
```
16. **S→H** progress, relayed **H→V** with the View's token. Then **S→H** result, relayed as **H→V** response `v2`.
```json
{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"v-pt-1","progress":1,"total":2}}
```
```json
{"jsonrpc":"2.0","id":"v2","result":{"content":[{"type":"text","text":"Lisbon: 22°C, clear"}],"structuredContent":{"tempC":22,"conditions":"clear","hourly":[21,22,22]}}}
```
If the View had called `get_weather` on another server, or a tool with `visibility:["model"]`:
```json
{"jsonrpc":"2.0","id":"v3","error":{"code":-32602,"message":"Tool not callable from this app"}}
```
The spec doesn't fix this error code; `-32602` (Invalid params) is Sherpa's choice.

**Phase G: resize, context change, teardown**

17. **V→H** (SDK auto-resize). The host keeps width 360 (fixed), sets the platform-view height to 412 (≤ 560) and animates.
```json
{"jsonrpc":"2.0","method":"ui/notifications/size-changed","params":{"width":360,"height":412}}
```
18. **H→V** (the user toggled the theme)
```json
{"jsonrpc":"2.0","method":"ui/notifications/host-context-changed","params":{"theme":"light"}}
```
19. **V→H** (optional, Draft: the user tapped "Done" in the View)
```json
{"jsonrpc":"2.0","method":"ui/notifications/request-teardown","params":{}}
```
20. **H→V** teardown request, then **V→H** response. The host then destroys the WebView, deletes the profile or data store, and keeps the stored input and result for re-rendering.
```json
{"jsonrpc":"2.0","id":"h1","method":"ui/resource-teardown","params":{}}
```
```json
{"jsonrpc":"2.0","id":"h1","result":{}}
```

---

## 13. Recommendations for Sherpa

1. **Implement the host side in pure Dart** as an `McpAppSession` that mirrors AppBridge semantics (§10) and fills the listed gaps:
   - visibility and same-server enforcement
   - `_meta` sanitization
   - progress relay
   - MRTR
   - buffering and gates
   - teardown timeout
   - audit log and HTML hashing

   Use `mcp_dart` 2.4.3's `McpUiToolMeta`/`McpUiResourceMeta`/`withMcpUiExtension` types for parsing and negotiation. It has no host bridge.
2. **Write Sherpa's own Kotlin and Swift WebView plugin.** Don't use `webview_flutter`'s `JavaScriptChannel`: on Android it uses `addJavascriptInterface`, which injects into all iframes. `flutter_inappwebview` is unmaintained since 2024-10.
   - Android: `addWebMessageListener` restricted to the shell origin.
   - iOS: `WKScriptMessageHandler(WithReply)` with `frameInfo` checks.
3. **Architecture:** a WebView, a host-generated trusted shell (meta CSP first in head), and an inner `<iframe sandbox="allow-scripts allow-forms" srcdoc>` with an opaque origin. Inject the CSP meta into the View HTML as well (after the doctype). This gives no storage, no popups and no navigation, and it is SDK-compatible.
4. **Default posture:**
   - no network unless declared and consented;
   - `'self'` removed;
   - `base-uri 'none'`, `form-action 'none'`, `object-src 'none'`;
   - no permissions granted in v1 (advertise none in `hostCapabilities.sandbox.permissions`);
   - `sampling` not advertised;
   - `downloadFile` advertised only once the SAF/share-sheet flow is built.
5. **Advertise conservatively in `hostCapabilities`:** `openLinks`, `serverTools`, `serverResources`, `logging`, `updateModelContext:{text:{}}`, `message:{text:{}}`. Gate `ui/message` behind a visible confirm chip at first.
6. **Store every UI tool call's input and result** so Views can be re-rendered from history and pooled aggressively. Only 2–3 live WebViews; always send `ui/resource-teardown` before destroying.
7. **Be liberal on input:**
   - `ui/message` content as an object or an array;
   - `isError` results and JSON-RPC errors;
   - `_meta`/`meta` (Python quirk);
   - the legacy `ui/resourceUri`;
   - both metadata locations.

   Be strict on output: SDK shapes (arrays, `{}` teardown params).
8. **Re-negotiate** when the user toggles interactive UI. Servers gate tool registration on the capability.
9. **Ship a conformance harness:**
   - run the ext-apps examples (`@modelcontextprotocol/server-<name>`, e.g. `server-map`, `server-threejs`, `server-pdf`) against Sherpa on both platforms;
   - add tests for CSP inheritance into `srcdoc`, `frame-src` vs `about:srcdoc`, the WebRTC neutering, the opaque-origin `localStorage` failure, and navigation blocking.
10. **Fallback first:** a `content`-only renderer is the baseline for every UI tool. UI failure must never lose information.

## 14. Risks

- **Spec churn.** The Draft adds features beyond Stable 2026-01-26: `ui/download-file`, `request-teardown`, `sampling/createMessage`, app-provided tools, listing-level metadata, and new `hostCapabilities` fields. The deprecated `ui/resourceUri` "will be removed before GA" even though SEP-1865 is "Final". Pin to Stable 2026-01-26 and treat Draft features as opt-in.
- **Core MCP 2026-07-28 statelessness** changes negotiation to per-request `_meta`, and most servers are still L-era. Dual-era complexity leaks into Apps: capability-dependent tool lists and MRTR during View-initiated calls.
- **Real-world Views assume looser CSP than the spec.** The reference host allows `'unsafe-eval'`, `blob:`/`data:` scripts and blob workers. A strict mobile CSP plus opaque origin will break some Views: WebGL/Cesium/Three.js, WASM, apps needing `localStorage` or `document.write`.
- **Engine-behaviour uncertainty** (all UNVERIFIED):
  - `srcdoc` CSP inheritance and `frame-src` interplay
  - custom-scheme secure contexts on iOS
  - `shouldInterceptRequest` coverage under `setBlockNetworkLoads`
  - WebSocket interception
  - content-rule-list `fetch`/`websocket` minimum iOS version

  System WebView versions vary on Android.
- **Prompt injection and social engineering** through `ui/message`, `ui/update-model-context`, app-tool descriptions and misleading UI. App-callable server tools (default visibility) let a View act without the model.
- **Resource exhaustion:** many WebViews in a chat list, renderer crashes taking down siblings, and GPU-heavy Views draining battery. `IntersectionObserver`-based pausing doesn't work under native scrolling.
- **`domain` semantics can't be honoured** with opaque origins. Fetches send `Origin: null`, so APIs that allowlist a specific origin (CORS) won't work in Sherpa.
- **Exfiltration channels outside CSP:** WebRTC, DNS prefetch, and the host-side fetch in `ui/download-file` `resource_link` (SSRF).

## 15. Open questions for the product owner

1. **CSP strictness:** spec-strict (no `'unsafe-eval'`, no blob workers), or basic-host-compatible (`'unsafe-eval'`, `blob:` workers, `'wasm-unsafe-eval'`)? Should this be per-server opt-in with a warning?
2. **Compat tier:** should Sherpa offer an opt-in "same-origin compat mode" (a distinct per-View https origin, `allow-same-origin`, non-persistent storage) for Views that need `localStorage`, `document.write` or a stable Origin header (`ui.domain`)? It expands the attack surface (bridge exposure must then rely solely on native validation).
3. **`ui/message` UX:** auto-send, or require user confirmation? Same question for `ui/update-model-context`: always visible to the user, or silent?
4. **Permissions:** support camera, microphone, geolocation or clipboard for Views in v1 (OS prompts plus a per-server grant UI), or advertise none?
5. **Downloads:** support `ui/download-file` in v1? Should host-fetched `resource_link` downloads be allowed at all (SSRF risk)?
6. **Sampling from Views** (`sampling/createMessage`, Draft; core Sampling is deprecated in 2026-07-28): expose local or remote model access to Views? Under what cost and rate limits?
7. **App-provided tools** (Draft): let Views register tools the agent can call (voice/agent-driven UIs)? With what approval model?
8. **Display modes:** offer `pip` on mobile (a floating overlay over chat) or only `inline` and `fullscreen`?
9. **Legacy compatibility:** support OpenAI Apps SDK keys (`openai/outputTemplate`, `text/html+skybridge`, `window.openai`) for servers not yet migrated?
10. **Concurrency budget:** how many live interactive Views per conversation, and what is the off-screen policy (snapshot vs placeholder)?
11. **Network consent granularity:** per server, per resource hash, or per domain? Should it be remembered across sessions?

---

## 16. Verification log

Each load-bearing claim was re-checked after drafting by re-reading the cited primary source.

| # | Claim | Result | Source |
|---|---|---|---|
| 1 | Extension id `io.modelcontextprotocol/ui`; client caps `capabilities.extensions["io.modelcontextprotocol/ui"].mimeTypes` (required) with `"text/html;profile=mcp-app"` | **Confirmed** | Stable L40 and L1498-1522; `EXT/dist/src/server/index.js`: `W="io.modelcontextprotocol/ui"; function H(B){...return B.extensions?.[W]}` |
| 2 | In the M era, client caps travel per-request in `_meta["io.modelcontextprotocol/clientCapabilities"]`; servers advertise `extensions` in `server/discover`; `extensions` is absent from the 2025-11-25 schema | **Confirmed** | https://modelcontextprotocol.io/extensions/overview.md §Negotiation; changelog 2026-07-28 Minor 1; `grep -c extensions schema-2025-11-25.ts` hits only unrelated comments (L67, L83) |
| 3 | Tool linkage: `_meta.ui.resourceUri` takes precedence over the legacy `_meta["ui/resourceUri"]`; it must start with `ui://`, otherwise an error is thrown; `RESOURCE_URI_META_KEY` is the legacy key | **Confirmed** | `EXT/dist/src/app-bridge.js` `function AG`; `EXT/dist/src/constants.d.ts` |
| 4 | Visibility default `["model","app"]`; Host MUST hide tools without `"model"` from the agent and MUST reject app calls without `"app"`; same-server only | **Confirmed** | Stable L395-402 |
| 5 | AppBridge auto-forwards `tools/call` with no visibility check; `isToolVisibilityAppOnly` is true only for exactly `["app"]` | **Confirmed** | `EXT/dist/src/app-bridge.js`: `connect(){... this.oncalltool=async(W,X)=>this._client.request({method:"tools/call",params:W},{signal:X.mcpReq.signal})}`; `function IG(...){if(W.length===1&&W[0]==="app")return!0}` |
| 6 | Restrictive default CSP when `ui.csp` is omitted: Stable has no `object-src`; the Draft adds `object-src 'none'`; the construction formula in both versions includes `object-src 'none'` | **Confirmed.** The digest distinguishes the two (§5, §6.2). | Stable L277-284 vs Draft L286-294 (re-read verbatim) |
| 7 | `ui/initialize` params `{appInfo, appCapabilities, protocolVersion:"2026-01-26"}`; the View then sends `ui/notifications/initialized`; the host echoes a supported version, else `"2026-01-26"` | **Confirmed** | `EXT/dist/src/app.js` `connect()`; `EXT/dist/src/app-bridge.js` `_onAppsInitialize`; `spec.types.d.ts` `LATEST_PROTOCOL_VERSION = "2026-01-26"` |
| 8 | `ui/message.content` is an array in the SDK (spec prose shows a single object); `ui/resource-teardown` params are `{}` in the SDK (spec prose shows `{reason}`); zod is non-strict | **Confirmed** | `EXT/dist/src/generated/schema.json` (`McpUiMessageRequest.params.content.type = "array"`; `McpUiResourceTeardownRequest.params.properties = {}`); `app-bridge.js` `LF=F.object({method:F.literal("ui/resource-teardown"),params:F.object({})})`; 0 occurrences of `strict()` |
| 9 | Ordering: Host MUST NOT send to the View before `initialized`; `tool-input` at most once and before `tool-result`; partial stops at `tool-input`; teardown is a request the host SHOULD await | **Confirmed, with a nuance now noted in §7.** The "MUST NOT send … before `initialized`" sentence sits inside the sandbox-proxy rules (item 6). The `tool-input` prose says "after the View's initialize request completes". AppBridge docs say "after `oninitialized` … sent exactly once". Sherpa uses the strictest reading (after `initialized`). | Stable L485, L1118, L1136, L1201-1202; `EXT/dist/src/app-bridge.d.ts` L947-948 |
| 10 | Android: `addWebMessageListener` injects into frames matching origin rules; the rule grammar has no opaque-origin rule except `"*"`; JS must post first; `addJavascriptInterface` injects into all frames, including iframes; `webview_flutter_android` uses `addJavascriptInterface` | **Confirmed** | https://developer.android.com/reference/androidx/webkit/WebViewCompat (addWebMessageListener section); https://developer.android.com/reference/android/webkit/WebView (addJavascriptInterface: "injected into all frames of the web page, including all the iframes"); `webview_flutter_android-4.14.1` `WebViewProxyApi.java:249` |
| 11 | iOS: `add(_:contentWorld:name:)` defines the handler "in all frames in the specified content world"; `WKScriptMessage.frameInfo`, `WKFrameInfo.isMainFrame`/`securityOrigin` exist; registering `https` with `setURLSchemeHandler` is a programmer error | **Confirmed** | Apple doc JSON for `wkusercontentcontroller/add(_:contentworld:name:)`, `wkscriptmessage/frameinfo`, `wkframeinfo/ismainframe`, `wkframeinfo/securityorigin`, `wkwebviewconfiguration/seturlschemehandler(_:forurlscheme:)` |
| 12 | Android `loadDataWithBaseURL` without an http(s) base URL gives origin `"null"`, and the base URL is sent as `Referer`; `onRenderProcessGone` must return true or the app crashes | **Confirmed** | https://developer.android.com/reference/android/webkit/WebView#loadDataWithBaseURL; https://developer.android.com/reference/android/webkit/WebViewClient#onRenderProcessGone |
| 13 | `buildAllowAttribute` joins with `"; "` and includes `clipboard-write`; the spec sample joins with spaces and omits it | **Confirmed** | `EXT/dist/src/app-bridge.js` `function TG`; Stable L1746-1751 |
| 14 | Package versions: ext-apps 2.0.3 latest (2026-09-25), mcp_dart 2.4.3 (2026-10-14), androidx.webkit 1.17.1 stable | **Confirmed** | npm registry; pub.dev API; Google Maven metadata (all queried 2026-10-18) |
