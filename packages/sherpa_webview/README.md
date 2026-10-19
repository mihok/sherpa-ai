# sherpa_webview

The sandboxed host for MCP Apps (`io.modelcontextprotocol/ui`, stable spec
2026-01-26, R03), as a Flutter plugin for Android and iOS. It is Sherpa's
own small WebView (PLAN finding 3). `webview_flutter`'s JavaScript channel
uses `addJavascriptInterface`, which is injected into every frame, so it
is not used.

| Piece | What it is |
|---|---|
| `McpAppView` / `McpAppController` | The chat widget and its state: network consent, the native view, loading and error states, auto-height, inline ↔ fullscreen (the same WebView, moved with a `GlobalKey`), suspend/re-render from stored tool data, and teardown. |
| `McpAppsBridge` | The View protocol (`ui/initialize`, host context, tool data, `tools/call`, `ui/message`, `ui/open-link`, …). It is pure Dart over an injectable `McpAppChannel`. |
| `McpAppCsp`, `DeclaredDomains`, `CspOrigin`, `LinkPolicy`, `McpAppLimits` | Policy. |
| `McpAppResource` | A validated `ui://` resource (mime type, UTF-8 HTML, `_meta.ui`, SHA-256). |
| `package:sherpa_webview/mcp.dart` | sherpa_mcp glue: `loadMcpAppResource`, `mcpRouterAppCallbacks` (`McpToolRouter.executeForApp` / `appToolDefinition`), `mcpToolJson`. |
| `package:sherpa_webview/testing.dart` | `FakeMcpAppChannel` (a scriptable shell) and `FakeMcpAppPlatform` (a widget instead of a WebView). |
| `assets/mcp_app_shell.html` | The trusted shell page. Native code loads it from the app's Flutter assets, never from the network. |

## Architecture

```
Flutter: McpAppView ── McpAppController ── McpAppsBridge ──(McpAppChannel: JSON strings)──┐
                                                                                        Pigeon
Native WebView  [Android: per-server Profile, no file/content access, blockNetworkLoads  │
                 unless consent, 403 for non-consented origins; iOS: nonPersistent store,│
                 block-all WKContentRuleList + consented origins]                         │
 └─ Shell document  https://mcp-view.sherpa.invalid/  (trusted, static asset)  ◄─────────┘
     • CSP <meta> substituted by native (validated; else the no-network default)
     • bridge: Android addWebMessageListener("__sherpaHost", {shell origin});
               iOS handler in a private WKContentWorld, relay script in the main frame only
     • relay: source/origin check, size cap, token bucket, envelope {kind:'view', message}
     └─ <iframe sandbox="allow-scripts" allow="camera 'none'; …" srcdoc="<!DOCTYPE html>
             <meta CSP (same policy)><meta referrer no-referrer><script>prelude</script>VIEW_HTML">
        untrusted View, opaque origin "null"
```

The shell↔native leg is a Sherpa-internal envelope:

- shell → native: `ready {v, cspOk}`, `view {message}`, `frame-loaded`, `stats {forged, malformed, oversized, rateLimited}` and `error {reason}`.
- native → shell: `load {html, limits, theme, title}`, `post {message}`, `context {theme}` and `teardown`.

A View cannot forge an envelope, because the shell wraps everything it relays.

## Threat model

**Adversary.** A malicious or compromised MCP server controls the View's HTML and JS, and every tool result and resource it serves. Content returned by other tools may also be attacker-controlled.

**What the adversary wants, and what stops it:**

