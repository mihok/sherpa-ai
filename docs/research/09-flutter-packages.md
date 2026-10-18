# 09 — Flutter & Dart package landscape for Sherpa

**Status:** research digest, verified 2026-10-18. Toolchain used: Flutter 3.47.7 (stable), Dart 3.13.5, Android SDK 36/37, AGP 9.1.0 (template default), Kotlin 2.4.0.

**Method.**
- Every version, publish date, publisher, SDK constraint, platform list, pub points and like count below comes from the pub.dev JSON API (`/api/packages/<name>`, `/score`, `/publisher`, `/options`), pulled on 2026-10-18.
- Behaviour claims come from changelogs and READMEs in the published archives (`~/.pub-cache`), plus GitHub, dart.dev, riverpod.dev and modelcontextprotocol.io.
- Load-bearing claims were then tested in throwaway projects under `/tmp/claude-0/flutter-probe/`. The main one is a pub workspace with a Flutter app and a pure-Dart package. It holds about 60 of the packages below and resolves as a unit; `flutter test`, `dart test`, drift codegen, SQLCipher and SQLite3MultipleCiphers encryption, the mcp_dart Streamable HTTP round trip, SSE streaming and a real-font golden were all run in it. A debug APK build was also attempted.
- Anything marked *(reported)* comes from docs or third-party writing and was not run here.

**Legend.**
- **Publisher:** a domain (e.g. `flutter.dev`) means a pub.dev *verified publisher*; "none" means an unverified uploader.
- **Platforms:** A = Android, i = iOS, M = macOS, W = Windows, L = Linux, w = web.
- **Build-system tags** come from the pub.dev score tags. `SPM` means `is:swiftpm-plugin`, `Pods-only` means `is:darwin-legacy-native-build`, and `bK` means `is:built-in-kotlin`.
- **Verdict:** **USE**, **USE (pin)**, **WATCH**, **AVOID**.

---

## 0. Ecosystem shifts in 2026 that change the picks

These are cross-cutting. Several of them changed recommendations that would have been obvious a year ago.

