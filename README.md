# Sherpa

An open, local-first **agent harness** for Android and iOS. Sherpa runs agent loops against on-device
models (llama.cpp, MLX, LiteRT-LM, platform models) or remote ones (OpenAI-compatible servers, the OpenAI
Responses API, Anthropic), finds models on the Hugging Face Hub, manages its own context under token and
memory pressure, and is a full **MCP** host: tools, resources, prompts, elicitation and MCP Apps.

> Status: under active development, milestone by milestone. See [docs/PLAN.md](docs/PLAN.md) for the
> architecture, decisions and risks, and [docs/research/](docs/research/) for the verified research it is
> based on.

## Milestones

| Milestone | Scope | Status |
|---|---|---|
| [M1](docs/milestones/M1.md) | Core agent loop, remote providers, chat UI | **Done** |
| [M2](docs/milestones/M2.md) | Hugging Face directory, device fit, downloads, on-device inference (llama.cpp, MLX, LiteRT-LM, Gemini Nano, Apple FM) + optimization | **Done** |
| [M3](docs/milestones/M3.md) | Context manager: pruning, compaction, handoff, memory monitor, inspector | **Done** |
| [M4](docs/milestones/M4.md) | MCP client, OAuth, tool hygiene, approvals, tool budget | **Done** |
| [M5](docs/milestones/M5.md) | MCP Apps host, elicitation, sampling | **Done** |
| [M6](docs/milestones/M6.md) | Polish, [accessibility](docs/milestones/M6-accessibility.md), background execution, perf budgets, evals | **Done** |

Every milestone is verified by tests (unit, widget, golden, integration and an accessibility audit; a real
llama.cpp engine and small models on a Linux host) and on CI, which builds the Android APK (16 KB-aligned)
and the iOS app (Xcode 26.6). **Nothing has run on a phone yet.** Each milestone's notes list exactly what
was and wasn't verified.

## Repository layout

| Path | What it is |
|---|---|
| `packages/sherpa_core` | Pure-Dart core: domain model, provider/tool/context interfaces, the agent loop |
| `packages/sherpa_net` | SSE decoder, SSRF-safe URL policy, retry/backoff, secret redaction |
| `packages/sherpa_providers` | Remote providers: Anthropic, OpenAI Chat (+ server quirk profiles), OpenAI Responses |
| `packages/sherpa_data` | Encrypted Drift/SQLite persistence |
| `packages/sherpa_markdown` | Incremental streaming Markdown renderer |
| `packages/sherpa_hub` | Hugging Face Hub client, model-name parser, device-fit engine, download planner |
| `packages/sherpa_inference` | On-device inference: FFI bindings to `sherpa_engine`, engine hosts, `LlamaCppProvider`, model lifecycle (admission, memory pressure), scheduler, autotune, persistent prefix (KV) cache |
| `packages/sherpa_mcp` | MCP client for both protocol eras (stateless 2026-07-28 and session-based), Streamable HTTP + SSE transports |
| `packages/sherpa_auth` | OAuth 2.1 for MCP servers and Hugging Face: discovery, PKCE, client registration, token storage |
| `packages/sherpa_platform` | Native device signals (Pigeon): memory pressure, device profile, backup exclusion, background-run guard |
| `packages/sherpa_litert` | Android providers: LiteRT-LM (`.litertlm`) and Gemini Nano (ML Kit GenAI Prompt API) |
| `packages/sherpa_apple_ml` | iOS providers: MLX (mlx-swift-lm) and Apple Foundation Models |
| `packages/sherpa_webview` | Sandboxed WebView for MCP Apps: shell page, srcdoc iframe, CSP, bridge |
| `packages/sherpa_evals` | Eval suites L0–L4 (scripted, local model, remote) and host benchmarks |
| `bench/` | Perf baselines per device class; frame-timing benchmark scripts |
| `app/` | The Flutter app |
| `native/` | `sherpa_engine` (C ABI over llama.cpp) and pinned build scripts |
| `docs/` | Plan, research digests, milestone notes |