| Goal | Stopped by |
|---|---|
| Exfiltrate conversation data or track the user over the network | CSP built only from declared AND consented origins: none by default. Two copies apply: the srcdoc document inherits the shell's policy and gets its own `<meta>` (Chromium-verified). Native backstops: Android `blockNetworkLoads` and 403 interception; the iOS content rule list. `connect-src`/`img-src`/… are separated per the spec, `'self'` is dropped, and there is no `'unsafe-eval'`, no workers and no `frame-src`. `form-action`, `base-uri`, `object-src` and `manifest-src` are all `'none'`. `Origin: null` and no `Referer` on consented requests. |
| Reach the native bridge or shell globals | Opaque origin (no `allow-same-origin`, ever): Android injects the bridge only into frames of the shell origin. iOS keeps the handler in a private content world, and its relay script runs in the main frame only. Native re-checks main frame, origin and size on every message (and on iOS, also the world). The shell accepts only `event.source === iframe.contentWindow` with `origin === "null"`. |
| Read storage, cookies or the shell DOM | Opaque origin: `localStorage`, cookies, IndexedDB, Cache API and service workers all throw. Android uses a per-server WebView profile that is wiped when the server's last view closes, with cookies off. iOS uses a non-persistent store per view. |
| Navigate away, open popups, phish full-screen | Sandbox without `allow-top-navigation`, `allow-popups`, `allow-forms` or `allow-modals`. The shell's `frame-src 'none'` blocks the View navigating itself: at most it lands on the browser's error page, with nothing fetched. Native cancels every navigation except the shell load and `about:srcdoc`/`about:blank` subframes. There are no new windows, downloads or JS dialogs. Host chrome ("Content from <server>", the expand/close buttons) is drawn by Flutter outside the WebView. |
| Run tools without consent | The bridge looks up tools on the View's OWN server only and enforces the spec visibility predicate: `["model"]` and `[]` are refused. It then calls the app's approval callback. The View's `_meta` is never forwarded. `McpToolRouter.executeForApp` re-checks visibility and applies hygiene, schema checks and result limits. |
| Prompt injection via `ui/message` / `ui/update-model-context` | `ui/message` is text only, capped, inserted only after `confirmMessage` returns true, and limited to one prompt at a time. Model context is size-capped and handed to the app, which must wrap it as untrusted app data. |
| Malicious links | `ui/open-link` and plain `<a href>` clicks (reported by the shell prelude) go through `LinkPolicy`: `https:` only by default, with no control or bidi characters and no credentials. Then the user's confirmation, then `launchLink`. Nothing is navigated in place. |
| Device permissions | None granted: the iframe `allow` denies every feature. Android `onPermissionRequest` and geolocation are denied. iOS media capture and motion are denied. |
| DoS of the host | Shell token bucket (burst 64, 32/s; error replies ≤ 10/s), 1 MiB message cap (4 MiB hard), Dart request bucket (20, 10/s), ≤ 4 concurrent tool calls, a 120 s call timeout, log caps, and a 20 s load timeout. The renderer priority is waived. Android `onRenderProcessGone` returns true (the app survives) and the view shows an error. |

**Not in scope / trusted:** the Dart side and the native plugin; the MCP server's own access to data it was sent through `tools/call`; the OS WebView itself.

## What is enforced where