1. **Material and Cupertino were split out into `material_ui` / `cupertino_ui` (flutter.dev).**
   - Contributions to the in-SDK `package:flutter/material.dart` were frozen in Flutter 3.44, and opting into the packages became possible in 3.47. The docs say the in-SDK libraries will be deprecated in an upcoming stable release, without a date *(reported: [docs.flutter.dev breaking change](https://docs.flutter.dev/release/breaking-changes/material-ui-and-cupertino-ui), [flutter.dev blog](https://flutter.dev/blog/flutters-material-and-cupertino-code-freeze))*.
   - Current versions are `material_ui` 1.7.0 and `cupertino_ui` 1.1.3, both published 2026-10-14, with `sdk ^3.13.0` and `flutter >=3.47.0`.
   - **Verified:** `material_ui` defines its *own* `ColorScheme`, `ThemeData`, `MaterialApp` and so on. `dynamic_color` 2.x already returns `material_ui` types, so passing its scheme to a `package:flutter/material.dart` `ThemeData` is a **compile error** (`argument_type_not_assignable` from `dart analyze` in the probe).
   - **Verified by reading the source:** `go_router` 18 detects "MaterialApp" with `findAncestorWidgetOfExactType<MaterialApp>()` using the **material_ui** type. An app built on the legacy `MaterialApp.router` is therefore not recognised, and go_router falls back to its `WidgetsApp` page builder, which has no Material transitions and no HeroController.
   - Most third-party UI packages still import `package:flutter/material.dart`. Packages checked: flutter_markdown_plus, flutter_math_fork, alchemist, mobile_scanner, background_downloader, flutter_riverpod, webview_flutter and qr_flutter.
   - **Consequence for Sherpa:** start on `material_ui` + `cupertino_ui` now, and wrap legacy-package subtrees in `MaterialUiCompatibilityBridge`. Section 10 has the detail.
2. **Swift Package Manager is the iOS default since Flutter 3.44.** CocoaPods is in maintenance mode, and its trunk becomes read-only on **2026-12-02** *(reported: [flutter.dev blog](https://flutter.dev/blog/saying-goodbye-to-cocoapods-swift-package-manager-is-soon-the-default-in-flutter))*. Packages tagged `Pods-only` are now a liability: `flutter_inappwebview` 6.1.5, `share_handler` 0.0.25 and `animated_streaming_markdown`. `receive_sharing_intent` 1.9.0 went the other way and is SPM-only.
3. **Flutter's built-in Kotlin replaces plugins that apply KGP themselves.**
   - **Verified:** `flutter build apk` printed: "Your app uses the following plugins that apply Kotlin Gradle Plugin (KGP): cronet_http, flutter_web_auth_2, home_widget. Future versions of Flutter will fail to build if your app uses plugins that apply KGP."
4. **compileSdk 37 is needed.**
   - **Verified:** the APK build failed `checkDebugAarMetadata` because `receive_sharing_intent` 1.9.0 and `permission_handler_android` 14.1.0 need compileSdk 37. The latter comes in transitively via `live_activities`. The template default is `flutter.compileSdkVersion` = 36.
   - **Verified:** `flutter_local_notifications` additionally requires core-library desugaring.
5. **Native code moved to build hooks.** `package:hooks` 2.x, `code_assets` 2.x and `native_toolchain_c` 0.19 now provide native code. `native_assets_cli` is discontinued, replaced by `hooks`.
   - `sqlite3` 3.x and `cupertino_http` 3.x ship their native code this way and are no longer Flutter plugins.
   - Mixed `code_assets` majors cause silent downgrades. **Verified:** `cupertino_http` 3.1.0 still pins `code_assets ^1.0.0`, which dragged `objective_c` 9.6.2 → 9.5.0, `native_toolchain_c` 0.19.5 → 0.19.3, and capped `ffigen` at 21.0.0 instead of 23.0.0.
6. **Dart 3.13 has primary constructors.** **Verified:** `class Point(final int x, final int y) {…}` compiles and runs on 3.13.5. freezed 4.0.0 dropped `final` inside constructor parameters because Dart 3.13 no longer allows that syntax. Hand-written immutable models are now cheap; see section 12.
7. **MCP's current spec is `2026-07-28`, which is stateless.** The `initialize` handshake is replaced by per-request `_meta` protocol versions and an optional `server/discover` call *(reported: [modelcontextprotocol.io/specification/versioning](https://modelcontextprotocol.io/specification/versioning))*. Section 14 covers which Dart SDKs support it.

---

## 1. Monorepo tooling: pub workspaces vs melos

| Package | Version (published) | Publisher | SDK | Verdict |
|---|---|---|---|---|
| pub workspaces (Dart SDK feature) | Dart ≥ 3.6; globs in `workspace:` need ≥ 3.11 | dart.dev | — | **USE** |
| `melos` | 8.9.0 (2026-09-21) | invertase.io ✔ | ^3.9.0 | **OPTIONAL** (only for release/versioning automation) |

**How pub workspaces work.**
- The root `pubspec.yaml` has `workspace: [app, packages/*]`. Each member has `resolution: workspace` and an SDK constraint of `^3.6.0` or higher.
- `pub get` from any directory resolves the whole set into **one** root `pubspec.lock` and one `.dart_tool/package_config.json`. Stray member lockfiles are deleted.
- **Verified:** "Deleting old lock-file: ./app/pubspec.lock".

**Verified in the probe (Flutter app + pure-Dart package in one workspace).**
- `flutter test` in the app member works: 2 tests, plus a golden.
- `dart test` in the pure-Dart member works, including build hooks.
- `dart run build_runner build` in the member works: drift_dev, first build 57 s, "Built with build_runner/aot".
- `dart pub get` from the root works when `dart` is Flutter's bundled dart.
- The root lockfile marks *every* package `dependency: transitive` (the root has no deps). Tooling that reads "direct" from the lockfile will be confused.

**Gotchas.**

1. **The Flutter SDK's pins leak into pure-Dart packages.**
   - `flutter_test` from Flutter 3.47.7 pins `test_api 0.7.12`, `matcher 0.12.20` and `meta ^1.18.3`. In a shared resolution this holds `test` at 1.31.1 (1.33.0 is out).
   - `test` 1.31.1 requires `analyzer <14`, so the whole workspace sits on analyzer 13.3.0.
   - As a result `build_runner` is held at 2.16.1 (2.17.x needs analyzer ≥ 14.3 and `build` 5). `freezed` is held at 4.0.1 (4.0.2+ requires analyzer 14). **All verified.**
   - Expect codegen packages to lag Flutter-free projects by one analyzer major.
2. **`hooks: user_defines:` are only read from the workspace root `pubspec.yaml`.**
   - **Verified:** the same `sqlite3: source: sqlite3mc` block in a *member* pubspec is **silently ignored**. Plain, unencrypted SQLite is used and `PRAGMA cipher` returns `[]`.
   - This matches dart.dev/tools/hooks ("the workspace `pubspec.yaml` if you use a workspace"). It is a fail-open security trap; see section 2.
3. **One version of every package across the workspace.** `dependency_overrides` can override a package only once, so keep overrides in the root.
4. **CI needs Flutter's `dart`.** A Flutter-free CI job for `packages/*` still has to use the Flutter SDK's dart, because the shared resolution includes `sdk: flutter`. Alternatively, give that member its own resolution through a `pubspec_overrides.yaml` with an empty `resolution:`.
5. **There is no workspace-wide `flutter test`.** Use a small script, or `melos test` / `melos exec`, that runs `flutter test` in `app/` and `dart test` in each package.
6. **The current repo state:** the root pubspec lists only `packages/sherpa_core`. `app/` is *not* yet a workspace member and still has its own `pubspec.lock`. Add it (`workspace: [app, packages/*]`), and give `app/pubspec.yaml` `resolution: workspace`.

**melos.** melos 7.0.0 was "the first stable release of Melos that uses the Pub workspaces feature". It dropped `melos.yaml` in favour of a `melos:` section in the root `pubspec.yaml`, and it runs `pub get` only at the workspace root. 8.x (8.0.0 → 8.9.0, Aug–Sep 2026) adds:
- `melos test`
- `changed`
- script `dependsOn`
- `--post-filter`
- `cherry-pick`
- `markSharedDependencies`

It is real value for versioning, changelogs and publishing, but it adds no dependency-resolution value over native workspaces.

**Verdict:** native pub workspaces now. Add melos 8 only if or when we publish packages or want conventional-commit versioning. A 20-line `tool/each.dart` or Makefile covers test, analyze and format.

---

## 2. Persistence: drift + sqlite3 (+ encryption)

| Package | Version (published) | Publisher | SDK | Platforms | Points / likes | Verdict |
|---|---|---|---|---|---|---|
| `drift` | 2.35.2 (2026-10-07) | simonbinder.eu ✔ | ≥3.10 | A,i,W,L,M,w | 160 / 2482, Flutter Favorite | **USE** |
| `drift_flutter` | 0.3.1 (2026-07-11) | simonbinder.eu ✔ | ≥3.10 | all | 160 / 70 | **USE** (app only) |
| `drift_dev` | 2.35.1 (2026-09-30) | simonbinder.eu ✔ | ≥3.10 | (dev tool) | 110 / 72 | **USE** (dev) |
| `sqlite3` | 3.7.1 (2026-10-13), SQLite 3.54.0 | simonbinder.eu ✔ | ≥3.10 | all | 150 / 465 | **USE** |
| `build_runner` | 2.17.1 (2026-10-14); **2.16.1 resolvable** | tools.dart.dev ✔ | ^3.11 | dev | 160 / 2372 | **USE (pin ^2.16.1)** |
| `sqlite3_flutter_libs` | 0.6.0+eol (2026-02-15) | simonbinder.eu ✔ | — | — | — | **AVOID** (EOL) |
| `sqlcipher_flutter_libs` | 0.7.0+eol (2026-02-15) | simonbinder.eu ✔ | — | — | — | **AVOID** (EOL) |

**How SQLite gets bundled now.**
- In `sqlite3` 3.0.0 the breaking change was: "Use build hooks to load SQLite instead of `DynamicLibrary` … drop your dependencies on `sqlite3_flutter_libs` and `sqlcipher_flutter_libs`." `drift` 2.32.0 and `drift_flutter` 0.3.0 moved to sqlite3 3.x.
- The `sqlite3` build hook **downloads prebuilt binaries from the package's GitHub releases at build time** and verifies them against sha256 values shipped in the pub.dev package.
- Prebuilt platforms are Android (armv7a, aarch64, x86, x64), iOS (device arm64, simulator arm64/x64), macOS, Linux and Windows. The release workflow publishes SLSA-3 attestations and an SBOM.
- **Verified on Linux:** the download landed in `.dart_tool/hooks_runner/shared/sqlite3/build/download-<hash>/libsqlite3.so`, and `sqlite_version()` returned 3.54.0 with FTS5 enabled.
- Default compile options include FTS5, RTREE, math functions, the session extension, `SQLITE_DQS=0` and `SQLITE_TEMP_STORE=2`. They also *omit* the authorizer, progress callback, trace, shared cache and decltype.
- Other user-defines: `url_pattern` lets builds use an internal artifact mirror. `source: source` (with `path: sqlite3.c`) builds from your own amalgamation. `source: system|process|executable` uses an OS or statically linked copy.

**How to get encryption today.** There is no `sqlcipher_flutter_libs` any more. Put this in the **workspace root** pubspec:
```yaml
hooks:
  user_defines:
    sqlite3:
      source: sqlite3mc   # SQLite3MultipleCiphers (default cipher ChaCha20-Poly1305 "sqleet"); or: sqlcipher
```
- **Verified (probe, Linux):**
  - With `source: sqlite3mc`, `PRAGMA cipher` returned `[{chacha20: chacha20}]` and the file header was no longer `SQLite format 3`. Reopening without the key throws, and with `PRAGMA key` it reads back.
  - With `source: sqlcipher`, `PRAGMA cipher_version` returned `4.19.0 community`. That build carries the *older* SQLite 3.53.4, as the docs warn.
  - Drift worked end to end: `NativeDatabase.createInBackground(file, setup: (raw) => raw.execute("PRAGMA key = '…'"))` ran in a background isolate, encrypted the file, rejected a wrong key and accepted the right one.
- `drift_flutter`'s `driftDatabase(name:, native: DriftNativeOptions(setup: (CommonDatabase db) {...}))` is the hook to use in the app.
  - `setup` is **synchronous** and runs in the DB isolate. Read the key from secure storage *before* opening, and capture it as a `String`.
- Licensing is a cost: SQLite3MultipleCiphers and SQLCipher Community have their own licences, and the SQLCipher build links OpenSSL on Android.
- Migrating existing SQLCipher databases to sqlite3mc needs `PRAGMA cipher='sqlcipher'; PRAGMA legacy=4;` before the key. Encrypting an existing plaintext DB needs `VACUUM INTO` plus `PRAGMA rekey` (drift encryption docs).
- **Fail closed.** Because a misplaced `user_defines` block silently yields plaintext (section 1, gotcha 2), the app must, in release builds too, run `PRAGMA cipher` in `setup` and refuse to open if it is empty.

**Codegen.** drift_dev and build_runner ran fine in a workspace member. First build took 57 s; build_runner 2.16 compiles builders AOT. Keep drift as the *only* heavy codegen in the core (section 12).

**Breaking changes to note.**
- drift 2.34.0 uses `BEGIN IMMEDIATE` for transactions.
- drift 2.35.0 removed the `dart:html` `PortToChannel` (web only).
- sqlite3 3.0.0 renamed `SqliteException` parameters and deprecated `dispose()` in favour of `close()`.
- There is a "drift3 preview" in progress (drift changelog, 2.35.3 unreleased). Expect a major within the next year.

---

## 3. Secure storage: flutter_secure_storage

| Version (published) | Publisher | SDK / Flutter | Platforms | Tags | Verdict |
|---|---|---|---|---|---|
| **11.2.0** (2026-09-16) | steenbakker.dev ✔ (repo moved to juliansteenbakker/flutter_secure_storage) | ≥3.8 / ≥3.19 | A,i,W,L,M,w | SPM, bK, 160 pts, 4501 likes | **USE** |

**History.**
- **v10.0.0** rewrote Android "due to the deprecation of Jetpack Security library":
  - `encryptedSharedPreferences` (EncryptedSharedPreferences) was deprecated, with automatic migration via `migrateOnAlgorithmChange`.
  - New defaults: key cipher RSA/ECB/OAEPwithSHA-256andMGF1Padding and storage cipher AES-GCM.
  - `resetOnError` now defaults to true.
  - minSdk 23, Java 17.
  - The iOS and macOS code was merged into `flutter_secure_storage_darwin` (SPM, privacy manifest).
- **v10.1–10.3** added:
  - `storageNamespace`
  - `migrateWithBackup`
  - `useSecureEnclave` (iOS/macOS)
  - `AndroidBiometricType.strongBiometricOnly`
  - `biometricPromptNegativeButton`
- **v11.0.0** (2026-08-06, breaking) removed everything deprecated in v10:
  - `encryptedSharedPreferences`
  - `sharedPreferencesName` (use `storageNamespace`)
  - the RSA PKCS1 and AES-CBC algorithms
  - minSdk raised to 24
  - **Data written with pre-v10 algorithms becomes unreadable unless the app passed through v10 first.**
- **v11.1** added `checkUpgradeStatus()` to detect data lost in a direct major jump.
- **v11.2** added `requireBiometricsPerOperation` and fixed Android biometric hangs, `deleteAll` scoping, and finding items across accessibility levels on Darwin.

**Keychain options.**
- `IOSOptions.accessibility` is a `KeychainAccessibility` value: `passcode`, `unlocked` (**default**), `unlocked_this_device`, `first_unlock` or `first_unlock_this_device`.
- Further options are `accessControlFlags` (`devicePasscode`, `biometryAny`, `biometryCurrentSet`, `userPresence`, `or`/`and`, …), `synchronizable`, `groupId` (app groups, for share extensions and widgets), `useSecureEnclave` and `useDataProtectionKeychain` (macOS).

**For Sherpa.**
- Store the DB key and provider API keys with `first_unlock_this_device`, so background downloads and tasks can open the DB while the phone is locked and the keys never sync to iCloud.
- Store OAuth refresh tokens the same way.
- Use `storageNamespace` on Android.
- Call `checkUpgradeStatus()` on first launch of each new build.
- Being greenfield, we skip the v10 migration concern entirely.

---

## 4. Native interop: pigeon, ffigen, hooks / native_toolchain_c

| Package | Version (published) | Publisher | SDK | Verdict |
|---|---|---|---|---|
| `pigeon` | **29.0.10** (2026-10-15) | flutter.dev ✔ | ^3.11 | **USE** (dev) |
| `ffigen` | 23.0.0 (2026-10-06); **21.0.0 resolvable alongside cupertino_http 3.1.0** | tools.dart.dev ✔ | ≥3.10 | **USE when needed** |
| `hooks` | 2.2.0 (2026-08-18) | dart.dev ✔ | ≥3.10 | **USE** (if we ship C) |
| `code_assets` | 2.1.0 (2026-09-16) | dart.dev ✔ | ≥3.10 | **USE** (with hooks) |
| `native_toolchain_c` | 0.19.5 (2026-09-16) | labs.dart.dev ✔ (labs = pre-1.0) | ≥3.10 | **USE (pin)** |
| `native_assets_cli` | 0.18.0, discontinued → `hooks` | labs.dart.dev | — | **AVOID** |

### pigeon

**Breaking changes and new features.**
- **28.0.0 (breaking):** Kotlin and Swift generators emit `suspend fun` / `async throws` for `@FlutterApi` methods and for `@HostApi` methods annotated `@async`. `@asyncCallback` restores callback style.
- **29.0.0:** experimental direct **FFI (Swift) / JNI (Kotlin)** "native interop" mode.
- **29.0.8:** validation errors where FFI/JNI is unsupported, namely event channels, ProxyApis and sealed classes. Keep those in a separate, channel-based pigeon file.
- **29.0.3:** minimum Flutter 3.41 / Dart 3.11.
- **27.0.0:** generated data classes override `toString`. This conflicts with a custom Swift `description`.

**Supported features.**
- `@EventChannelApi()`: Swift, Kotlin and Dart only.
- `sealed` class hierarchies: Swift, Kotlin and Dart.
- `@ProxyApi()`: generates Dart proxies for native classes, with an InstanceManager and GC. Swift and Kotlin only. webview_flutter's own Android and WebKit layers are built on it.
- `@TaskQueue` (channel mode only).
- Multi-instance channel suffixes.
- Top-level constants (27.3).

**Verified by generating a probe definition with 29.0.10.** The definition had a `@HostApi` with `@async bool loadModel(String)`, a sync `String deviceInfo()`, `@async void startInference(InferenceRequest)`, and an `@EventChannelApi` streaming a `sealed class InferenceEvent` (`TokenEvent` | `DoneEvent`).
- **Dart:** a `class LocalModelApi` with `Future<bool> loadModel(String path)`, `Future<String> deviceInfo()` and `Future<void> startInference(InferenceRequest request)`. The stream is a *top-level function* `Stream<InferenceEvent> inferenceEvents({String instanceName = ''})`.
- **Kotlin:** `interface LocalModelApi { suspend fun loadModel(path: String): Boolean; fun deviceInfo(): String; suspend fun startInference(request: InferenceRequest) }`, plus `abstract class InferenceEventsStreamHandler` with `onListen(p0, sink: PigeonEventSink<InferenceEvent>)` and `register(messenger, handler, instanceName)`.
- **Swift:** `protocol LocalModelApi { func loadModel(path: String) async throws -> Bool; … }`, plus `class InferenceEventsStreamHandler: PigeonEventChannelWrapper<InferenceEvent>`.
- **Gotcha (verified):** "event channel methods must not … contain parameters". To parameterise a stream, start it through a `@HostApi` call that returns an id, then filter the events, or use `instanceName`.

### ffigen
- **23.0.0:** "The YAML configuration format is deprecated and will be removed." Use the programmatic API in `tool/ffigen.dart`: `FfiGenerator(output: Output(dart: DartOutput(path: …)), input: Input(entryPoints: […]), visitors: [Visitor(func: (n) => n.isIncluded = …)])` followed by `await generator.generate()`.
- **22.0.0** was a large breaking overhaul of that Dart API: a `Visitor` pattern, `Headers` renamed to `Input`, and `DartOutput`.
- Generation needs LLVM 18+ on the generating machine.

### hooks / native_toolchain_c
A package ships C by adding `hook/build.dart`:
```dart
await build(args, (input, output) async {
  if (input.config.buildCodeAssets) {
    await CBuilder.library(name: 'x', assetName: 'x.g.dart', sources: ['src/x.c']).run(input: input, output: output);
  }
});
```
- Hooks run on `run`, `build` and `test`, and are cached.
- Only `CodeAsset` is supported; data assets are planned.
- Link hooks and tree-shaking arrived in Dart 3.13.
- Hook packages must be regular `dependencies`, not dev dependencies.

**Sherpa use.** Only if we vendor a C library, for example a tokenizer or llama.cpp. Pigeon covers the Kotlin/Swift plugins.

---

## 5. WebView

| Package | Version (published) | Publisher | SDK / Flutter | Tags | Verdict |
|---|---|---|---|---|---|
| `webview_flutter` | **4.14.1** (2026-07-07) | flutter.dev ✔ | ^3.10 / ≥3.38 | SPM, bK, 4533 likes | **USE** |
| `webview_flutter_android` | 4.14.1 (2026-08-28) | flutter.dev ✔ | ^3.12 / ≥3.44 | bK | **USE** (direct dep for platform APIs) |
| `webview_flutter_wkwebview` | 3.27.0 (2026-10-01) | flutter.dev ✔ | ^3.13 / ≥3.47 | SPM | **USE** (direct dep for platform APIs) |
| `flutter_inappwebview` | 6.1.5 (**2024-10-08**); 6.2.0-beta.3 (2026-02-04) | inappwebview.dev ✔ | ^3.5 / ≥3.24 | **Pods-only** (stable) | **AVOID for now** |

### webview_flutter: verified from the 4.14.1 / 3.27.0 sources

- **Cross-platform API:**
  - `loadHtmlString(html, {baseUrl})`, `loadRequest`, `loadFile`, `loadFlutterAsset`
  - `addJavaScriptChannel(name, onMessageReceived:)` and `removeJavaScriptChannel`
  - `runJavaScript` and `runJavaScriptReturningResult`
  - `NavigationDelegate` with `onNavigationRequest` (returns prevent/navigate), `onPageStarted`, `onPageFinished`, `onProgress`, `onWebResourceError`, `onHttpError`, `onUrlChange`, `onHttpAuthRequest` and `onSslAuthError`
  - `setOnConsoleMessage`, `setOnJavaScriptAlertDialog/Confirm/TextInput`, `setOnPlatformPermissionRequest`, `setUserAgent`, `setBackgroundColor` and `setOverScrollMode`
- **Android-only (`AndroidWebViewController`):**
  - `setOnShowFileSelector`. iOS handles `<input type=file>` natively.
  - `setMixedContentMode`, `setAllowFileAccess`, `setTextZoom`, `setGeolocationEnabled` with permission-prompt callbacks, `setMediaPlaybackRequiresUserGesture`, and the static `enableDebugging`.
- **iOS-only (`WebKitWebViewController`):** `setInspectable`, `setAllowsBackForwardNavigationGestures` and `setAllowsLinkPreview`.
- **Android subresource interception is not possible.** `WebViewClientProxyApi` implements `shouldOverrideUrlLoading` but **not** `shouldInterceptRequest`. The term only appears in a doc comment on `WebResourceRequest`.
- **iOS has no `WKContentRuleList` or `WKURLSchemeHandler`.** There are zero occurrences in the generated WebKit bindings.
- **Escape hatch.** Both controllers expose `webViewIdentifier`. In our own Kotlin or Swift plugin we can fetch the native view:
  - Android: `WebViewFlutterAndroidExternalApi.getWebView(engine, id)`
  - iOS: `FWFWebViewFlutterWKWebViewExternalAPI.webView(forIdentifier:withPluginRegistrar:)`
  - On iOS this lets us compile a `WKContentRuleListStore` list and add it to `configuration.userContentController`; that call works after creation.
  - On Android we would have to replace the `WebViewClient`, which breaks the plugin's `NavigationDelegate`. Don't.
- **Security notes.**
  - `JavaScriptChannel` messages carry no origin or frame info in the Dart API. On Android the channel is reachable from *every* frame.
  - Treat every channel message as untrusted input, and prefer a single channel carrying a versioned JSON envelope plus a per-load nonce.

**Recommended pattern for agent-generated HTML artifacts.**
1. Inject a strict CSP `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: blob:; style-src 'unsafe-inline'; script-src 'nonce-…'">` and `loadHtmlString` with an opaque `baseUrl`. This blocks network on both platforms without interception.
2. Use `onNavigationRequest` to block top-level navigations, sending external links to the system browser.
3. For multi-file artifacts, serve from a loopback `shelf` server inside the app, which requires `NSAllowsLocalNetworking`.

### flutter_inappwebview
It has everything webview_flutter lacks:
- `shouldInterceptRequest` (Android)
- `contentBlockers`, which map to `WKContentRuleList` on iOS and are emulated on Android
- `addWebMessageListener` (verified present in `flutter_inappwebview_platform_interface` 1.3.0+1)

But its status is weak:
- The last stable release is from **October 2024**.
- 6.2.0-beta.3 (Feb 2026) is the only 2026 release.
- The last commit on `master` is 2026-02-10.
- It is Pods-only in stable while CocoaPods goes read-only in December 2026.
- Forks are appearing; `flutter_inappwebview_fx` is already marked discontinued on pub.dev.

**Verdict:** don't take it as a core dependency in 2026. Revisit only if per-request interception turns into a hard requirement. Otherwise write a small own plugin through the external-API hook above.

---

## 6. Background downloads (model weights, attachments)

| Package | Version (published) | Publisher | SDK / Flutter | Tags | Verdict |
|---|---|---|---|---|---|
| `background_downloader` | **9.6.4** (2026-10-07), very active (≈ weekly) | bbflight.com ✔ | ^3.13 / **≥3.47** | SPM, bK, 160 pts | **USE** |

From the 9.6.4 README, docs and changelog:
- **iOS** uses a background `URLSession`. **Android** uses WorkManager `DownloadWorker`, or a `JobService` UIDT (user-initiated data transfer) on Android 14+ when `priority: 0` / `TransferHint.userInitiated` is set.
- **Pause and resume** work for GET requests when `allowPause: true` and the server supports `Range`.
- On Android, plain WorkManager tasks are capped at 9 minutes. `allowPause` / `TransferHint.largeFile` chains automatic pause/resume cycles past this; UIDT avoids it.
- `retries` (1–10) use exponential backoff and resume rather than restart when possible.
- **`requiresWiFi`:** on Android 9+ this is a real `TRANSPORT_WIFI` constraint (unmetered on older versions). On iOS it sets `allowsCellularAccess=false`. A global `FileDownloader().requireWiFi(...)` override also exists.
- **Progress and status** are available as streams or callbacks, or through the new 9.6.0 **Transfer API** (`FileDownloader().transfers.start(task)` with awaitable `transfer.file`, `pause()`, `resume()`, `cancel()`, `holdReasonNotifier`, and `stallTimeout`).
- **Parallel chunked downloads:** `ParallelDownloadTask(urls: [...mirrors], chunks: 4)`. On Android these are child workers; on iOS, multiple URLSessionTasks are stitched together. They are not supported with URIs or Android UIDT.
- An optional notification integration and a task database are included.
- **No checksum or hash verification.** A grep of lib, docs and README for checksum/sha256/md5/digest found nothing. Sherpa must verify SHA-256 itself, streaming with `package:crypto` `sha256.startChunkedConversion` over the file after completion. Keep expected hashes in the model manifest.
- **9.6.1 adds `BDPlugin.onNativeTaskStatusChange` / `onNativeTaskProgressChange` in Swift.** This is useful for driving a Live Activity while the Dart isolate is suspended.

---

## 7. Auth and deep links

| Package | Version (published) | Publisher | SDK / Flutter | Tags | Verdict |
|---|---|---|---|---|---|
| `flutter_web_auth_2` | **5.1.0** (2026-08-12); 6.0.0-alpha.8 (2026-09-08) | femtopedia.de ✔ | ≥3.5 / ≥3.24 | SPM, **no bK (KGP warning)** | **USE (5.1.0), watch 6.0** |
| `app_links` | **7.2.2** (2026-10-06) | cow-level.ovh ✔ | ^3.12 / ≥3.44 | SPM, bK, 1324 likes | **USE** |

**flutter_web_auth_2.**
- It uses `ASWebAuthenticationSession` on iOS 12+ and macOS 10.15+, and **Chrome Auth Tab** on Android.
- If the callback is `https`, `httpsHost` and `httpsPath` are required on Android.
- `preferEphemeral` is supported; for Chrome < 141 it falls back to a legacy implementation.
- The 6.0 alphas add:
  - Flutter 3.44 / Dart 3.12 minimums
  - iOS UIScene lifecycle
  - richer iOS errors
- It pulls `desktop_webview_window` and `window_to_front` for desktop. They are harmless on mobile but add to the lockfile.
- Use it for MCP OAuth (PKCE, authorization code) and for provider OAuth.

**app_links.**
- It handles Universal Links, App Links and custom schemes, with `uriLinkStream` and the initial link.
- 7.2.2 fixed links received before the first listen and stopped resending the launch link on activity rebuild.
- It does not conflict with flutter_web_auth_2 when the auth callback scheme differs from the deep-link scheme. Keep them different.

---

## 8. QR: scanning and generating

| Package | Version (published) | Publisher | Tags | Verdict |
|---|---|---|---|---|
| `mobile_scanner` | **7.4.2** (2026-09-14) | steenbakker.dev ✔ | SPM, bK, 2306 likes | **USE** |
| `qr_flutter` | 4.1.0 (**2023-05-14**) | theyakka.com ✔ | holds `qr` at 3.0.2 (4.0.0 out) | **USE (pin), low-maint** |
| `pretty_qr_code` | 3.6.0 (2026-01-31) | none (unverified) | — | alternative |

**mobile_scanner.**
- 7.0.0 moved Apple platforms to the Vision API (iOS 12+), removed `EncryptionType.none`, and changed the `errorBuilder` / `placeholderBuilder` signatures.
- **Android uses Google ML Kit.** The bundled model adds 3–10 MB. The alternative is unbundled via Play Services (`dev.steenbakker.mobile_scanner.useUnbundled=true`).
- Either way it is proprietary Google code, which is an issue for F-Droid builds (see the open questions).

**qr_flutter.** It is stale but simple and works. Only generation is needed (pairing QR); revisit if it breaks.

---

## 9. Markdown, syntax highlighting, math

### Markdown

| Package | Version (published) | Publisher | Notes | Verdict |
|---|---|---|---|---|
| `flutter_markdown` | 0.7.7+1 (2025-05-06) | flutter.dev | **Discontinued, `replacedBy: flutter_markdown_plus`** (pub.dev `/options`) | **AVOID** |
| `flutter_markdown_plus` | 1.0.12 (2026-07-10) | foresightmobile.com ✔ | Continuation of flutter_markdown on `package:markdown` 7.3.1. Adds `selectable` + `contextMenuBuilder`, `MarkdownElementBuilder` builders, `noScroll`, and goldens. Imports legacy `flutter/material`. 850k dl/30d | **USE as fallback / for static docs** |
| `markdown_widget` | 2.3.2+8 (2025-04-26) | morn.fun ✔ | Uses the dead `flutter_highlight`. 9k dl/30d | **AVOID** |
| `gpt_markdown` | 1.3.4 (2026-10-08) | useval.io ✔ | Own regex parser, not `package:markdown`. LaTeX and highlighting via brand-new `val_latex_flutter` 0.1.x and `val_highlight_flutter` 0.1.0 (both first published Oct 2026). Four releases in 5 days | **WATCH** (too much churn) |
| `flutter_streaming_text_markdown` | 1.11.1 | dilacode.com ✔ | Typewriter effect layered on gpt_markdown | **AVOID** |
| `hyper_render`, `flutter_markdown_stream`, `streamdown`, `flutter_smooth_markdown`, `streaming_markdown` | various 2026 | mixed; several unverified | ≤ 20 likes, < 4k dl/30d each | **AVOID** |
| `markdown` (dart-lang parser) | **7.3.1** (2026-03-18) | tools.dart.dev ✔ | CommonMark + `ExtensionSet.gitHubFlavored`, AST `Node` / `Element` / `Text`, `BlockSyntax` / `InlineSyntax` extension points. Pure Dart. **No incremental parsing** | **USE (core)** |

**Recommendation: build our own streaming renderer on `package:markdown`.**
- LLM output arrives token by token. Re-parsing the whole message on every token is O(n²) and makes the widgets flicker.
- The proven approach:
  1. Split the buffer into *closed* blocks and one *open tail*. The boundary is a blank line outside a fenced code block, list or table.
  2. Parse closed blocks once and cache them by content hash.
  3. Re-parse only the tail on each delta, and render it with "unclosed-fence tolerant" fallbacks: an open ``` renders as a code block, and an open `**` renders literally.
- Doing this in `sherpa_core` as pure Dart makes it unit-testable. The Flutter side maps the AST to our own widgets, so there is no legacy-Material dependency.
- `flutter_markdown_plus` can render non-streaming content such as settings help text until then.

### Syntax highlighting

| Package | Version (published) | Publisher | Notes | Verdict |
|---|---|---|---|---|
| `re_highlight` | 0.0.3 (2024-02-05) | reqable.com ✔ | highlight.js port. **197 languages, 74 themes** in the archive. Deps are only `path` and `collection`. Used by `re_editor` (0.10.0, 2026-07) | **USE (pin)**, low-maint but stable API |
| `flutter_highlight` / `highlight` | 0.7.0 (**2021**) | none (unverified) | Dead since 2021 | **AVOID** |
| `syntax_highlight` | 0.5.0 (2025-08-19) | serverpod.dev ✔ | TextMate grammars, async init, few languages. **Depends on `super_clipboard` (Rust native)** | **AVOID** |
| `val_highlight_flutter` | 0.1.0 (2026-10-01) | useval.io ✔ | Brand new | **WATCH** |

Run highlighting off the UI thread for big blocks, using `Isolate.run` on the token list, and only after the code fence closes.

### Math

| Package | Version (published) | Publisher | Notes | Verdict |
|---|---|---|---|---|
| `flutter_math_fork` | 0.7.4 (2025-05-21) | simpleclub.com ✔ | KaTeX-style layout in pure Flutter. Deps: `flutter_svg`, `provider`, `tuple`. The last releases only add "support for flutter 3.x" | **USE (pin)**, maintenance-only |
| `latext` | 0.5.1 (2025-05-23) | djade.net ✔ | Thin wrapper over flutter_math_fork for inline `$…$` | **AVOID** (do it in our parser) |
| `val_latex_flutter` | 0.1.3 (2026-10-10) | useval.io ✔ | Brand new | **WATCH** |

---

## 10. State management and routing

| Package | Version (published) | Publisher | SDK / Flutter | Verdict |
|---|---|---|---|---|
| `flutter_riverpod` / `riverpod` | **3.4.3** (2026-09-03) | dash-overflow.net ✔ | ^3.12 / ≥3.0 | **USE (no codegen)** |
| `riverpod_annotation` / `riverpod_generator` | 4.0.7 / 4.0.9 | dash-overflow.net ✔ | ^3.12 | **AVOID for now** (codegen optional) |
| `riverpod_lint` | 3.1.9 | **none (unverified)** | ≥3.13.0-0 | optional |
| `provider` | 6.1.5+1 (2025-08-19) | dash-overflow.net ✔ | — | **AVOID** (maintenance mode; same author recommends Riverpod) |
| `signals` / `signals_flutter` | 7.1.0 (2026-05-29) | rodydavis.com ✔ | ^3.5 | **AVOID** (fine library; smaller ecosystem, 26k dl/30d) |
| plain `ValueNotifier` / `ChangeNotifier` | SDK | — | — | **USE inside widgets** |
| `go_router` | **18.1.0** (2026-10-14) | flutter.dev ✔ | ^3.12 / ≥3.44 | **USE** |
| `material_ui` / `cupertino_ui` | 1.7.0 / 1.1.3 (2026-10-14) | flutter.dev ✔ | ^3.13 / ≥3.47 | **USE** |

### Riverpod 3.x facts

These are from riverpod.dev's 3.0 migration and what's-new pages. The no-codegen usage was **verified** in the probe, including `flutter test` with `ProviderContainer.test()`.
- **`Ref` lost its type parameter.** All `Ref` subclasses are gone. `ProviderRef.state` moved to `Notifier.state`, `listenSelf` to `Notifier.listenSelf`, and `FutureProviderRef.future` to `AsyncNotifier.future`.
- **AutoDispose interfaces were removed.** `AutoDisposeNotifier` is just `Notifier`, and so on.
- **Family notifier variants were removed.** The argument moves from `build` to the constructor.
- **Failures are wrapped** in `ProviderException`. `AsyncValue.error` users don't need to change anything.
- **All providers filter updates with `==`.** Previously some used `identical`, which mainly affects streams.
- **Automatic retry is on by default** with exponential backoff. Configure `retry` on `ProviderScope` or `ProviderContainer`, or per provider. **Sherpa should disable it globally.** Failing network calls belong to the agent loop's own retry policy, not a UI-layer silent retry.
- **Out-of-view listeners are paused** (TickerMode). There is no global opt-out.
- **Using a disposed `Ref` throws** `UnmountedRefException`. Guard with `ref.mounted` after `await`.
- `StateProvider`, `StateNotifierProvider` and `ChangeNotifierProvider` moved to `package:flutter_riverpod/legacy.dart`.
- **Experimental, not stable:** offline persistence (`riverpod_sqflite`) and `Mutation`s. Avoid both.
- **Codegen is optional.** The only codegen-only features are generic providers and statically safe scoping.

### Recommendation for a "boring and testable" team

1. **Keep all real state and logic in `sherpa_core`, which has no Flutter and no Riverpod.** Use plain Dart classes exposing `Stream`s and immutable snapshots: the agent loop, session store, tool registry and download manager.
2. **In the app, use Riverpod 3 *without codegen* purely as dependency injection plus async-state adapters.**
   - One `Provider` per core service.
   - `StreamProvider` / `AsyncNotifierProvider` wrap the core streams.
   - `NotifierProvider` handles UI-only state.
   - `overrideWithValue` / `ProviderContainer.test()` make tests trivial.
   - Disable `retry`.
3. **Use `ValueNotifier` for ephemeral widget-local state** such as text-field focus and expand/collapse.
4. **Lint:** `riverpod_lint` is optional; its publisher is unverified, and it pins `sdk >=3.13.0-0`.

### go_router 18
- 18.0.0 "migrates to material_ui and cupertino_ui" and requires Flutter 3.44 / Dart 3.12.
- 17.0.0 changed ShellRoute to notify observers, adding `notifyRootObserver`.
- 17.5 added route `metadata`.
- **Use `material_ui`'s `MaterialApp.router`, or go_router won't detect a Material app** (section 0, item 1).
- Typed routes (`go_router_builder`) need build_runner. Skip them and use string paths with constants.

### material_ui migration
1. Run `dart fix --apply --code=migrate_design_widgets`.
2. Use `GlobalMaterialLocalizations.delegates` from material_ui.
3. Wrap legacy-package subtrees in `MaterialUiCompatibilityBridge`, or put it once in `MaterialApp.builder`.

---

## 11. Device and platform plugins

All of these resolved together in the probe workspace on Flutter 3.47.7.

| Package | Version (published) | Publisher | Flutter min | Tags | Verdict / notes |
|---|---|---|---|---|---|
| `speech_to_text` | 7.5.0 (2026-09-14); 7.6.0-beta.4 | csdcorp.com ✔ | ≥3.44 | SPM, bK | **USE.** Platform recognisers: Android `SpeechRecognizer`, iOS `SFSpeechRecognizer`. Offline only where the OS has offline language packs. `SpeechListenOptions` since 6.6 |
| `record` | 7.1.2 (2026-10-09) | cow-level.ovh ✔ | ≥3.44 | SPM, bK | **USE.** `startStream(RecordConfig(encoder: AudioEncoder.pcm16bits))` for streaming to STT or realtime APIs. 7.1.0 clamps the config to device capabilities and reports it via `onConfigChanged` |
| `image_picker` | 1.2.4 (2026-10-06) | flutter.dev ✔ | ≥3.41 | SPM, bK | **USE** |
| `file_picker` | 13.1.0 (2026-09-15) | victorcarreras.dev ✔ | ≥3.38 | SPM, bK | **USE.** **13.0.0 breaking:** removed `allowMultiple`, `withData`, `withReadStream` and `lockParentWindow`, and `PlatformFile.length()` now returns `Future<int?>`. 12.0 was a federated rewrite |
| `share_plus` | 13.3.1 (2026-10-01) | fluttercommunity.dev ✔ | ≥3.38.1 | SPM, bK, FF | **USE** (`SharePlus.instance.share(ShareParams(...))`) |
| `receive_sharing_intent` | **1.9.0** (2026-06-24) | kasem.dev ✔ | ≥3.38 | **SPM-only on iOS**, bK | **USE.** 1.9.0 is breaking: requires a SceneDelegate (UIScene), SPM only, iOS 13+, and a rebuilt Share Extension UI. **Needs compileSdk 37** (verified) |
| `share_handler` | 0.0.25 (2025-07-29) | shoutsocial.com ✔ | ≥2.0 | **Pods-only**, no bK | **AVOID** (CocoaPods sunset) |
| `quick_actions` | 1.1.1 (2026-09-09) | flutter.dev ✔ | ≥3.38 | SPM, bK | **USE** |
| `home_widget` | 0.10.0 (2026-09-17) | antonborri.es ✔ | ≥3.38.1 | SPM, **KGP warning** | **USE (v1.x of app).** 0.10.0 is breaking (custom fonts and icons, widget previews). Widget UI is still native (SwiftUI / Glance or XML) |
| `live_activities` | 2.6.0 (2026-09-11) | dimitridessus.fr ✔ | ≥3.44 | SPM, bK | **USE if we ship Live Activities.** iOS 16.1+ ActivityKit; Android RemoteViews. Pulls `permission_handler` (→ compileSdk 37) |
| `flutter_local_notifications` | 22.3.2 (2026-10-12); 23.0.0-dev.4 | dexterx.dev ✔ | ≥3.38.1 | SPM, bK, FF | **USE.** **Requires core-library desugaring** on Android (verified build error) |
| `flutter_foreground_task` | 11.0.3 (2026-09-07) | pravera.me ✔ | ≥3.44 | SPM, bK | **USE (Android).** Declare `foregroundServiceType` (`dataSync` / `specialUse`). Android 15 caps `dataSync` at 6 h per 24 h. On iOS it is only about 30 s every ~15 min, so don't rely on it there |
| `device_info_plus` | 13.3.0 (2026-10-01) | fluttercommunity.dev ✔ | ≥3.38.1 | SPM, bK, FF | **USE** |
| `battery_plus` | 7.1.2 (2026-10-01) | fluttercommunity.dev ✔ | ≥3.22 | SPM, bK, FF | **USE.** Its Linux deps (`upower` → `dbus` 0.7) hold `connectivity_plus` at 7.3.1 (verified) |
| `connectivity_plus` | 7.3.2 (2026-10-01); **7.3.1 resolvable** with battery_plus | fluttercommunity.dev ✔ | ≥3.7 | SPM, bK, FF | **USE ^7.3.1.** Reports interface type only, not reachability |
| `path_provider` | 2.1.6 (2026-06-15) | flutter.dev ✔ | ≥3.38 | FF | **USE** |
| `dynamic_color` | 2.1.0 (2026-08-20) | material.io ✔ | — | SPM, bK | **USE only with `material_ui`.** 2.0.0 migrated to material_ui (type clash verified). Android 12+ only; iOS is a no-op |

Flag: `FF` = Flutter Favorite.

---

## 12. Utilities: ids, crypto, serialization, logging, HTTP

| Package | Version (published) | Publisher | Verdict / notes |
|---|---|---|---|
| `uuid` | 4.6.0 (2026-07-15) | yuli.dev ✔ | **USE.** v4 and **v7** (`Uuid().v7()`, time-ordered, good as DB keys) |
| `crypto` | 3.0.7 (2025-11-04) | dart.dev ✔ | **USE.** SHA-256 / HMAC, including chunked conversion for file hashes |
| `cryptography` (+ `cryptography_flutter`) | 2.9.0 / 2.3.4 (2025-11-21) | dint.dev ✔ | **USE only if needed.** AEAD (AES-GCM, ChaCha20-Poly1305), X25519, Ed25519, Argon2id. Releases resumed in Nov 2025 after a two-year gap (2.7.0 Sep 2023 → 2.8.0 Nov 2025) |
| `json_serializable` / `json_annotation` | 6.14.1 / 4.12.0 | google.dev ✔ | **USE sparingly.** Only for large provider wire DTOs |
| `freezed` / `freezed_annotation` | 4.0.3 (2026-10-17) / 3.1.0 | dash-overflow.net ✔ | **AVOID.** Analyzer coupling: 4.0.2+ needs analyzer 14, and the workspace is stuck on 13 (verified, resolved 4.0.1). Primary constructors + sealed classes + records cover most of it |
| `dart_mappable` | 4.10.0 | schultek.dev ✔ | **AVOID** (another codegen stack) |
| `logging` | 1.3.0 (2024-10-17) | dart.dev ✔ | **USE.** Hierarchical `Logger`, root listener into our own sink or ring buffer. Stable, zero-dep |
| `http` | 1.6.0 (2025-11-10) | dart.dev ✔ | **USE** as the core's only HTTP abstraction (`http.Client`). 1.5.0 added aborting requests. **1.6.0 is breaking:** `Request.body` adds a charset only for text and XML types |
| `cupertino_http` | 3.1.0 (2026-09-03) | dart.dev ✔ | **USE on iOS.** NSURLSession: HTTP/3, system proxy/VPN, `CupertinoWebSocket`. **3.x is hooks/FFI-based, not a plugin**, and pins `code_assets ^1` (downgrade cascade verified) |
| `cronet_http` | 1.10.0 (2026-09-29) | dart.dev ✔ | **WATCH.** Needs Play Services, or `--dart-define=cronetHttpNoPlay=true` for embedded Cronet. **Verified:** the debug APK build **failed** manifest merge under AGP 9.1.0 with "Namespace 'org.chromium.net' is used in multiple modules … cronet-api, cronet-shared 141.7340.3", and it also triggers the KGP warning. Use the default `IOClient` on Android for now |
| `ok_http` | 0.1.0 (2024-08-05) | none (unverified) | **AVOID** |
| `shelf` / `shelf_router` | 1.4.3 / 1.1.5 (both 2026-10-16) | tools.dart.dev ✔ | **USE (dev)** for fake LLM/MCP servers in tests |

**Serialization recommendation.**
- Hand-write the core domain types: messages, content blocks, tool calls and events. Use `sealed class` hierarchies with primary constructors, explicit `toJson` / `fromJson`, and pattern-matching `switch`.
- Golden-JSON test them. These are the types we must keep stable across provider APIs and persisted sessions, so explicit code beats generated code for review and migration.
- Allow `json_serializable` only for large third-party DTO surfaces.

**Streaming HTTP.**
- **Verified:** a `shelf` handler emitting SSE chunks at 200 ms intervals arrived incrementally through `http.Client().send()` → `StreamedResponse.stream`, at t = 113, 292 and 492 ms.
- The core should accept an injected `http.Client`.
- `package:http`'s `runWithClient(() => …, () => CupertinoClient.defaultSessionConfiguration())` makes even third-party code that calls `http.Client()` use the native stack. **Verified with mcp_dart:** 3 requests went through the injected client.

---

## 13. Testing

| Package | Version (published) | Publisher | Verdict / notes |
|---|---|---|---|
| `flutter_test` `matchesGoldenFile` | SDK | flutter.dev | **USE.** **Verified:** load real fonts in `test/flutter_test_config.dart` via `FontLoader('Roboto')..addFont(...)`, set `tester.view.physicalSize` and `devicePixelRatio`, then `--update-goldens`. The re-run passed and the PNG shows real Roboto glyphs |
| `alchemist` | 0.14.1 (2026-10-08) | betterment.dev ✔ | **OPTIONAL.** "CI goldens" use Ahem (boxes) for cross-OS stability, plus "platform goldens". Its `theme` is a legacy `ThemeData`, which causes friction with material_ui |
| `golden_toolkit` | 0.15.0, **discontinued** | ebay.com | **AVOID** |
| `integration_test` | SDK (`sdk: flutter`). The pub.dev package 1.0.2+3 is **discontinued** | flutter.dev | **USE the SDK one** |
| `patrol` | 4.10.0 (2026-09-15) | leancode.co ✔ | **OPTIONAL** for native dialogs, permissions and notifications in E2E |
| `mocktail` | 1.0.5 (2026-04-10) | felangel.dev ✔ | **USE.** No codegen. Prefer hand-written fakes for core interfaces |
| `mockito` | 5.8.1 | dart.dev ✔ | **AVOID** (needs build_runner) |
| `test` | 1.33.0 latest; **1.31.1 resolvable** in a Flutter workspace | dart.dev ✔ | **USE ^1.31.1** |
| `fake_async` / `clock` | 1.3.3 / 1.1.3 | dart.dev / tools.dart.dev ✔ | **USE** for timeouts, retries and backoff in the agent loop |

**Golden policy.**
- Pixel goldens only run on one pinned CI image (Linux) with bundled fonts. Use `tags: ['golden']` and skip elsewhere.
- Use widget tests with `find.*` for the rest.
- flutter_markdown_plus itself skips its goldens on unpinned CI for the same drift reason.

---

## 14. MCP SDKs for Dart

| Package | Version (published) | Publisher | Spec support | Streamable HTTP client | OAuth | Elicitation / sampling / tasks | Verdict |
|---|---|---|---|---|---|---|---|
| `mcp_dart` | **2.4.3** (2026-10-14) | leehack.com ✔ (personal account) | **2026-07-28 (stateless, default `McpProtocol.stable`)** plus 2025-11-25, 06-18, 03-26, 2024-11-05, 2024-10-07 | **Yes** (`StreamableHttpClientTransport`, reconnection options, resumable SSE) | **Yes, client side.** Protected-resource and AS metadata discovery, **PKCE S256 enforced**, client-ID metadata documents, dynamic registration, `oauthUriValidator` for cross-origin AS | **Yes.** `elicitation/create` (form + URL), sampling, `TaskClient` | **ADOPT (pinned, behind our own interface)** |
| `dart_mcp` | 0.5.2 (2026-06-29) | labs.dart.dev ✔ | ≤ **2025-11-25** | **No.** stdio or any `StreamChannel` only | **No** | Elicitation (form + URL) and sampling yes; tasks no | **AVOID for Sherpa** ("still experimental"; built for Dart tooling) |
| `mcp_client` | 3.0.0 (2026-10-13) | makemind.dev ✔ | Claims through 2026-07-28, but source says the stateless version is "NOT yet in supportedVersions" | Yes | Yes | Yes | **AVOID** (8 likes, 2.7k dl/30d) |

### mcp_dart assessment

**Quality signals.**
- About 45k LOC in `lib/`.
- Runtime dependencies are only `crypto`, `http` and `meta`.
- Dart ≥ 3.4, all platforms including web.
- A `test/` tree with conformance and interop suites. The README claims it passes the official conformance sets for 2025-11-25 and 2026-07-28, including "all 25 required 2026 authorization scenarios", and interop with the TypeScript 2.2.0 and Python 2.3.0 SDKs *(reported, not re-run)*.
- Published security, dependency and versioning policies.
- On GitHub: 116 stars, 33 forks, 1 open issue and 1 open PR.

**Verified round trip.**
- An in-process `StreamableMcpServer` with one tool, and `McpClient` + `StreamableHttpClientTransport`, negotiated **"Protocol: 2026-07-28"** via `server/discover`.
- `listTools` and `callTool` both worked.

**Weaknesses.**
- Single maintainer on a personal account; it is pursuing MCP SDK "Tier 1" but has not been granted it.
- `StreamableHttpClientTransport` hard-codes `http.Client()`. It is still injectable with `http.runWithClient` (verified).
- Noisy default logging: INFO and DEBUG lines go to stdout during the test.
- A large API surface with deprecation churn between 2.2 and 2.3.

**Could Sherpa adopt it instead of writing its own client?** Yes, as the **transport and protocol engine**, behind a narrow `McpConnection` interface in `sherpa_core`:
- connect
- list/call tools
- resources/prompts
- elicitation and sampling callbacks
- auth hooks

This saves us implementing the 2026 stateless negotiation, legacy fallback, SSE resumption and the OAuth discovery maze, which is the riskiest part to hand-roll. Keep a contract-test suite against our interface, using shelf/mcp_dart fake servers, so we can fork it or swap it out if maintenance stalls.

---

## Final pinned dependency table

All rows marked ✔ resolved **together** in one pub workspace on Flutter 3.47.7 / Dart 3.13.5 (probe, 2026-10-18). Where the newest version was not resolvable, the resolvable one is pinned and the reason is given. Use caret constraints in pubspecs and commit the single root `pubspec.lock`.

| Package | Where | Constraint | Locked (probe) | Notes |
|---|---|---|---|---|
| *(workspace)* | root | `workspace: [app, packages/*]` | — | `hooks.user_defines.sqlite3.source: sqlite3mc` **must live here** |
| material_ui | app | ^1.7.0 | 1.7.0 ✔ | adopt from day one |
| cupertino_ui | app | ^1.1.3 | 1.1.3 ✔ | |
| flutter_riverpod | app | ^3.4.3 | 3.4.3 ✔ | no codegen; `retry` disabled |
| go_router | app | ^18.1.0 | 18.1.0 ✔ | needs material_ui `MaterialApp` |
| drift | core | ^2.35.2 | 2.35.2 ✔ | |
| sqlite3 | core | ^3.7.1 | 3.7.1 ✔ | sqlite3mc via root user_defines |
| drift_flutter | app | ^0.3.1 | 0.3.1 ✔ | `DriftNativeOptions.setup` → `PRAGMA key` |
| drift_dev | core (dev) | ^2.35.1 | 2.35.1 ✔ | |
| build_runner | core (dev) | ^2.16.1 | 2.16.1 ✔ | 2.17.x blocked (analyzer 14 / build 5) |
| flutter_secure_storage | app | ^11.2.0 | 11.2.0 ✔ | `first_unlock_this_device` |
| pigeon | plugin pkgs (dev) | ^29.0.10 | 29.0.10 ✔ | channel mode; FFI/JNI experimental |
| webview_flutter (+_android, _wkwebview) | app | ^4.14.1 / ^4.14.1 / ^3.27.0 | ✔ | CSP + loadHtmlString |
| background_downloader | app | ^9.6.4 | 9.6.4 ✔ | own SHA-256 verify |
| flutter_web_auth_2 | app | ^5.1.0 | 5.1.0 ✔ | KGP warning; track 6.0 |
| app_links | app | ^7.2.2 | 7.2.2 ✔ | |
| mobile_scanner | app | ^7.4.2 | 7.4.2 ✔ | ML Kit (not FOSS) |
| qr_flutter | app | ^4.1.0 | 4.1.0 ✔ | |
| markdown | core | ^7.3.1 | 7.3.1 ✔ | own incremental renderer |
| flutter_markdown_plus | app | ^1.0.12 | 1.0.12 ✔ | non-streaming fallback only |
| re_highlight | app | ^0.0.3 | 0.0.3 ✔ | |
| flutter_math_fork | app | ^0.7.4 | 0.7.4 ✔ | |
| speech_to_text | app | ^7.5.0 | 7.5.0 ✔ | |
| record | app | ^7.1.2 | 7.1.2 ✔ | |
| image_picker | app | ^1.2.4 | 1.2.4 ✔ | |
| file_picker | app | ^13.1.0 | 13.1.0 ✔ | |
| share_plus | app | ^13.3.1 | 13.3.1 ✔ | |
| receive_sharing_intent | app | ^1.9.0 | 1.9.0 ✔ | compileSdk 37, SceneDelegate, SPM |
| quick_actions | app | ^1.1.1 | 1.1.1 ✔ | |
| home_widget | app | ^0.10.0 | 0.10.0 ✔ | KGP warning; optional for v1 |
| live_activities | app | ^2.6.0 | 2.6.0 ✔ | optional; pulls permission_handler |
| flutter_local_notifications | app | ^22.3.2 | 22.3.2 ✔ | desugaring required |
| flutter_foreground_task | app | ^11.0.3 | 11.0.3 ✔ | Android FGS |
| device_info_plus | app | ^13.3.0 | 13.3.0 ✔ | |
| battery_plus | app | ^7.1.2 | 7.1.2 ✔ | |
| connectivity_plus | app | ^7.3.1 | 7.3.1 ✔ | 7.3.2 blocked by battery_plus Linux deps |
| path_provider | app | ^2.1.6 | 2.1.6 ✔ | |
| dynamic_color | app | ^2.1.0 | 2.1.0 ✔ | material_ui types |
| cupertino_http | app | ^3.1.0 | 3.1.0 ✔ | downgrades objective_c to 9.5.0, native_toolchain_c to 0.19.3, code_assets to 1.2.1 |
| http | core | ^1.6.0 | 1.6.0 ✔ | inject `http.Client` |
| mcp_dart | core | ^2.4.3 | 2.4.3 ✔ | behind `McpConnection` |
| logging | core | ^1.3.0 | 1.3.0 ✔ | |
| uuid | core | ^4.6.0 | 4.6.0 ✔ | v7 ids |
| crypto | core | ^3.0.7 | 3.0.7 ✔ | |
| cryptography | core | ^2.9.0 | 2.9.0 ✔ | only if E2E/backup encryption is needed |
| json_annotation / json_serializable | core / core (dev) | ^4.12.0 / ^6.14.1 | ✔ | sparingly |
| meta / collection / async / path | core | ^1.19.0 / ^1.19.1 / ^2.13.1 / ^1.9.1 | ✔ | |
| test | core (dev) | ^1.31.1 | 1.31.1 ✔ | capped by flutter_test pins |
| mocktail | dev | ^1.0.5 | 1.0.5 ✔ | |
| shelf / shelf_router | core (dev) | ^1.4.3 / ^1.1.5 | ✔ | fake servers |
| fake_async / clock | core (dev) | ^1.3.3 / ^1.1.3 | (transitive ✔) | |
| integration_test / flutter_test | app (dev) | `sdk: flutter` | ✔ | |
| alchemist | app (dev) | ^0.14.1 | 0.14.1 ✔ | optional |
| lints / flutter_lints | dev | ^6.1.0 / ^6.0.0 | ✔ | |
| *(not adopted)* cronet_http | — | (1.10.0) | resolved, **APK build failed** | AGP 9.1 manifest namespace clash |
| *(avoid)* flutter_inappwebview, share_handler, flutter_markdown, markdown_widget, flutter_highlight, syntax_highlight, provider, freezed, mockito, golden_toolkit, sqlite3_flutter_libs, sqlcipher_flutter_libs, dart_mcp, mcp_client | | | | see sections |

**Android build settings required by this set** (all verified by APK build failures):
- `compileSdk = 37`. Also note AGP 9.1.0 warns that its "maximum recommended compile SDK" is 36.
- `isCoreLibraryDesugaringEnabled = true`, plus `coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")`.
- minSdk 24, which is Flutter's default.

**Debug APK result.**
- With these settings, and **without cronet_http**, `flutter build apk --debug --target-platform android-arm64` **succeeded** (13 min cold Gradle cache, then 12 s incremental).
- The APK contains `lib/arm64-v8a/libsqlite3mc.so` (2.0 MB). This confirms that the root `user_defines` block selects the bundled native asset on Android.
- It also contains `libbarhopper_v3.so` (ML Kit barcode model, 4.9 MB arm64; armeabi-v7a and x86_64 copies are shipped too).

---

## Recommendations for Sherpa

1. **Monorepo.**
   - Native pub workspace with `workspace: [app, packages/*]`; make `app/` a member now.
   - No melos until we publish packages.
   - CI runs Flutter's `dart`. Use a tiny `tool/` script for per-package `dart test` and `flutter test`.
2. **Design system.** Start on `material_ui` / `cupertino_ui` with `MaterialUiCompatibilityBridge` in `MaterialApp.builder`. go_router 18 and dynamic_color 2 already need it. Every widget we write imports `package:material_ui/material_ui.dart`.
3. **Persistence.**
   - drift + sqlite3 3.x with `source: sqlite3mc` in the **root** pubspec.
   - The key comes from flutter_secure_storage (`first_unlock_this_device`), and `PRAGMA key` is applied in `setup`.
   - **Fail closed** if `PRAGMA cipher` is empty.
   - Mirror the sqlite3 release binaries via `url_pattern` for reproducible CI.
4. **Core and app split.**
   - `sherpa_core` stays pure Dart: drift tables, the agent loop, the markdown incremental parser, the MCP adapter (mcp_dart) and the HTTP abstraction (`http.Client`).
   - `app/` holds plugins and Riverpod-3-as-DI.
   - No codegen except drift (and json_serializable only where unavoidable).
5. **Networking.**
   - Inject `http.Client`. Use `CupertinoClient` on iOS and `IOClient` on Android for now; re-test `cronet_http` when it supports AGP 9.
   - SSE parsing lives in core and is tested against `shelf` fakes.
6. **MCP.** Adopt `mcp_dart` 2.4.x behind our own interface, with contract tests, and keep the option to fork. Drive OAuth redirects with `flutter_web_auth_2`, and store tokens in secure storage.
7. **Rendering.**
   - Write our own streaming markdown renderer on `package:markdown`, using a closed-block cache and an open-tail re-parse.
   - Use `re_highlight` for code (in an isolate, after the fence closes) and `flutter_math_fork` for math.
   - Keep `flutter_markdown_plus` only as a stopgap.
8. **Web artifacts.** Use `webview_flutter` with CSP-injected `loadHtmlString`, a single nonce-checked `JavaScriptChannel`, and navigation blocking. If request interception becomes mandatory, write a ~200-line pigeon plugin on the external-API hooks rather than adopting `flutter_inappwebview`.
9. **Downloads.** `background_downloader` 9.6 Transfer API with `allowPause`, `retries` and optional `requiresWiFi`, plus our own SHA-256 verification against a signed manifest.
10. **State management.** Riverpod 3 without codegen, as DI plus stream adapters. Set `retry: (retryCount, error) => null` (typedef `Retry`) globally. Use `ValueNotifier` for local widget state and `ProviderContainer.test()` in tests.
11. **Tests.** Pure-Dart unit tests for the core, with `fake_async` and `clock`. Widget tests with `mocktail` and fakes. One pinned-Linux real-font golden suite. SDK `integration_test` for device E2E, adding `patrol` only for native dialogs.

---

## Risks

| # | Risk | Likelihood / impact | Mitigation |
|---|---|---|---|
| R1 | **Silent plaintext DB.** `hooks.user_defines` placed in a member pubspec is ignored (verified) | Med / **High** | Runtime `PRAGMA cipher` assert in release builds plus a CI test that opens the DB and checks the file header |
| R2 | **Build-time network dependency.** The sqlite3 hook downloads from GitHub releases; cupertino_http and others run hooks | Med / Med | `url_pattern` mirror; cache `.dart_tool/hooks_runner` in CI; or `source: source` with a vendored amalgamation |
| R3 | **Material split churn.** Two `ThemeData`s while the ecosystem migrates; the deprecation date is unannounced | High / Med | Adopt material_ui now plus the bridge; keep third-party UI widgets few and isolated |
| R4 | **Analyzer lag in a Flutter workspace** (test_api pins) holds back build_runner and freezed, and may block a future drift_dev | High / Low–Med | Minimise codegen; upgrade Flutter promptly; isolate codegen-only packages with an independent `resolution:` if needed |
| R5 | **Native-assets skew** (`code_assets` 1.x vs 2.x) causes silent downgrades (cupertino_http) and capped ffigen | Med / Med | Watch `dart pub outdated`; pin `objective_c` and `native_toolchain_c` once stable; report to dart-lang/http |
| R6 | **KGP-applying plugins** (flutter_web_auth_2 5.1.0, home_widget, cronet_http) will fail a future Flutter | High (within ~2 releases) / Med | Track flutter_web_auth_2 6.0; keep home_widget optional; avoid cronet_http |
| R7 | **CocoaPods trunk read-only 2026-12-02.** Pods-only plugins stop receiving fixes | Certain / Low (we avoid them) | Enforce "SPM tag required" in dependency review |
| R8 | **mcp_dart bus factor** (single maintainer, personal account) | Med / Med | Wrap behind our interface; contract tests; budget for a fork |
| R9 | **WebView capability ceiling.** No Android request interception or iOS content rules in webview_flutter | Med / Med | CSP-first design; own small plugin if needed |
| R10 | **Stale leaf packages** (re_highlight 2024, qr_flutter 2023, flutter_math_fork maintenance-only) may break on a future Flutter | Med / Low | Pin; each is small enough to vendor and fork |
| R11 | **Riverpod 3 defaults** (auto-retry, pause-when-hidden) can hide failures or stall background-ish UI work | Med / Med | Disable retry globally; keep long-running work in core, not providers |
| R12 | **compileSdk 37 vs AGP 9.1's "max recommended 36"** warning; future AGP needed | Low / Low | Bump AGP when Flutter templates do |
| R13 | **Proprietary components** (ML Kit in mobile_scanner, optional Play-Services Cronet) block F-Droid / de-Googled builds | Depends on PO / Med | Flavor-split, or a ZXing-based scanner for a FOSS flavor |

---

## Open questions for the product owner

1. **F-Droid / de-Googled distribution?** If yes, we need a FOSS flavor without ML Kit (mobile_scanner) or Play-Services components, plus a different QR scanner, and must avoid cronet.
2. **Encryption at rest by default?** sqlite3mc brings a licence review (SQLite3MultipleCiphers MIT; SQLCipher BSD-style plus OpenSSL on Android). The size cost is small. Measured on Linux x64: libsqlite3 1.8 MB, libsqlite3mc 2.1–2.3 MB, libsqlcipher 5.4 MB; on Android arm64, libsqlite3mc is 2.0 MB. Do we encrypt all users' DBs (recommended), or offer it opt-in?
3. **Do agent-generated HTML artifacts need network access**, for example CDN scripts? If yes, CSP-only sandboxing is insufficient and we need an interception plugin or an allow-list proxy.
4. **Which home-screen surfaces are in v1:** widgets (home_widget), Live Activities / Dynamic Island, quick actions? Each adds native targets (Widget Extension, App Group) and review surface.
5. **Background expectations on iOS.** iOS gives roughly 30 s of background time, and the background URLSession covers downloads only. Is "agent keeps running while backgrounded" an Android-only feature?
6. **Minimum OS versions.** The plugin set implies Android API 24 and iOS 13 (receive_sharing_intent) or iOS 16.1 for Live Activities. Are those acceptable?
7. **Are we OK depending on a single-maintainer MCP SDK** (mcp_dart), with a contingency to fork, versus budgeting ~4–6 engineer-weeks for an in-house 2026-07-28 client with OAuth?
8. **On-device STT and TTS.** Is platform `speech_to_text` (online on many Android devices) acceptable for privacy, or do we need on-device-only, e.g. a bundled Whisper via hooks?

---

## Verification log (10 most load-bearing claims)

| # | Claim | How verified | Result |
|---|---|---|---|
| V1 | Versions, dates, publishers, SDK constraints, platforms, discontinued flags for ~120 packages | pub.dev JSON API (`/api/packages/<n>`, `/score`, `/publisher`, `/options`) on 2026-10-18; e.g. `flutter_markdown` → `isDiscontinued: true, replacedBy: flutter_markdown_plus`; `sqlite3_flutter_libs` → `0.6.0+eol` | ✔ |
| V2 | The whole recommended set resolves together on Flutter 3.47.7 in a pub workspace (app + pure-Dart pkg) | `flutter pub add` / `dart pub add` in `/tmp/claude-0/flutter-probe/ws`; one root `pubspec.lock`; holds observed: test 1.31.1, analyzer 13.3.0, build_runner 2.16.1, connectivity_plus 7.3.1, ffigen ≤ 21 | ✔ |
| V3 | `flutter test` and `dart test` and drift codegen work inside workspace members | Riverpod 3 widget + `ProviderContainer.test` tests pass; `dart run build_runner build` generated `db.g.dart`; drift in-memory stream test passes (SQLite 3.54.0, FTS5) | ✔ |
| V4 | sqlite3 3.x bundles SQLite via build hooks (download plus sha256), no `*_flutter_libs`, including on Android | Hook output found at `.dart_tool/hooks_runner/shared/sqlite3/build/download-*/libsqlite3.so`; `sqlite3.version` = 3.54.0; changelog 3.0.0 text; debug APK contains `lib/arm64-v8a/libsqlite3mc.so` | ✔ (Linux + Android APK; iOS not buildable here) |
| V5 | Encryption via `hooks.user_defines.sqlite3.source: sqlite3mc` / `sqlcipher` plus `PRAGMA key` works, including drift background isolate | `PRAGMA cipher` → `chacha20`; header not plaintext; wrong key fails; SQLCipher `cipher_version` → `4.19.0 community` | ✔ |
| V6 | user_defines in a workspace **member** pubspec are ignored | Moved the block to `packages/probe_core/pubspec.yaml` → `PRAGMA cipher` returned `[]` | ✔ (fail-open) |
| V7 | material_ui types are distinct; dynamic_color 2.x can't feed legacy `ThemeData`; go_router 18 detects only material_ui `MaterialApp` | `dart analyze` error `argument_type_not_assignable` (two `ColorScheme` definitions); go_router 18.1.0 `pages/material.dart` source | ✔ (analysis + source) |
| V8 | Pigeon 29.0.10 generates `Future` HostApi methods, Kotlin `suspend`, Swift `async throws`, and a top-level `Stream<T>` for `@EventChannelApi`; event-channel methods can't take parameters | Ran `dart run pigeon` on a probe definition; inspected `.g.dart`, `.g.kt`, `.g.swift`; parameterised version rejected with explicit error | ✔ |
| V9 | webview_flutter has no `shouldInterceptRequest` and no `WKContentRuleList`; native view is reachable via external APIs | grep of webview_flutter_android 4.14.1 Java/Kotlin and webview_flutter_wkwebview 3.27.0 generated bindings; read `WebViewFlutterAndroidExternalApi` / `FWFWebViewFlutterWKWebViewExternalAPI` | ✔ (source) |
| V10 | mcp_dart 2.4.3 speaks MCP 2026-07-28 over Streamable HTTP, and its client is injectable via `http.runWithClient` | In-process `StreamableMcpServer` + `McpClient`: log "MCP Server Discovered … Protocol: 2026-07-28", `listTools` / `callTool` OK, 3 requests counted through the injected client | ✔ |

Also verified but not in the top 10:
- Dart 3.13 primary constructors compile.
- `http` streams SSE chunks incrementally from a `shelf` server.
- A real-font golden (Roboto via `FontLoader`) renders and re-verifies.
- The APK build demands compileSdk 37 (receive_sharing_intent, permission_handler_android) and desugaring (flutter_local_notifications), prints the KGP warning, and cronet_http fails manifest merge.

**Reported, not re-verified:**
- The CocoaPods read-only date and Material deprecation timing.
- mcp_dart's conformance claims.
- iOS-side behaviour of every plugin. iOS could not be built on this Linux host.
- The MCP spec details beyond the versioning page.