## Development

Requirements: Flutter 3.47.7 (Dart 3.13.5). Android builds need the Android SDK with NDK 29.0.14206865;
iOS builds need Xcode on macOS.

```sh
flutter pub get            # one resolution for the whole pub workspace
tools/test_all.sh          # analyze + every package's tests
cd app && flutter run      # run the app
```

The database is encrypted with SQLite3MultipleCiphers. The `hooks.user_defines` block that selects it must
stay in the **root** `pubspec.yaml`; in a member pubspec it is silently ignored.

### Accessibility

Every screen outside chat, home and the shell is audited by widget tests (M6, see
[docs/milestones/M6-accessibility.md](docs/milestones/M6-accessibility.md)). The shared helper is
`app/test/support/a11y_audit.dart`: `auditScreen('name', open)` registers one test per view of the matrix
(phone 360×740 and tablet 1200×840, text at 1× and 2×, plus phone in dark mode), opens the screen through
the feature's own rig, and calls `expectAudit`, which checks the screen at the top and after each scroll
step to its end:

- Flutter's `androidTapTargetGuideline` (48×48), `iOSTapTargetGuideline` (44×44),
  `labeledTapTargetGuideline` and `textContrastGuideline`;
- exact text contrast from the colours in the widget tree (`expectExactTextContrast`), because the
  pixel-sampling contrast guideline misreads 12 px text at 1× (anti-aliasing, a neighbouring surface or a
  button outline wins its sample). Where it does, the screen lists that view in `pixelContrastSkip` with a
  `contrastNote`; the exact check still runs there;
- no RenderFlex overflow (every visible `Row`/`Column` measured) and no exception, so no "A RenderFlex
  overflowed" report either;
- every icon-only button has a tooltip, `excludeSemantics` over something tappable keeps the action, and
  every screen has a heading that isn't read after the text around it.

`test/a11y/` also holds the RTL pass (`rtl_test.dart`), reduced motion for sheets, dialogs, expansion tiles
and pushed pages (`reduced_motion_test.dart`), focused semantics checks (`semantics_test.dart`) and source
rules (`source_rules_test.dart`: no hard-coded left/right, every framework animation given
`motionStyleOf(context)`, headings through `Heading`).

```sh
cd app
flutter test --no-pub --concurrency=2 test/a11y                     # the audit and its rules
flutter test --no-pub --concurrency=2 test/a11y/audit_models_test.dart --plain-name 'downloads'
```

When you add a screen, add an `auditScreen` line next to its feature's rig and use the design system's
pieces: `Heading` / `HeadingGroup` for headings, `LiveAnnouncement` for progress that should be announced
at milestones, `SectionHeader(count:)` for list lengths, `motionStyleOf(context)` / `MotionPageRoute` for
anything that animates.

### Release builds

The `android-release` job in [`.github/workflows/ci.yml`](.github/workflows/ci.yml) builds the release APK
(arm64-v8a, with the on-device engine) on pushes to `main`, on `v*` tags and on manual runs (Actions → ci →
Run workflow). Pull requests skip it: a cold engine build alone takes about 5 minutes.

1. Installs the NDK and CMake pinned in `native/llama/llama.lock` if the runner lacks them.
2. Restores `native/llama/out/android` from the cache, keyed by a hash of `native/llama/llama.lock`,
   `native/llama/*.sh` and `native/engine/**`. On a miss it runs `native/llama/build_android.sh` with
   `SHERPA_STRICT=1`; a failing engine gate (alignment, NEEDED, variants, exports, size budget) fails the job.
   To force a rebuild, delete the `android-engine-Linux-…` entry under Actions → Caches.
3. Writes `app/android/key.properties` and the keystore from the secrets below (deleted at the end of the job),
   then runs `flutter build apk --release --target-platform android-arm64`.