| Control | Shell (JS) | Native | Dart bridge / controller |
|---|---|---|---|
| CSP | Copies its own policy into the View's `<meta>`; refuses to load without a valid policy | Substitutes the policy (`[a-z0-9 :;'*./-]` and required directives, else the default) | Builds it from declared ∩ consented origins |
| Network | — | Android: `blockNetworkLoads` with no consent, 403 for non-allowlisted origins. iOS: content rules | Consent via `requestNetworkAccess` |
| Bridge reachability | `source`/`origin` checks, drops sibling and nested frames | Origin rule + `isMainFrame` (Android); world + `isMainFrame` + `securityOrigin` (iOS) | — |
| Size / rate | 1 MiB per message, token bucket, error replies | Hard string cap | Size re-check, JSON-RPC shape, request bucket, concurrency |
| Navigation | Sandbox flags, `frame-src 'none'` | `shouldOverrideUrlLoading` / `decidePolicyFor` | Links only via confirmation |
| Tool visibility / approval | — | — | Same server, visibility, `approveToolCall`; `executeForApp` re-checks |
| Ordering | — | — | Nothing before `initialized`; partial* → input → result \| cancelled, each once |

### Design decisions

- **Origin.** The shell origin is `https://mcp-view.sherpa.invalid`, loaded with `loadDataWithBaseURL` (Android) or `loadHTMLString` (iOS), with that base URL. It is a real, secure https origin for the bridge's origin rule, with no request at all. So nothing depends on interception, no path handler exists that a View could fetch from, and `blockNetworkLoads` can stay on. `.invalid` is reserved and never resolves, so an escaped request cannot reach anything. `WebViewAssetLoader` was not used: it serves the page through `shouldInterceptRequest`, which the plan says not to rely on.
- **Sandbox.** The iframe is `sandbox="allow-scripts"`, per this task's brief. PLAN §2 says `allow-scripts allow-forms`. Without `allow-forms`, `submit` events never fire, so Views must handle buttons rather than `<form onsubmit>`. Adding `allow-forms` would still be safe, because the inherited `form-action 'none'` blocks submission. This is a product decision.
- **No-consent CSP** (golden: `test/web/fixtures/policies.json`):
  `default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src 'none'; media-src 'none'; connect-src 'none'; frame-src 'none'; child-src 'none'; worker-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; manifest-src 'none'`.
  With consent, `resourceDomains` are added to the script, style, img, font and media directives, and `connectDomains` to `connect-src`. `frameDomains` and `baseUriDomains` are never granted. Origins must be plain `https`/`wss` origins (resource domains `https` only). Paths, keywords, `*`, IP literals, single-label hosts and LAN suffixes (`.local`, `.lan`, `.home`, `.internal`, …) are refused. `hostCapabilities.sandbox.csp` reports exactly what was granted.

## Using it from the app (chat)

A tool result renders as an app when its `ToolResultPart.uiResourceUri` is set. `AgentRunner` fills it from the result's or the tool's `_meta.ui.resourceUri`, and puts the server in `meta[ToolResultPart.metaServerId]`. A stored `UiResourcePart` (`resourceUri`, `serverId`, `callId`) works the same way.

```dart
import 'package:sherpa_webview/mcp.dart';
import 'package:sherpa_webview/sherpa_webview.dart';

final serverId = part.meta[ToolResultPart.metaServerId]! as String;
final McpAppResource resource;
try {
  resource = await loadMcpAppResource(manager, serverId: serverId, uri: part.uiResourceUri!);
} on McpAppResourceException {
  return textFallback(part);                 // servers MUST send meaningful content
}
final wireName = router.lookup(part.meta[ToolResultPart.metaTool] as String? ?? part.toolName)?.wireName;

final controller = McpAppController(
  session: McpAppSession(
    serverId: serverId,
    serverName: manager.config(serverId)!.name,
    resource: resource,
    tool: wireName == null ? null : await mcpToolJson(manager, serverId, wireName),   // toolInfo.tool
    callId: part.callId,
  ),
  callbacks: mcpRouterAppCallbacks(
    router: router, manager: manager, serverId: serverId, sessionId: sessionId,
    // REQUIRED: the approval policy for app-initiated calls. Attribute them:
    // "requested by ${req.identity.label}". Treat them as tainted (untrusted).
    approveToolCall: (req) async {
      final def = req.tool.definition;
      if (def == null) return false;
      return switch (approvalPolicy.evaluate(def, sessionId, tainted: true)) {
        AutoApprove() => true,
        final NeedsConfirmation n => (await approvalHandler.requestApproval(
                sessionId: sessionId, call: ToolCall(id: 'app', name: def.name, arguments: req.arguments),
                tool: def, requirement: n, cancel: CancellationToken())).decision == UserDecision.approve,
        Denied() => false,
      };
    },
    confirmMessage: (req) => showProposedMessageSheet(req),     // show req.text, from req.identity.label
    insertMessage: (req) => chat.sendUserMessage(req.text, fromApp: req.identity),
    confirmOpenLink: (req) => showLinkSheet(req.uri),           // the full URL, host emphasized
    launchLink: (uri) => openInCustomTabOrSafariVC(uri),
    updateModelContext: (ctx) => chat.setAppContext(ctx),       // latest wins; wrap as untrusted
    requestNetworkAccess: (req) => showNetworkConsent(req),     // returns granted CspOrigin.source set
  ),
  hostContext: McpAppHostContext(
    userAgent: 'Sherpa/$version (Android $release)',
    timeZone: ianaTimeZoneFromNative,
    styleVariables: mcpAppStyleVariables(light: lightScheme, dark: darkScheme),
  ),
  grantedOrigins: persistedConsent(serverId, resource.sha256),   // null: ask; {}: offline
);
controller
  ..setToolInput(toolCallPart.call.arguments)                    // or setToolInputPartial while streaming
  ..setToolResultPart(part);                                     // or setToolCancelled(reason)

McpAppView(controller: controller, fallback: Text(part.text));
```

- **Lifecycle.** Own controllers in the chat state, keyed by `callId`. Keep 2–3 live: call `await controller.suspend()` for off-screen Views (this sends `ui/resource-teardown`), and they re-render from the stored data when shown again. Call `await controller.close()` while the widget is still on screen, so the teardown request is delivered. Removing the widget on its own releases the WebView without a teardown.
- **Persist consent** per server plus `resource.sha256`, and ask again when either changes (`McpAppNetworkRequest` carries both).
- **Theme and locale** come from the widget's `Theme` and `Localizations`. Pass styles, user agent and time zone through `hostContext`.
- **Removing a server.** `PigeonMcpAppPlatform.instance.clearServerData(McpAppNativeViewConfig.profileKeyFor(serverId))`.

## Tests

```sh
export PATH=/opt/flutter-sdk/flutter/bin:$PATH
cd packages/sherpa_webview && flutter test --no-pub --concurrency=2   # 73 Dart tests
dart analyze --fatal-infos packages/sherpa_webview                    # from the repo root
packages/sherpa_webview/test/web/run.sh                               # 27 Chromium security tests
dart run tool/csp_fixture.dart     # regenerate CSP goldens (csp_test.dart fails on drift)
```

- **Dart tests:**
  - `bridge_test`: handshake, ordering and buffering, visibility, approval, timeouts, cancellation, links, messages, model context, display modes, rate limits, logs and teardown.
  - `csp_test` and `policy_test`: origin validation, the CSP builder plus goldens, links, the token bucket, resources, JSON-RPC validation, host context and result mapping.
  - `widget_test`: loading, ready, error/retry/fallback, consent, unsupported, load timeout, fullscreen reparenting with no remount, suspend/re-render and teardown.
  - `pigeon_platform_test`: config encoding and message routing over mocked channels.
  - `mcp_adapter_test`: end to end through a real in-process MCP server, `McpServerManager` and `McpToolRouter`.