4. Runs [`tools/check_release_apk.sh`](tools/check_release_apk.sh): `apksigner verify` (prints the certificate
   SHA-256), `zipalign -c -P 16 -v 4`, not debuggable, the INTERNET permission, the `:inference` service, the
   engine libraries stored uncompressed, and the JNI names native code looks up (every class named by
   `lib/arm64-v8a/*.so`, `EngineError.<init>(I[B)V`, `ProgressSink.onProgress(F)Z`, `NativeEngine`'s natives
   against the shim's `RegisterNatives` table) in the dex.
5. Uploads `sherpa-<version>-<commit>-arm64-release.apk` as an artifact (the `.apk` itself, kept 30 days) and a
   `…-symbols` artifact (R8 `mapping.txt`, unstripped engine libraries), and puts the APK's SHA-256 in the job
   summary.

Without the secrets (forks, or before they are added) the APK is signed with the debug key and named
`…-arm64-debug-signed.apk`, and the job summary says so: it installs, but cannot update an install signed with
the release key. On a `v*` tag, `android-release-publish` attaches a release-signed APK and its `.sha256` to the
tag's GitHub Release once the tests pass, creating the release as a draft if it does not exist yet. The tag must
match the app version (`v0.1.0` for `version: 0.1.0+N`); a debug-signed APK is never attached.

Repository secrets and variables (Settings → Secrets and variables → Actions):

| Name | Kind | Value |
|---|---|---|
| `SHERPA_RELEASE_KEYSTORE_BASE64` | secret | the keystore (`.jks`), base64 on one line |
| `SHERPA_RELEASE_STORE_PASSWORD` | secret | the keystore password |
| `SHERPA_RELEASE_KEY_PASSWORD` | secret | the key password (for a PKCS12 keystore, keytool's default, the store password) |
| `SHERPA_RELEASE_KEY_ALIAS` | variable (or secret) | the key's alias |
| `SHERPA_RELEASE_CERT_SHA256` | variable, optional | the certificate's SHA-256; the job then fails on any other key |

```sh
# Once: create the key (keep the .jks and its passwords backed up, outside the repository).
keytool -genkeypair -v -keystore sherpa-release.jks -storetype PKCS12 -keyalg RSA -keysize 4096 \
  -validity 10000 -alias sherpa-upload
# The base64 value (Linux and macOS), straight into the secret with the GitHub CLI:
base64 < sherpa-release.jks | tr -d '\n' > sherpa-release.jks.b64
gh secret set SHERPA_RELEASE_KEYSTORE_BASE64 < sherpa-release.jks.b64 && rm sherpa-release.jks.b64
gh secret set SHERPA_RELEASE_STORE_PASSWORD      # prompts for the value
gh variable set SHERPA_RELEASE_KEY_ALIAS --body sherpa-upload
gh secret set SHERPA_RELEASE_KEY_PASSWORD
# Optional: pin the certificate (the job then fails on any other key).
keytool -list -keystore sherpa-release.jks -alias sherpa-upload | sed -n 's/.*(SHA-256): //p'
gh variable set SHERPA_RELEASE_CERT_SHA256 --body '<that fingerprint>'
```

The alias is read from the variable first: GitHub masks every secret value wherever it appears in the logs, so
an alias stored as a secret should be a word that occurs nowhere else (`sherpa-upload`, not `sherpa`).

Locally, the same build and checks (the script finds the build tools through `ANDROID_HOME`):

```sh
native/llama/build_android.sh                  # once, and after engine changes
(cd app && flutter build apk --release --target-platform android-arm64)
tools/check_release_apk.sh --require-release-key            # app/build/app/outputs/flutter-apk/app-release.apk
```

Release signing reads `app/android/key.properties` (`storeFile`, `storePassword`, `keyAlias`, `keyPassword`;
gitignored); without it, release builds fall back to the debug key.

## License

MIT — see [LICENSE](LICENSE).