- **Security suite** (`test/web/security.test.mjs`, Node `node:test` + Playwright and Chromium from `/opt/pw-browsers`; never `playwright install`). It serves the shell at its real origin, injects a fake native bridge the way Android does (only into shell-origin frames, recording `isMainFrame`), logs every request that leaves the renderer and every WebSocket attempt (CDP `Network.webSocketCreated`; Playwright's `routeWebSocket` is an in-page mock that would bypass CSP). It proves:
  - isolation from parent DOM, globals and storage;
  - CSP blocks fetch, XHR, WebSocket, EventSource, images, scripts, styles, fonts, media, frames, workers, beacons and markup loads;
  - srcdoc policy inheritance;
  - consented connect and resource domains work, and nothing else does;
  - forged and nested-frame messages are dropped;
  - size and flood caps apply;
  - `ui/open-link` and anchor clicks arrive as host requests with no navigation;
  - form submission and top/self navigation fail;
  - the iOS relay mode;
  - the real `@modelcontextprotocol/ext-apps` 2.0.3 `App` (vendored bundle) works through the shell under the strict CSP.
- **Kotlin:** JVM tests for `ShellPolicy` (CSP acceptance, shell rendering, bridge checks, navigation, allowlist matching, profile names). They run from any Flutter app that depends on the plugin: `cd <app>/android && ./gradlew :sherpa_webview:testDebugUnitTest :sherpa_webview:lintDebug`.
- **Swift:** `SWIFT_TOOLCHAIN=<swift-6.x-linux>/usr tool/swift_typecheck/check.sh` type-checks the sources against stand-in UIKit, Flutter and WebKit modules. The stand-ins mirror the SDK declarations used, including `@MainActor`. WebKit delegate methods are declared as requirements, so a mistyped witness is an error. There are two Linux-only substitutions: `#if os(iOS)` in the generated file, and the Darwin-only trust constant. The check is clean in Swift 5, Swift 5 with `-strict-concurrency=complete`, and Swift 6 modes. **This is UNVERIFIED against the real iOS SDK.** The first real compile is CI on macOS.

Regenerate Pigeon with `dart run pigeon --input pigeons/webview_api.dart`. Async methods use `@asyncCallback`, so neither kotlinx.coroutines nor Swift concurrency is needed.

## Known gaps (and what is UNVERIFIED)

- **Nothing here ran in a real Android System WebView or WKWebView.** The shell, CSP, sandbox and relay were proven in Chromium 141, which is close to Android WebView but not the same. The Kotlin compiles, lints and passes its JVM tests, and a debug APK builds. Swift was only type-checked on Linux.
- **WebKit specifics (UNVERIFIED):**
  - whether `frame-src 'none'` leaves the `about:srcdoc` child alone (Chromium: yes);
  - whether `postMessage` from the private-world relay reaches the handler;
  - whether content rules apply to `loadHTMLString` main documents and `about:` frames (they are explicitly re-allowed).
- **WebRTC is not covered by CSP**, and Chromium does not implement the CSP `webrtc` directive. The prelude removes `RTCPeerConnection` from the View realm, and native document-start scripts (Android rules `"*"`, iOS all frames) do the same best-effort. A nested frame's own realm still has it (shown by the suite), so STUN/TURN can leak small amounts of data and the device IP. DNS prefetch is turned off with `x-dns-prefetch-control`, but its coverage per engine is UNVERIFIED.
- **`.invalid` and `loadDataWithBaseURL`:** the origin rule matching for this host and the injection of document-start scripts into opaque srcdoc frames are UNVERIFIED in Android WebView.
- **Permissions:** none are granted. Camera, microphone, geolocation and clipboard Views degrade.
- **Not supported:** `ui/download-file`, `sampling/createMessage`, app-provided tools (Draft), `pip`, `frameDomains`/`baseUriDomains`, `ui.domain` (opaque origin: CORS-allowlisted APIs won't work), `'unsafe-eval'`, blob workers (WebGL/Three.js-style Views break), and real storage.
- **Wildcards** like `https://*.co.uk` pass validation; there is no public-suffix list. DNS rebinding of a consented domain to a LAN address is not prevented.
- **Fullscreen** reuses the same WebView through `GlobalKey` reparenting. This is tested with the fake platform view only; on a device the Android hybrid-composition behaviour is UNVERIFIED.
- **`blockNetworkLoads`:** whether it also blocks WebSockets is UNVERIFIED. CSP `connect-src` is the primary control.
- **App-level recommendation:** consider `android.webkit.WebView.MetricsOptOut` in the app manifest. It is app-wide, so the plugin does not set it.
