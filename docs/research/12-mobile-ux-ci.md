# 12 — Mobile UX (Flutter 3.47) and CI for Sherpa

Researched 2026-10-18 against Flutter **3.47.7** stable (framework `abaf9c5`, engine `deb2874`, Dart 3.13.5, DevTools 2.60.0) installed at `/opt/flutter-sdk/flutter`. Sources:
- **[SDK]**: grepped in that checkout (path:line given).
- **[DOC]**: official page fetched today (docs.flutter.dev, api.flutter.dev, developer.android.com, developer.apple.com, docs.github.com, firebase.google.com, pub.dev).
- **[RAW]**: README or source file fetched from raw.githubusercontent.com.
- **[MOB]**: real app screens on Mobbin (iOS).
- **[3P]**: third-party article.

Anything I could not check is marked **UNVERIFIED**.

---

## 0. Ten facts that change Sherpa's plans

| # | Fact | Source |
|---|---|---|
| 1 | Material and Cupertino are leaving the SDK. Contributions froze in 3.44. **`material_ui` 1.0 and `cupertino_ui` 1.0 shipped with 3.47.** Latest versions: `material_ui` **1.7.0** (2026-10-14, `flutter: >=3.47.0`) and `cupertino_ui` **1.1.3**. The in-SDK libraries are "scheduled for formal deprecation in the upcoming Fall stable release in November". | [DOC] docs.flutter.dev/release/breaking-changes/material-ui-and-cupertino-ui; flutter.dev/blog/whats-new-in-flutter-3-47; pub.dev API `/api/packages/material_ui` |
| 2 | **Material 3 Expressive barely exists.** The SDK has only `DynamicSchemeVariant.expressive` (a color scheme). The SDK itself says "Material 3 Expressive springs … are not currently supported by Flutter". In `material_ui` 1.7.0, `StyleVariant.material3Expressive` is honored **only by `IconButton`**, through `IconButtonThemeData.variant`. | [SDK] `material/color_scheme.dart:51`, `material/page_transitions_theme.dart:468`; `material_ui-1.7.0` archive: `lib/src/theme_data.dart:200`, `icon_button_theme.dart:56-60` |
| 3 | **No official Liquid Glass.** Neither the SDK nor the `cupertino_ui` changelog has any glass material. The third-party options are experimental. | [SDK] grep `liquid\|glass` returns nothing relevant; [DOC] pub.dev/packages/cupertino_ui/changelog |
| 4 | **The Android default transition is `PredictiveBackPageTransitionsBuilder` (since 3.38).** It falls back to `FadeForwardsPageTransitionsBuilder` for non-gesture pops, and its duration is **450 ms** (it was 300 ms). With targetSdk 36 on Android 16, system predictive-back animations are on by default. On Android 13–15 you still need `android:enableOnBackInvokedCallback="true"`, and **Sherpa's manifest doesn't have it**. | [SDK] `material/page_transitions_theme.dart:764-771`; [DOC] breaking-changes/default-android-page-transition, platform-integration/android/predictive-back, developer.android.com/about/versions/16/behavior-changes-16; repo `app/android/app/src/main/AndroidManifest.xml` |
| 5 | **Google Play requires targetSdk 36 from 2026-08-31** (extension available to 2026-11-01). This brings mandatory edge-to-edge, ignored orientation and resizability restrictions on displays ≥600dp (Android 17 also removes the opt-out), and predictive back. | [DOC] developer.android.com/google/play/requirements/target-sdk; breaking-changes/android-large-screens-restrictions-ignored |
| 6 | **Impeller on Android uses one of three backends:** Vulkan when the driver is allowed, **Impeller-GLES** when it isn't, and **Skia-GLES on API < 29 or Vivante GPUs**. Vulkan is denied on: Adreno ≤ 650, Huawei Maleoon, Samsung Xclipse with Vulkan < 1.3, PowerVR older than CXT, and Pixel 10 with driver < 25.1. iOS has Impeller only. | [SDK] `engine/.../android/flutter_main.cc:34,268-302`; `impeller/renderer/backend/vulkan/driver_info_vk.cc:377-427`; [DOC] docs.flutter.dev/perf/impeller |
| 7 | **A streaming message wrapped in a live region will flood the screen reader.** Every label change re-announces the *whole* label. On iOS that is a queued `UIAccessibilityAnnouncementNotification`; on Android it is a subtree content-change event. Android reports `supportsAnnounce == false`, and `SemanticsService.announce` is deprecated in favor of `sendAnnouncement(view, …)`. | [SDK] `darwin/ios/.../SemanticsObject.mm:356-369`, `accessibility_bridge.mm:139-150`; `android/.../AccessibilityBridge.java:313-325,580,1705-1707`; `lib/ui/window.dart:995`; `semantics/semantics_service.dart:51-56` |
| 8 | **iOS Reduce Motion does not set `MediaQuery.disableAnimations`.** That flag covers only Android "Remove animations" (`TRANSITION_ANIMATION_SCALE == 0`). iOS Reduce Motion appears only as `AccessibilityFeatures.reduceMotion`. | [SDK] `widgets/media_query.dart:663-672`; `darwin/ios/.../AccessibilityFeatures.swift:45`; `android/.../AccessibilityBridge.java:583-588` |
| 9 | **Firebase Test Lab is deprecated and shuts down on 2027-09-30.** Its successor, Google Cloud **Developer Device Platform**, has been in Preview since 2026-08-12, and its CLI covers **Android only** ("iOS support is coming soon"). | [DOC] firebase.google.com/docs/test-lab/migrate; firebase.google.com/docs/test-lab/android/get-started; [DOC/3P] docs.cloud.google.com/developer-device-platform/overview, release notes |
| 10 | **`flutter test` renders goldens with software Skia** (`--enable-software-rendering --skia-deterministic-rendering --use-test-fonts --disable-asset-fonts`). Goldens therefore never show Impeller output. Real fonts and icons must be loaded by hand. | [SDK] `flutter_tools/lib/src/test/flutter_tester_device.dart:113-120` |

---

## 1. Flutter UX platform status (3.47.7)

### 1.1 Design libraries: material_ui / cupertino_ui
- **Timeline [DOC]:** 3.44 froze in-SDK Material and Cupertino contributions. 3.47 published 1.0 of both packages, with "weekly releases with semantic versioning" planned. The blog post gives the formal deprecation of `package:flutter/material.dart` as the "upcoming Fall stable release in November"; the breaking-change page says only "an upcoming stable release". No removal date has been announced.
- **Migration [DOC]:** run `dart fix --apply --code=migrate_design_widgets`, or add the packages yourself and change imports to `package:material_ui/material_ui.dart` / `package:cupertino_ui/cupertino_ui.dart`. With `localizationsDelegates: GlobalMaterialLocalizations.delegates`, the Cupertino and Widgets delegates are included automatically.
- **Compatibility bridge [DOC]:** `MaterialApp(builder: (c, child) => MaterialUiCompatibilityBridge(child: child!))` injects `Theme` and `MaterialLocalizations` for dependencies that haven't migrated. It **cannot** fix type mismatches when a dependency's public API takes SDK types such as `ColorScheme` or `TextTheme`. Package authors should treat migrating as a major-version bump.
- **3.44 reorganization [DOC]:** `CupertinoPageTransitionsBuilder` moved into `cupertino_ui`. The Material builders, `PredictiveBackPageTransitionsBuilder` included, stay in `material_ui`.
- **Version floor [DOC]:** `material_ui` 1.4.0+ and `cupertino_ui` 1.1.1+ require Flutter 3.47 / Dart 3.13. Sherpa is already on that floor.

### 1.2 Material 3 and "Material 3 Expressive"
- `ThemeData(useMaterial3:)` still defaults to `true` [SDK `material/theme_data.dart:413`]. The M3 token refresh landed in 3.41 [DOC breaking-changes list].
- **What M3 Expressive support exists:**
  - In the SDK, only `ColorScheme.fromSeed(dynamicSchemeVariant: DynamicSchemeVariant.expressive)` [SDK `color_scheme.dart:51,2217`].
  - In `material_ui`: 1.2.0 added the `StyleVariant {material3, material3Expressive}` enum, and 1.5.0 wired up "Material 3 Expressive support for IconButton" plus contrast baselines [DOC changelog]. In 1.7.0 the variant is read only by `IconButton`/`ButtonStyle` code [archive grep].
  - Its own docstring: "Material 3 Expressive support is under development … may see visual changes".
- **Missing:** button groups, split buttons, FAB menu, floating toolbars, `LoadingIndicator` (the shape-morph spinner), shape morphing, and the spring motion scheme. A grep of the `material_ui` 1.7.0 archive finds none of these classes.
- **Implication:** Sherpa's "expressive" feel (morphing composer, wavy progress) must be built in-house. Use your own tokens and `AnimationController`/`SpringSimulation`. Don't wait for `material_ui`.

### 1.3 Cupertino, iOS 26/27, and Liquid Glass
- **Official status:**
  - 3.38 "fully supports" iOS 26 / Xcode 26 and adopted UIScene [DOC whats-new].
  - 3.47 targets Xcode 27, raises the iOS minimum **13 → 15**, and warns that "Apps built with Xcode 27 that do not adopt UIScene will fail to launch on startup" [DOC 3.47 blog].
  - Sherpa already has `SceneDelegate.swift`, `UIApplicationSceneManifest`, `FlutterImplicitEngineDelegate` and `IPHONEOS_DEPLOYMENT_TARGET = 15.0` [repo].
- **Liquid Glass:** there is **no first-party implementation**, and the cupertino_ui changelog has nothing about glass [DOC]. A 3P article (issoh.co.jp, August 2026) reports that the Flutter team said in June 2025 it had no plans to build the Apple 26 look into Cupertino (tracking issue flutter/flutter#170310). **UNVERIFIED**: github.com was blocked for this session.
- **Packages (all experimental):**
  - `liquid_glass_renderer` **1.0.0-dev.0** (whynotmake.it). Requires Flutter ≥ 3.47. Full effect needs Impeller **and Flutter GPU (preview)**; otherwise it falls back to `FakeGlass` (a BackdropFilter). Each `LiquidGlassLayer` is a `BackdropFilter` that copies the render pass. Max 16 shapes per layer. Its authors say it is "not yet battle-tested in production" [DOC pub.dev].
  - `cupertino_native` **0.1.1** (serverpod.dev, 13 months old). A proof of concept that hosts seven native UIKit/AppKit controls as platform views [DOC pub.dev].
  - `liquid_glass_native` uses real SwiftUI glass in `UiKitView`s, from an unverified uploader [3P search]. **UNVERIFIED** quality.
- **SDK building blocks if we approximate glass:** `BackdropFilter` + `BackdropGroup`/`BackdropKey`, which share one backdrop read across several filters [SDK `widgets/basic.dart:471`]. Also `ImageFilter.shader(FragmentShader)` [SDK `lib/ui/painting.dart:4461`] and `RSuperellipse`/`RoundedSuperellipseBorder` for iOS-style squircles [SDK `painting/`].
- **Gap:** Flutter exposes **no "Reduce Transparency" flag**. `AccessibilityFeatures` offers accessibleNavigation, invertColors, disableAnimations, boldText, reduceMotion, highContrast, onOffSwitchLabels, noAnnounce, noAutoPlayAnimatedImages, noAutoPlayVideos and deterministicCursor [SDK `lib/ui/window.dart:928-938`]. Any glass surface needs a native plugin to honor that setting, or a "solid" fallback we always ship.
- **New Cupertino widgets worth using:**
  - `showCupertinoSheet`/`CupertinoSheetRoute` (stacked sheets; `showDragHandle` forwarding fixed in cupertino_ui 1.1.2).
  - `CupertinoMenuAnchor`, `CupertinoExpansionTile`, `CupertinoFocusHalo` [SDK `cupertino/`].
  - `CupertinoDynamicColor` with wide gamut (3.38) [DOC].

### 1.4 Adaptive layout, large screens and foldables
- **Guidance [DOC adaptive-responsive/general, best-practices, large-screens]:**
  - Choose layouts from `MediaQuery.sizeOf(context)` (whole window) or `LayoutBuilder` (parent constraints). Never use device type, and never put `OrientationBuilder` near the root.
  - Don't lock orientation. On foldables a lock causes letterboxing, and `MediaQuery` never sees the larger window.
  - Bottom `NavigationBar` below 600 logical px; `NavigationRail` at 600 or more.
  - Use `SliverGridDelegateWithMaxCrossAxisExtent` rather than fixed column counts. Keep state across fold/unfold (`PageStorageKey` for scroll).
  - `flutter_adaptive_scaffold` is **discontinued** (0.3.3+1) [DOC pub.dev].
- **Window size classes, width [DOC developer.android.com use-window-size-classes]:**

  | Class | Width |
  |---|---|
  | compact | < 600 dp |
  | medium | 600–839 |
  | expanded | 840–1199 |
  | large | 1200–1599 |
  | extra-large | ≥ 1600 |

  Height: compact < 480, medium 480–899, expanded ≥ 900. Flutter ships no size-class API (grep for `WindowSizeClass` finds nothing) [SDK], so Sherpa defines its own `enum WindowClass` from `MediaQuery.sizeOf`.
- **Android platform changes:**
  - Android 16 with targetSdk 36 ignores orientation, resizability and aspect-ratio restrictions on sw ≥ 600dp. A temporary opt-out exists: `PROPERTY_COMPAT_ALLOW_RESTRICTED_RESIZABILITY` [DOC].
  - Android 17 removes that opt-out, so `SystemChrome.setPreferredOrientations` is **ignored** at ≥ 600dp [DOC breaking-changes/android-large-screens-restrictions-ignored].
  - Edge-to-edge opt-out (`windowOptOutEdgeToEdgeEnforcement`) is disabled for targetSdk 36 on Android 16 devices [DOC].
- **Foldables:**
  - `MediaQuery.displayFeaturesOf(context)` returns `List<ui.DisplayFeature>` and is **populated only on Android**. Types: `hinge`/`cutout` obstruct, `fold` doesn't. States: `postureFlat`, `postureHalfOpened`. Bounds are in logical px [SDK `media_query.dart`; DOC api.flutter.dev DisplayFeature].
  - `DisplayFeatureSubScreen` places dialogs on one side of a hinge [SDK `widgets/display_feature_sub_screen.dart:54`]. There is **no TwoPane widget**.
  - `View.of(context).display` gives the physical size and refresh rate [DOC]. `MediaQuery.displayCornerRadiiOf` (Android 31+) [SDK] is useful for inset composer corners.
- **TwoPane pattern for Sherpa (to build):**
  - At ≥ 840dp, or when a vertical `fold`/`hinge` splits the window: conversation list | transcript, or transcript | tool/artifact inspector. Split exactly on `feature.bounds`.
  - With a horizontal fold in `postureHalfOpened` (tabletop): transcript above the fold, composer and approvals below.
  - Wrap all modal dialogs in `DisplayFeatureSubScreen`.

### 1.5 Predictive back and navigation
- The default `PageTransitionsTheme` maps Android → `PredictiveBackPageTransitionsBuilder()` and iOS/macOS → `CupertinoPageTransitionsBuilder()` [SDK `page_transitions_theme.dart:764-771`].
- The predictive animation runs only while `route.popGestureInProgress` and only on Android U+. Otherwise it uses `FadeForwardsPageTransitionsBuilder` [SDK `predictive_back_page_transitions_builder.dart:19-98`]. `PredictiveBackFullscreenPageTransitionsBuilder` is the alternative for full-screen surfaces.
- **Test breakage [DOC]:** 450 ms transitions. Use `TransitionDurationObserver` / `observer.pumpPastTransition(tester)` instead of hard-coded pumps.
- **Manifest:** the Flutter template does **not** add `enableOnBackInvokedCallback` (grep of `flutter_tools/templates` finds nothing) [SDK]. The docs tell you to add it for Android 13+ [DOC]. Android 16 with targetSdk 36 enables predictive system animations by default and stops calling `onBackPressed` [DOC]. The engine registers `OnBackInvokedCallback` on API 33+ when the framework handles back [SDK `FlutterActivity.java:658-735`].
- **Pop handling:** `PopScope(canPop:, onPopInvokedWithResult: (didPop, result) …)`; `WillPopScope` is deprecated [DOC].
- **Harness rule:** a back gesture must **never** cancel a running agent turn. Runs continue in the background, and `PopScope` only guards an unsent draft or a pending approval sheet.

### 1.6 Rendering: Impeller, threads, refresh rate
- **iOS:** Impeller is "the only supported rendering engine … no ability to switch to Skia" [DOC perf/impeller].
- **Android selection [SDK `flutter_main.cc`]:**
  - `enable_impeller && api_level >= 29 && !IsVivante()` → `kImpellerAutoselect`, which tries Vulkan then falls back to Impeller-GLES [SDK `android_context_dynamic_impeller.cc:154-161`].
  - Anything else → `kSkiaOpenGLES`.
  - The flutter.minSdk default is **24** [SDK `FlutterExtension.kt:26`], so devices on API 24–28 run **Skia**.
- **Vulkan denylist** (`DriverInfoVK::IsKnownBadDriver`, these fall back to GLES): Adreno ≤ 650 (flutter#178285, #178498), Huawei Maleoon, Samsung Xclipse with Vulkan < 1.3, PowerVR < CXT, Pixel 10 PowerVR with driver < 25.1 [SDK `driver_info_vk.cc:377-427`]. Many mid-range Snapdragon 8xx-era phones (Adreno 640/650) therefore run Impeller-GLES. Sherpa's device lab needs one.
- **Opt-out:** `<meta-data android:name="io.flutter.embedding.android.EnableImpeller" android:value="false"/>` is still `allowedInRelease = true`. `ImpellerBackend` (`vulkan`/`opengles`) is a manifest key [SDK `FlutterEngineFlags.java:146-162`; DOC].
- **Desktop:** Impeller became the default on macOS/Windows/Linux in 3.47 [DOC].
- **Merged UI/platform thread** is the default (`MergedPlatformUIThread::kEnabled`), and iOS rejects `FLTEnableMergedPlatformUIThread=false` [SDK `common/settings.h:385`, `FlutterDartProject.mm:229-232`]. Dart work on the root isolate therefore stalls the platform thread too. **SSE/JSON parsing, markdown parsing of big messages, syntax highlighting, tokenization and FFI inference must run off the root isolate** (`Isolate.run`, long-lived worker isolates).
- **High refresh rate:**
  - iOS: the template sets `CADisableMinimumFrameDurationOnPhone = true`, and Sherpa has it [repo `app/ios/Runner/Info.plist:5`]. ProMotion 120 Hz is available.
  - Android: the embedding never calls `Surface.setFrameRate` (no match in `embedding/`) [SDK]. The device or OEM picks the rate. `flutter_displaymode` 0.7.0 can request it, but is "ineffective on devices with LTPO panels" [DOC pub.dev].
  - Measure with `TimelineSummary` keys `60hz_frame_percentage` … `120hz_frame_percentage` [SDK `flutter_driver/.../timeline_summary.dart:364-369`].
  - Budget: 16 ms build + 16 ms raster at 60 Hz; "under 8ms (total)" for 120 fps [DOC perf/best-practices].

### 1.7 Text scaling
- `textScaleFactor` APIs are deprecated (since 3.12). `MediaQuery.textScalerOf` returns a `SystemTextScaler` that calls `platformDispatcher.scaleFontSize`, which gives **nonlinear** scaling on Android 14+ [SDK `media_query.dart:352,2473-2479`].
- `TextScaler.clamp(minScaleFactor:, maxScaleFactor:)`, `MediaQuery.withClampedTextScaling`, `MediaQuery.withNoTextScaling` [SDK `painting/text_scaler.dart:62`, `media_query.dart:1479,1503`].
- **Rule:** never clamp message bodies. Clamp only dense chrome (badges, token counter) to about 1.3–1.5×, and test at the largest OS setting. The release checklist requires the UI to stay usable at "very large" scale [DOC accessibility].
- `MediaQuery.boldTextOf` (iOS, Android 31+).

### 1.8 Semantics and screen readers (streaming-specific)
- **Available APIs [SDK]:**
  - `Semantics(role: SemanticsRole.*)`. Values include `status`, `alert`, `loadingSpinner`, `progressBar`, `list`, `listItem`, `dialog`, `alertDialog`, `tab*`, `menu*`, `form`, `tooltip`, `table`… [`lib/ui/semantics.dart:361+`].
  - `liveRegion`, `headingLevel`, `identifier`, `traversalParentIdentifier`/`traversalChildIdentifier`, `controlsNodes`, `validationResult`, `inputType`, `accessibilityFocusBlockType` [`widgets/basic.dart`].
- **Android role mapping:** only `PROGRESS_BAR`, `COMBO_BOX`, `MENU`, `LIST`, `RADIO_GROUP` and `MENU_ITEM*` get configurators. `status`/`alert` change **nothing** on Android [SDK `RoleConfiguratorFactory`]. Use `liveRegion` explicitly.
- **Live-region behavior [SDK]:**
  - iOS announces the full new label whenever a live-region label changes. The announcement is queued (`UIAccessibilitySpeechAttributeQueueAnnouncement`).
  - Android sends `TYPE_WINDOW_CONTENT_CHANGED` (SUBTREE) on each label change, and TalkBack speaks politely.
- **Announcements:**
  - `SemanticsService.announce` is deprecated after 3.35. Use `SemanticsService.sendAnnouncement(View.of(context), msg, TextDirection.ltr)` [SDK `semantics_service.dart:51-96`]. `Assertiveness` is honored only on web.
  - Android sets `NO_ANNOUNCE`, so `MediaQuery.supportsAnnounceOf` is **false**. On API 36 it logs a deprecation warning but still calls `announceForAccessibility` [SDK `AccessibilityBridge.java:313-325,580`].
- **Headings:** 3.47 made `header: true` a **no-op on iOS/Android**. Use `headingLevel: 1..6`, which maps to `View.setHeading(true)` and `UIAccessibilityTraitHeader`/`accessibilityHeadingLevel` [DOC breaking-changes/semantics-header-heading-level].
- **Recommended streaming pattern for Sherpa (synthesized):**
  1. **Never** make the streaming text node a live region.
  2. Keep one **turn-status node** per active turn: visually it is the status chip, and it is the only `liveRegion: true`. Change its label only on **phase transitions**: "Sherpa is thinking" → "Running tool web_search" → "Waiting for your approval" → "Response complete, 340 words. Double-tap to read". Debounce label changes to ≥ 1.5 s. On iOS, `sendAnnouncement` for phase changes is fine where `supportsAnnounceOf` is true.
  3. While `MediaQuery.accessibleNavigationOf(context)` is true (TalkBack/VoiceOver), expose the message's semantic label only up to the last **finalized block or sentence boundary**. `ExcludeSemantics` the live tail, so a focused user doesn't hear text rewrite under them. Disable the typewriter or cursor animation.
  4. Add an opt-in setting, "Read responses aloud while streaming", that queues `sendAnnouncement` per completed sentence (iOS), or per paragraph-level live region (Android).
  5. Put `headingLevel: 2` on each message's author line ("Sherpa", "You") for rotor/heading navigation. Add `customSemanticsActions` (Copy, Retry, Read aloud) instead of tiny icon rows.
  6. High-risk approvals go in a modal route, which brings route semantics and focus. Inline approval cards need an explicit focus request and a live-region status change.
- **Tests [DOC accessibility-testing]:** `expectLater(tester, meetsGuideline(androidTapTargetGuideline | iOSTapTargetGuideline | labeledTapTargetGuideline | textContrastGuideline))` with `tester.ensureSemantics()`. Run them on every chat-surface widget test.

### 1.9 Reduced motion, haptics, keyboard, restoration, selection
- **Reduced motion:**
  - Compute `reduceMotion = MediaQuery.disableAnimationsOf(ctx) || View.of(ctx).platformDispatcher.accessibilityFeatures.reduceMotion`. Listen through `WidgetsBindingObserver.didChangeAccessibilityFeatures`.
  - With `disableAnimations`, `AnimationController(animationBehavior: normal)` runs at **5%** duration [SDK `animation_controller.dart:76,651`].
  - `deterministicCursor` (iOS) asks for a non-blinking caret [SDK `window.dart:939`].
- **Haptics [SDK `services/haptic_feedback.dart`]:**
  - `vibrate`, `lightImpact`, `mediumImpact`, `heavyImpact`, `selectionClick`.
  - New: `successNotification` / `warningNotification` / `errorNotification`. iOS uses `UINotificationFeedbackGenerator`. Android API 30+ uses `CONFIRM`/`KEYBOARD_TAP`/`REJECT`, and these are **no-ops below API 30**.
  - Suggested map: send → `lightImpact`; approval required → `warningNotification`; tool error → `errorNotification`; foreground run complete → `successNotification`. **Never per token.**
- **Keyboard:**
  - Use `Shortcuts` + `Actions` + `Intent` (`isEnabled` gating), or `CallbackShortcuts` for simple cases. `SingleActivator`, `CharacterActivator`. Bindings need a `Focus` ancestor [DOC ui/interactivity/actions-and-shortcuts; SDK `widgets/shortcuts.dart:433,682,1182`].
  - Sherpa map:
    - Enter: send. Shift+Enter: newline (hardware keyboard only).
    - Esc: stop generation / dismiss sheet.
    - Ctrl/⌘+K: new chat. Ctrl/⌘+/: model picker. Ctrl/⌘+↑: edit last message.
    - Y/N on a focused approval card.
  - The 3.47 blog notes keyboard shortcuts can dismiss selection menus [DOC].
- **State restoration:**
  - `MaterialApp.restorationScopeId`, `RestorationMixin`, `RestorableTextEditingController`, `ScrollView.restorationId` [SDK `widgets/restoration.dart:647`, `restoration_properties.dart:470`].
  - The iOS engine's `FlutterSceneDelegate` implements scene `stateRestorationActivity` [SDK `FlutterSceneDelegate.mm`]; **UNVERIFIED** end-to-end with Sherpa's SceneDelegate.
  - Restore only small things: draft text, open conversation id, anchor message id. Everything else rehydrates from the local DB.
- **Selection:**
  - `SelectionArea`/`SelectableRegion` [SDK]. 3.47: handles "remain stable during minor scrolling", plus a crash fix when selection starts in an empty scrollable [DOC blog].
  - Use **one `SelectionArea` per message**, not around the whole list. That bounds selection-geometry work and avoids cross-message drags in a lazily built list.
  - `SystemContextMenu` exists for native iOS edit menus [SDK `widgets/system_context_menu.dart:57`].
- **Secrets on screen:** wrap API-key and token fields in `SensitiveContent(sensitivity: ContentSensitivity.sensitive)`. Android API 35+ then obscures them during screen share; on other platforms it is a no-op [SDK `widgets/sensitive_content.dart`].

### 1.10 Long chat lists and streaming without jank
- **List primitives [SDK]:**
  - `CustomScrollView` + `SliverList.builder` with per-message keys and `findItemIndexCallback`. It replaced `findChildIndexCallback` in 3.41, and it keeps `State` alive when messages are inserted above [DOC breaking-changes].
  - `scrollCacheExtent: ScrollCacheExtent.pixels(…)` / `.viewport(…)` replaces `cacheExtent` (deprecated 3.44) [DOC breaking-changes/scroll-cache-extent; SDK `rendering/viewport.dart:42`].
  - Builder lists already wrap children in `RepaintBoundary` (`addRepaintBoundaries = true`) [SDK `scroll_view.dart:1329`].
  - Avoid `shrinkWrap`, intrinsics and `Opacity` animations [DOC perf/best-practices].
- **Anchoring: two viable designs.**
  - **A. `reverse: true` (index 0 = newest).** The growing message sits at scroll offset 0, so a user pinned to the bottom stays pinned for free. A user scrolled up into history is different: growth of item 0 pushes everything above it up by Δ every frame. Compensate with `position.correctBy(Δ)` or `jumpTo(pixels + Δ)` after layout (`ScrollPosition.correctBy`, SDK `scroll_position.dart:458`).
  - **B. `center:` key (`CustomScrollView(center: liveKey)`).** History goes in a sliver *before* the center (grows upward), and the live turn goes *after* it (grows downward). Reading history is stable for free. Follow mode needs `jumpTo(maxScrollExtent)` once per frame while pinned [SDK `scroll_view.dart:330,359`].
  - **Recommendation:** B, plus a two-state follow machine. **Pinned** (auto-follow) becomes **Detached** on any user drag or fling, or when `extentAfter > 48 px`. Detached shows a "Jump to latest" button with a new-content dot, as ChatGPT does ([MOB] https://mobbin.com/screens/a748d6a3-60ee-4661-903c-17fae0958588). Add a widget test that streams 2k tokens while detached and asserts that the first visible message's `dy` drifts by 0 px.
- **Streaming markdown:**
  - `flutter_markdown` is **discontinued**. Its replacement `flutter_markdown_plus` 1.0.12 (Foresight Mobile) documents no incremental rendering [DOC pub.dev].
  - `gpt_markdown` 1.3.4 (useval.io): "settled segments are reused while the changing tail updates", `SliverGptMarkdown` builds lazily, and it claims 31–74× faster updates at 12 KB versus 1.2.1 [DOC pub.dev; vendor claim].
  - `flutter_ai_toolkit` 1.0.0 (labs.flutter.dev) `LlmChatView` renders with `flutter_markdown_plus` [DOC pub.dev].
- **Sherpa render pipeline (recommended):**
  1. A worker isolate parses SSE or local tokens and emits **coalesced deltas** at most once per vsync. 30 Hz is enough for text; use `SchedulerBinding.scheduleFrameCallback` on receipt.
  2. An incremental block splitter (paragraph, list, fenced code, table, math) marks blocks **final** once a following block starts or a fence closes.
  3. Final blocks become immutable widgets cached by `(messageId, blockIndex, hash)`, each in its own `RepaintBoundary`. Do syntax highlighting and LaTeX layout only on final blocks, off the main isolate.
  4. Only the **live tail block** rebuilds, as a plain `Text.rich` with a cheap parse. Unclosed code fences render as monospace without highlighting.
  5. No per-token fade animations. A caret is fine, disabled under reduce motion.
  6. Structured tool or result cards stream as fixed-height **skeletons** (as Mindtrip does: [MOB] https://mobbin.com/screens/122d988f-464c-487e-9343-0bede153c3ad) so the layout doesn't jump.
- **Generative UI:** `genui` 0.10.4 (labs.flutter.dev; A2UI `createSurface`/`updateComponents`, widget `Catalog`) is a candidate for rich tool-result cards later. It is pre-1.0 [DOC pub.dev].

---

## 2. How AI chat apps handle the hard parts (patterns to copy / avoid)

Evidence is from Mobbin iOS screens captured in 2026 (ChatGPT incl. Codex, Claude, Perplexity, Grok, GitHub Copilot, Granola, Craft), plus the official READMEs and sites of local-LLM apps. Mobbin had **no matching screens for Gemini or Le Chat**; claims about those two are **UNVERIFIED**.

| Concern | What leading apps do | Evidence |
|---|---|---|
| **Streaming & stop** | Send turns into a ■ stop button. The composer stays live and accepts a "Follow up" while the agent runs. A spinner chip sits next to the model/effort chip ("5.5 Medium") | ChatGPT Codex [MOB] https://mobbin.com/screens/d3e5f342-f871-44fc-9dc9-f47b8ace05a4 |
| **Reasoning** | Collapsed to one muted line, "Thought for a couple of seconds ›". Tapping opens a **bottom sheet with a step timeline** (globe icon "Searching…", query chips, "Done"). The answer is never interleaved with raw thoughts | ChatGPT [MOB] https://mobbin.com/screens/3eaf4e44-fdce-48bc-965b-b194ed9c43ac, https://mobbin.com/screens/4fe4b960-ab35-4327-82b0-759ccbb0d825; Mindtrip pill "Thought for 1s" [MOB] https://mobbin.com/screens/122d988f-464c-487e-9343-0bede153c3ad |
| **Reasoning control** | A model-sheet toggle: Claude "Extended – Always uses deep reasoning"; Perplexity per-model "With thinking". AI Edge Gallery "Thinking Mode" toggle (Gemma 4 family) | [MOB] https://mobbin.com/screens/fa4512d1-e46f-434d-8c89-9e83a3d0e090, https://mobbin.com/screens/b8f4ebc1-c7ef-487c-b7e0-85074e19565f; [RAW] google-ai-edge/gallery README |
| **Tool calls** | One-line, past-tense, tappable rows ("Ran pwd ›", "Listed files ›") that **group** ("Ran 3 commands ›"), with a "Thinking" status line. Earlier turns collapse ("18 previous messages ›"). The final message has a summary, artifact links and "Verification run". Perplexity streams step lines with icons ("Gathering research…", "Searching for…") | ChatGPT Codex [MOB] https://mobbin.com/screens/a748d6a3-60ee-4661-903c-17fae0958588, https://mobbin.com/screens/8ebafe46-9984-453e-a420-4c286164f015; Perplexity [MOB] https://mobbin.com/screens/86a8cd56-7ac2-4aa9-a75a-aa968fdbbe2f |
| **Approvals / permissions** | Inline card in the transcript: "ChatGPT wants to connect to Quizzes [Not now] [Connect]", with a "Running app request" status. A permission-mode chip sits in the composer (ChatGPT ✋ "Default"; Claude "Tool access: Auto" in the + sheet). Consent is explicit and destructive ("Disconnect Microsoft 365 … remove access to all the tools"). Risk-explaining copy, as in Coinbase's "Only allow access if…" | [MOB] https://mobbin.com/screens/588c8fba-95a8-4aba-ba28-64f539eb06ca, https://mobbin.com/screens/42bb2da1-3873-4690-858f-dbfd808e6a6b, https://mobbin.com/screens/469f1ceb-9a49-4838-a632-9425a2c1517b, https://mobbin.com/screens/f71dd6ba-9dd5-4eb9-8f53-43665422152d |
| **Agent asks the user** | Claude docks a **paginated question card above the composer** ("1 of 2", numbered options, free-text "Type your answer…", ‹ › and ✕) instead of a modal | [MOB] https://mobbin.com/screens/465d155d-404f-40b5-8fc5-ba686cec318b |
| **Undo instead of confirm** | Applied changes are shown with "Discarded / Undo" affordances | Structured [MOB] https://mobbin.com/screens/03f22cd7-b6f1-42ec-b472-e04e40dc28b2 |
| **Background completion** | "Turn On Response Notifications – feel free to step away"; a notification pre-prompt that lists task types ("Refactor complete", "Research paused – needs your input") | Claude [MOB] https://mobbin.com/screens/795e1600-cad6-4f17-ab49-2dde0f004836, https://mobbin.com/screens/c5cbd6f5-1c04-4111-acee-c0080b68e97f |
| **Model picker** | A composer chip showing model and effort ("Sonnet 4.6 Low"). The sheet lists models with a one-line purpose ("Fastest for quick answers"), **unavailable** rows greyed with a badge, and "More models ›". Other variants: Auto/Best default (Perplexity, GitHub, Granola, Grok), cost tiers ("Use fewer credits"), badges (New/max/Pro/Preview), and Grok's **modes** (Heavy/Expert/Fast/Auto) instead of model names | [MOB] https://mobbin.com/screens/fa4512d1-e46f-434d-8c89-9e83a3d0e090, https://mobbin.com/screens/dd3b0165-b93d-41c1-b8e6-2a40f9988134, https://mobbin.com/screens/a2965031-64bf-4d8d-8116-c323b0c46c95, https://mobbin.com/screens/c67bcedd-a70d-4f27-a63d-1920ce43d40a |
| **Local model download** | Each row shows name, size ("1 GB"), a one-line capability, **"Not Compatible" disabled** rows, and an inline progress ring (Craft). Large downloads are flagged ("up to 4GB, we recommend Wi-Fi", Glow); "Download over Wi-Fi only" toggle (TikTok). PocketPal: search the HF Hub, pick a quantization "that fits your device's memory", bookmark, Load/Unload, load from a chevron in the composer, screen kept awake during inference, benchmark tok/s and memory. Private LLM filters by device and RAM and "recommends" a model. Edge Gallery: model manager + benchmark (TTFT, prefill/decode speed [3P]) | [MOB] https://mobbin.com/screens/ffbffbea-fea3-4599-922c-e448cc506545, https://mobbin.com/screens/604e8790-6642-415a-86ee-c0bae9d2af7a, https://mobbin.com/screens/213e14e2-e561-4fac-8d09-eea6ac32f243; [RAW] a-ghorbani/pocketpal-ai README; [DOC] privatellm.app; [RAW] google-ai-edge/gallery README |
| **Local vs cloud clarity** | Enclave: local by default, optional OpenRouter cloud, "clear indications of when data leaves your device" | [DOC] enclaveai.app |
| **Context / limits** | None of the surveyed screens shows a token or context meter. Claude docks a **usage-limit banner** above the composer ("Limit reached · Resets Tuesday at 12:00am [Upgrade]"); ChatGPT collapses history | [MOB] https://mobbin.com/screens/e4c51fae-e8b6-4e42-8a4c-23d1ec12b06a |
| **Message actions** | Icon row: copy, share, read-aloud, 👍/👎, retry, plus "Sources" with favicons. Regenerated variants get a pager ("‹ 2/2 ›", Grok). Long-press a user message to edit and regenerate; retry "optionally with a different model" (PocketPal) | [MOB] https://mobbin.com/screens/8cf567ec-633b-4d0b-81b8-4e05de5fdb9c, https://mobbin.com/screens/ffae3303-20cb-443f-8dcb-b9cad46a78cd; [RAW] PocketPal README |
| **Errors / offline** | A toast "Something went wrong, try again later" over a partially kept answer (Perplexity). A remote host shows "Offline · Last seen 18 minutes ago · Reconnect" (Codex) | [MOB] https://mobbin.com/screens/89a97c86-1a4e-4d73-b087-f3cf44fdba42, https://mobbin.com/flows/0a126f6c-fd31-4900-ae34-823e516b77bf |

**Other apps:**
- **Locally AI:** reportedly acquired by LM Studio in April 2026; uses MLX-community models [3P ai.engineer]. **UNVERIFIED**.
- **MLC Chat:** MLC LLM's engine runs on iOS (Metal) and Android [RAW mlc-ai/mlc-llm README]; app UX **UNVERIFIED**.
- **LM Playground:** **UNVERIFIED**, no primary source found.

**Copy these:**
1. Collapsed reasoning plus a step-timeline sheet.
2. Grouped past-tense tool rows with drill-down.
3. A permission-mode chip in the composer, with inline approval cards for scoped actions and a modal for destructive ones.
4. A question card docked above the composer for agent→user questions.
5. A model + effort chip, and a picker with purpose lines, availability states and "Recommended for this device".
6. A local model manager showing size, a compatibility gate, Wi-Fi default, resumable progress, Load/Unload and a benchmark.
7. Response notifications for background runs.
8. A jump-to-latest button while detached.
9. Undo for reversible tool effects.

**Avoid these:**
- Live-region streaming text (it floods screen readers).
- Auto-scrolling while the user reads history.
- Raw chain-of-thought expanded by default.
- Approval prompts without visible arguments.
- Modal permission dialogs for low-risk reads; they cause approval fatigue.
- Silent model fallback when a local model doesn't fit RAM. Show "Not Compatible" instead.
- Downloading multi-GB models over cellular by default.
- A **hidden context budget** in an *agent* harness, because compaction then surprises users. Mainstream chat apps hide it; Sherpa shouldn't.
- Per-token haptics or animations.

---

## 3. CI for a Flutter pub-workspace app

### 3.1 Actions and versions (verified 2026-10-18)

| Component | Current | Source |
|---|---|---|
| `subosito/flutter-action` | **`@v2`** (README on `main`). Inputs: `channel`, `flutter-version`, `flutter-version-file` (needs an exact `flutter: x.y.z` in pubspec), `architecture`, `cache`, `pub-cache` (independent; empty falls back to `cache`), `cache-key`/`pub-cache-key` with tokens `:os: :channel: :version: :arch: :hash: :sha256:`, `dry-run`, `git-source`. Internally uses **`actions/cache@v5`**; the pub cache key gets `-${{ hashFiles('**/pubspec.lock') }}` appended. Self-hosted runners need ≥ 2.327.1 | [RAW] subosito/flutter-action `README.md`, `action.yaml`, `setup.sh:130-181` |
| `actions/checkout` | **v7** (7.0.1; node24; blocks fork-PR checkout for `pull_request_target`/`workflow_run`) | [RAW] actions/checkout `CHANGELOG.md` |
| `actions/cache` | **v6** (6.1.0) | [RAW] actions/cache `RELEASES.md` |
| `actions/upload-artifact` | **v7** | [RAW] README |
| `actions/setup-java` | **v6** (Flutter 3.47 verified toolchain: Java 17, AGP 9.1.0, KGP 2.4.0, Gradle 9.3.1) | [RAW] README; [DOC] 3.47 blog |
| `gradle/actions/setup-gradle` | **v6** | [RAW] gradle/actions README |
| `reactivecircus/android-emulator-runner` | **v2** (v2.38.0: build-tools 37.0.0; v2.37 moved to Node 24; v2.36 dropped `--abi` for 16 KB images) | [RAW] `CHANGELOG.md` |
| `google-github-actions/auth` | **v3** | [RAW] README |

### 3.2 Pub workspaces in CI
- **Facts [DOC dart.dev/tools/pub/workspaces]:**
  - Dart ≥ 3.6. Root `workspace:` list; globs need ≥ 3.11. Members declare `resolution: workspace`.
  - **One `pubspec.lock` and one `.dart_tool/package_config.json` at the root**; `pub get` deletes stray member copies.
  - `dart pub workspace list` lists members. `dart pub -C <dir> …` runs pub in a member.
  - Only one version of a package is allowed, and overrides are best kept at the root.
- `dart pub get --enforce-lockfile` exists [SDK CLI help] and should be used in CI.
- **Repo gap found:** the root `pubspec.yaml` lists only `packages/sherpa_core`. `app/` is **not a workspace member** (no `resolution: workspace`) and keeps its own `app/pubspec.lock`. `dart pub workspace list` prints only `sherpa_workspace` and `sherpa_core`. Fix before CI:
  - Add `- app` to `workspace:` and `resolution: workspace` to `app/pubspec.yaml`.
  - Delete `app/pubspec.lock`.
  - Pin `environment: flutter: 3.47.7` in the root, or set `FLUTTER_VERSION` in the workflow.
- **Test loop:** `flutter test` and `dart test` are per package. Iterate over members (`dart pub workspace list`), or use explicit steps: `dart test` in `packages/sherpa_core` (pure Dart, so it runs on the fastest runner), then `flutter test` in `app`. The `github` reporter is the default on Actions, and `--file-reporter json:reports/x.json` is available [SDK CLI help]. Sharding uses `--total-shards/--shard-index`.

### 3.3 Runners and Xcode

| Label | Image | Notes |
|---|---|---|
| `ubuntu-latest` = `ubuntu-24.04` (also `ubuntu-26.04`, `-arm`, `ubuntu-slim`) | Public repo: **4 vCPU / 16 GB**. Private: **2 vCPU / 8 GB** | KVM Android emulation supported on Linux [DOC docs.github.com github-hosted-runners; github.blog 2024-04-02] |
| `macos-latest` = **`macos-26`** arm64 (M1, 3 vCPU / 7 GB) | macOS 26.6.2, image 20260907. Xcode **26.6 (default)**, 26.5, 26.4.1, 26.3, 26.2, 26.1.1, 26.0.1. iOS sims 26.2/26.4/26.5 (iPhone 17/17 Pro/Air/17e, iPads) | [RAW] runner-images `images/macos/macos-26-arm64-Readme.md` |
| `macos-15` arm64 | Default Xcode **16.4**; also 26.0.1–26.3; iOS sims 18.5–26.2 | [RAW] `macos-15-arm64-Readme.md` |
| **`xcode-27`** (preview) arm64 | macOS 27.0.1. Xcode **27.0 default**, 27.1 RC, 27.2 beta 2; iOS 27.0 sims | [RAW] `xcode-27-arm64-Readme.md`; README table |
| `macos-14` | **Deprecated**, fully unsupported **2026-11-02** | [RAW] runner-images announcement banner |

- **arm64 macOS limits:** **no nested virtualization**, so no Android emulator there, and no static UDID [DOC].
- **App Store:** builds must use **Xcode 26+ with an iOS 26 SDK since 2026-04-28**. Since 2026-09-09 uploads must target iOS 13+ (Sherpa: 15) [DOC developer.apple.com/news/upcoming-requirements].
- **flutter_tools:** requires Xcode ≥ 15 and recommends ≥ 16 [SDK `macos/xcode.dart:24-28`].
- **Unsigned iOS builds:**
  - `flutter build ios --simulator` (tests).
  - `flutter build ios --release --no-codesign` (device-arch compile check). `--[no-]codesign` defaults to true [SDK `commands/build_ios.dart:912-932`].
  - `--config-only` regenerates Xcode settings.
  - Raw xcodebuild: `CODE_SIGNING_ALLOWED=NO`.
  - Select Xcode with `sudo xcode-select -s /Applications/Xcode_26.6.app`.

### 3.4 Android emulator on Linux
- **Enable KVM** (verbatim from the action README [RAW]):
  ```bash
  echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' | sudo tee /etc/udev/rules.d/99-kvm4all.rules
  sudo udevadm control --reload-rules && sudo udevadm trigger --name-match=kvm
  ```
- **Inputs:**
  - `api-level` (e.g. `36`), `target` (`google_apis`, `google_atd`, **`google_apis_ps16k`** for 16 KB pages), `arch: x86_64`, `profile`, `cores`, `ram-size`, `disk-size`, `emulator-boot-timeout` (600 s).
  - `disable-animations` (**default true**).
  - Default `emulator-options`: `-no-window -gpu swiftshader_indirect -no-snapshot -noaudio -no-boot-anim`.
  - AVD snapshot caching uses `actions/cache` on `~/.android/avd/*` and `~/.android/adb*` [RAW].
- **Gotcha:** `disable-animations: true` runs `settings put global transition_animation_scale 0.0` [RAW `src/emulator-manager.ts:104-105`]. Flutter maps that to `disableAnimations = true` [SDK `AccessibilityBridge.java:583-588`], so every `AnimationController` runs at 5% duration. Keep it on for functional tests. **Turn it off for perf runs and for animation and golden-on-device checks.**
- **Graphics:** `swiftshader_indirect` is CPU rendering. Emulator frame timings are therefore only good for **catastrophic-regression** gates, never absolute budgets. **UNVERIFIED** which Impeller backend Flutter picks on SwiftShader; log it in the test.
- **16 KB pages:** Play blocks updates that lack 16 KB support for targetSdk ≥ 35 from **2027-02-01**. Check with `zipalign -c -P 16 -v 4 app.apk` (build-tools ≥ 35) and `check_elf_alignment.sh` [DOC developer.android.com/guide/practices/page-sizes]. This matters for native LLM libraries (llama.cpp, LiteRT-LM, MLC).

### 3.5 Golden tests
- `flutter test` passes `--enable-software-rendering --skia-deterministic-rendering --use-test-fonts --disable-asset-fonts` unless you pass `--enable-impeller` [SDK `flutter_tester_device.dart:113-120`]. Goldens are deterministic Skia-software snapshots with **test fonts** (boxes).
- **Real text and icons:** in `test/flutter_test_config.dart` (discovered by `flutter_tools/lib/src/test/test_config.dart:10`), load fonts with `FontLoader('Inter')..addFont(rootBundle.load(...))` and the same for `MaterialIcons`.
- **Determinism:**
  - Generate and compare **only on Linux** (tag `golden`; skip with `Platform.isLinux` in the config).
  - Pin the runner image (`ubuntu-24.04`, not `-latest`).
  - Regenerate with `--update-goldens` in a `workflow_dispatch` job that uploads the PNGs as an artifact, so goldens never come from developer Macs.
  - Allow a tiny tolerance through a custom `LocalFileComparator` subclass (`precisionTolerance` pattern in [SDK `flutter_test/lib/src/goldens.dart:142-178`]).
- **Packages:** `golden_toolkit` is **discontinued** [DOC pub.dev]. `alchemist` 0.14.1 (betterment.dev) separates CI goldens (text obscured, no shadows, host-independent) from platform goldens, with `diffThreshold` [DOC pub.dev].

### 3.6 integration_test on emulators and simulators
- **Run:** `flutter test integration_test -d emulator-5554`. iOS: `xcrun simctl boot "iPhone 17"`, then `flutter test integration_test -d <udid>` [DOC docs.flutter.dev/testing/integration-tests].
- **Native permission and notification dialogs** (model-download notifications, mic) need `patrol` 4.10.0 (leancode.co) with `patrol_cli` [DOC pub.dev].
- **Determinism for agent tests:** drive the UI with a **fake provider** that replays recorded SSE/tool transcripts at a fixed tokens/sec. Never hit real LLMs in CI.

### 3.7 Performance measurement
- **Frame metrics (Flutter-native, works everywhere):**
  - `binding.traceAction(() async {...}, reportKey: 'stream')`, then a `test_driver/perf_driver.dart` with `integrationDriver(responseDataCallback:)`, `TimelineSummary.summarize(...)` and `writeTimelineToFile(..., includeSummary: true)`.
  - Run `flutter drive --driver=test_driver/perf_driver.dart --target=integration_test/stream_perf_test.dart --profile --no-dds` [DOC cookbook/testing/integration/profiling].
  - Output: `build/<name>.timeline_summary.json`. Keys include `average/90th/99th/worst_frame_build_time_millis`, `…_frame_rasterizer_time_millis`, `missed_frame_build_budget_count`, `missed_frame_rasterizer_budget_count`, `frame_count`, `new_gen_gc_count`, `old_gen_gc_count`, `average/90th/99th_vsync_transitions_missed`, `…_frame_request_pending_latency`, `total_ui_gc_time`, `60hz…120hz_frame_percentage`, `…_gpu_frame_time`, `…_gpu_memory_mb` [SDK `flutter_driver/lib/src/driver/timeline_summary.dart:285-377`].
  - Lighter option: `binding.watchPerformance(..., reportKey:)` gives `FrameTiming`-based summaries [SDK `integration_test.dart:382-387`; `flutter_test/lib/src/frame_timing_summarizer.dart:244+`].
- **Startup:** `flutter run --profile --trace-startup` writes `build/start_up_info.json` with `timeToFirstFrameMicros` and `timeToFirstFrameRasterizedMicros` [SDK `tracing.dart:117-198`].
- **Size:** `flutter build apk --release --analyze-size --target-platform android-arm64` (one ABI; incompatible with `--split-debug-info`) [SDK CLI help].
- **Reference devices:**
  - **Firebase Test Lab:**
    - Android: build with `flutter build apk`, `./gradlew app:assembleAndroidTest`, `./gradlew app:assembleDebug -Ptarget=integration_test/x_test.dart`, then `gcloud firebase test android run --type instrumentation --app … --test …`.
    - iOS: `flutter build ios integration_test/x_test.dart --release`, `xcodebuild build-for-testing`, zip `Release-iphoneos` + `*.xctestrun`, then `gcloud firebase test ios run --test ios_tests.zip --device model=…` [SDK `packages/integration_test/README.md:252-370`].
    - iOS artifacts must be signed; Test Lab re-signs the app [DOC firebase run-xctest].
    - Limits: 45 min physical / 60 min virtual.
    - **Deprecated, shutdown 2027-09-30** [DOC].
  - **Developer Device Platform:** Preview, Android-only CLI [DOC/3P]. Plan a migration and don't build deep coupling.
  - **AWS Device Farm:** Android (Appium, Instrumentation) and iOS (Appium, XCTest, XCTest UI). Custom environments are not supported for XCTest [DOC docs.aws.amazon.com/devicefarm test-types]. Flutter's Android instrumentation APK and iOS `RunnerTests` XCTest bundle fit these slots. **UNVERIFIED** end-to-end on Device Farm.
- **Android Macrobenchmark:**
  - `StartupTimingMetric` gives TTID and TTFD [DOC]. `FlutterActivity.onFlutterUiDisplayed()` calls `reportFullyDrawn()` on API 29+ [SDK `FlutterActivity.java:1443-1454`], so **TTFD = first Flutter frame, not "chat ready"**. Add a `TraceSectionMetric` around a custom trace for "transcript ready".
  - `FrameTimingMetric` measures "the main application UI thread and the Compose RenderThread" [DOC]. Flutter frames come from engine threads, so **it is likely meaningless for Flutter** (**UNVERIFIED** inference). Use Flutter `FrameTiming` instead.
  - `PowerMetric` (experimental) works only on physical Pixel 6+ [DOC macrobenchmark-metrics].
- **XCTest:** `XCTApplicationLaunchMetric`, `XCTCPUMetric`, `XCTMemoryMetric`, `XCTClockMetric` and `XCTOSSignpostMetric` in `measure(metrics:)` from a UI-test target. **UNVERIFIED** in this session (from memory; Apple pages not fetched). `XCTCPUMetric` is Apple's suggested energy-regression proxy [DOC/3P developer.apple.com "analyzing your app's battery use"]. UIScrollView hitch metrics won't apply, because Flutter doesn't use UIScrollView.

### 3.8 Enforcing perf budgets
- **Baselines:** commit `perf/baselines/<device-class>/<scenario>.json`. A pure-Dart gate (`tool/perf_gate.dart`) reads `build/*.timeline_summary.json` and fails the job when any metric exceeds `min(abs_max, baseline × (1 + max_regression_pct))`, or when `frame_count < min_frames` (the run is invalid).
- **Noise handling:** take the median of 5 runs on device and 3 on emulator. Emulator gates are relative only (+50%); device gates are relative +10–15% plus absolute caps. Rebaselining needs a PR label `perf-rebaseline` and uploads the new JSON as an artifact for review.
- Example:
  ```json
  {"scenario":"stream_4k_tokens_markdown_pinned","device_class":"android-mid-adreno650-gles",
   "min_frames":600,
   "metrics":{
     "90th_percentile_frame_build_time_millis":{"baseline":5.2,"max_regression_pct":15,"abs_max":8.0},
     "99th_percentile_frame_rasterizer_time_millis":{"baseline":9.8,"max_regression_pct":15,"abs_max":16.0},
     "missed_frame_build_budget_count":{"baseline":3,"max_regression_pct":50,"abs_max":15},
     "old_gen_gc_count":{"baseline":1,"max_regression_pct":100,"abs_max":4}}}
  ```
- **Pure-Dart core** (`sherpa_core`): `benchmark_harness` 2.4.0 (tools.dart.dev; `BenchmarkBase`, `AsyncBenchmarkBase`, `dart run benchmark_harness:bench --flavor aot`) [DOC pub.dev] for the context manager, compaction, token counting and JSON-RPC framing. Use the same gate script.
- **Startup and size gates:** `timeToFirstFrameRasterizedMicros` (device only), and the arm64 APK/IPA size from `--analyze-size` (deterministic, so gate it on every PR).

### 3.9 Energy
- **Android:**
  - The Android Studio **Power Profiler** reads **ODPM** rails (CPU big/mid/little, GPU, display, memory, WLAN, cellular, UFS…) on **Pixel 6+ with Android 10+**. The rails are system-wide, not per app [DOC developer.android.com/studio/profile/power-profiler].
  - The same data is available headless through a Perfetto trace with the `android.power` data source (`collect_power_rails: true`). **UNVERIFIED** config syntax; test it before relying on it.
  - Macrobenchmark `PowerMetric`: Pixel 6+ only [DOC].
  - Battery Historian / `dumpsys batterystats` are legacy. **UNVERIFIED** maintenance status.
  - **Play vitals:** "excessive partial wake locks" counts a session as excessive at > 2 h of cumulative non-exempt wake locks in 24 h. The threshold is violated when ≥ 5% of sessions over 28 days are excessive. From 2026-03-01 such apps "may be excluded from prominent discovery surfaces". Audio and user-initiated transfers are exempt [3P bleepingcomputer/betanews; enforcement details **UNVERIFIED**]. This is directly relevant to background agent runs and local inference.
- **iOS:**
  - Xcode energy gauge.
  - **Instruments Power Profiler** (iPhone with iOS 26+; can record on device away from the desk).
  - Xcode Organizer Battery Usage, and `XCTCPUMetric` in XCTests [DOC developer.apple.com measuring-your-app-s-power-use-with-power-profiler, analyzing-your-app-s-battery-use].
  - **MetricKit** (`MXMetricManager` daily metric and diagnostic payloads) needs a small native Swift plugin. **UNVERIFIED** in this session; known API.
- **Proposed Sherpa metric:** **mWh per 1k generated tokens** (local model) and **mWh per 10-min streaming session** (cloud). Measure weekly on one Pixel (ODPM) and one iPhone (Power Profiler), and track trends rather than gating PRs.

### 3.10 Recommended CI layout

```yaml
# .github/workflows/ci.yml (PR + main)
name: ci
on: { pull_request: {}, push: { branches: [main] } }
concurrency: { group: "${{ github.workflow }}-${{ github.ref }}", cancel-in-progress: true }
env: { FLUTTER_VERSION: "3.47.7" }
jobs:
  core:            # pure Dart, fastest feedback
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v7
      - uses: subosito/flutter-action@v2
        with: { channel: stable, flutter-version: "${{ env.FLUTTER_VERSION }}", cache: true }
      - run: dart pub get --enforce-lockfile          # one root lockfile (workspace)
      - run: dart format --output=none --set-exit-if-changed .
      - run: flutter analyze --fatal-infos
      - run: dart test --coverage=coverage
        working-directory: packages/sherpa_core
  app-tests:       # widget + a11y + goldens (Linux only)
    needs: core
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v7
      - uses: subosito/flutter-action@v2
        with: { channel: stable, flutter-version: "${{ env.FLUTTER_VERSION }}", cache: true }
      - run: flutter pub get --enforce-lockfile
      - run: flutter test --exclude-tags golden --file-reporter json:reports/app.json
        working-directory: app
      - run: flutter test --tags golden
        working-directory: app
      - if: failure()
        uses: actions/upload-artifact@v7
        with: { name: golden-failures, path: app/test/**/failures/ }
  android:         # build + emulator integration (KVM)
    needs: core
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v7
      - uses: actions/setup-java@v6
        with: { distribution: temurin, java-version: "17" }
      - uses: gradle/actions/setup-gradle@v6
      - uses: subosito/flutter-action@v2
        with: { channel: stable, flutter-version: "${{ env.FLUTTER_VERSION }}", cache: true }
      - run: flutter build apk --release --analyze-size --target-platform android-arm64
        working-directory: app
      - run: $ANDROID_HOME/build-tools/37.0.0/zipalign -c -P 16 -v 4 app/build/app/outputs/flutter-apk/app-release.apk
      - name: Enable KVM
        run: |
          echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' | sudo tee /etc/udev/rules.d/99-kvm4all.rules
          sudo udevadm control --reload-rules && sudo udevadm trigger --name-match=kvm
      - uses: actions/cache@v6
        with: { path: "~/.android/avd/*\n~/.android/adb*", key: avd-36-x86_64-v1 }
      - uses: reactivecircus/android-emulator-runner@v2
        with:
          api-level: 36
          target: google_apis
          arch: x86_64
          force-avd-creation: false
          emulator-options: -no-snapshot-save -no-window -gpu swiftshader_indirect -noaudio -no-boot-anim
          working-directory: app
          script: flutter test integration_test -d emulator-5554
  ios:             # compile + simulator smoke (path-filtered to save macOS minutes)
    needs: core
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v7
      - run: sudo xcode-select -s /Applications/Xcode_26.6.app
      - uses: subosito/flutter-action@v2
        with: { channel: stable, flutter-version: "${{ env.FLUTTER_VERSION }}", cache: true }
      - run: flutter build ios --release --no-codesign
        working-directory: app
      - run: |
          UDID=$(xcrun simctl list devices available -j | python3 -c "import json,sys;d=json.load(sys.stdin)['devices'];print(next(x['udid'] for k,v in d.items() if 'iOS-26' in k for x in v if x['name']=='iPhone 17'))")
          xcrun simctl boot "$UDID"; flutter test integration_test/smoke_test.dart -d "$UDID"
        working-directory: app
```

- **Other workflows:**
  - `nightly.yml`: emulator perf with `disable-animations: false` and a relative gate; API 29 and **API 28 (Skia path)** emulator smoke; a `google_apis_ps16k` API 36 run; `flutter test --enable-impeller` goldens as an informational diff.
  - `device-lab.yml` (nightly or on `release/*`):
    - Physical-device perf on FTL now, Developer Device Platform later, or self-hosted.
    - Device matrix: one **Adreno ≤ 650 device (Impeller-GLES path)**, one recent Pixel (Vulkan, ODPM), one Samsung Xclipse, one 4–6 GB RAM low-end, and one iPhone.
    - Gate on `perf/baselines`.
  - `xcode-next.yml` (weekly, `runs-on: xcode-27`, `continue-on-error: true`): `flutter build ios --no-codesign`.
  - `goldens-update.yml` (`workflow_dispatch`): `--update-goldens` on `ubuntu-24.04`, then upload the artifact.
  - `release.yml`: signing secrets, store uploads. Out of scope here.

---

## Recommendations for Sherpa

1. **Design system.**
   - Build on `material_ui` 1.x, not `package:flutter/material.dart`, and run `dart fix --apply --code=migrate_design_widgets` now. The SDK libraries will be deprecated (the 3.47 blog says the November stable).
   - Wrap the app in `MaterialUiCompatibilityBridge` until all dependencies migrate, and audit dependencies for public-API SDK types.
   - Own the "Sherpa" tokens. Treat M3 Expressive as unavailable (IconButton only) and Liquid Glass as **out of scope for v1**: no official support, and no Reduce Transparency signal.
2. **Android manifest and target.**
   - targetSdk 36 is mandatory for Play.
   - Add `android:enableOnBackInvokedCallback="true"` for predictive back on Android 13–15.
   - Support all orientations, and keep the edge-to-edge-safe layout.
   - Consider **minSdk 29**. It removes the Skia path (API 24–28), and on-device LLM work realistically needs it. Product decision.
3. **Adaptive shell.** Implement our own `WindowClass` (600/840/1200/1600). Use NavigationBar below 600 and a rail above. Provide a TwoPane at ≥ 840 or on a vertical hinge/fold (split on `DisplayFeature.bounds`), a tabletop layout for `postureHalfOpened`, and `DisplayFeatureSubScreen` for dialogs.
4. **Transcript engine.** Use the `center`-key `CustomScrollView` with a Pinned/Detached follow machine and a jump-to-latest button. Key items with `findItemIndexCallback`. Use per-message `SelectionArea`. Keep the block-finalizing markdown pipeline with per-frame coalescing, all parsing and highlighting off the root isolate (merged UI/platform thread), and skeleton cards for streaming tool output.
5. **Accessibility.**
   - One debounced live-region **turn-status** node per run; streaming text is never a live region.
   - `headingLevel` on author lines and `customSemanticsActions`.
   - Combine `disableAnimations || reduceMotion`.
   - `meetsGuideline` tests on every chat widget. Manual TalkBack and VoiceOver passes are part of the release checklist.
6. **Agent UX.**
   - Collapsed "Thought for Ns" reasoning with a timeline sheet.
   - Grouped tool rows.
   - A permission-mode chip, with inline scoped approvals ("once / this chat / always") that show exact args and a risk line; destructive actions go in a modal.
   - Agent→user question cards docked above the composer.
   - Undo for reversible effects. Response notifications for background runs.
   - A **context ring** in the composer (used/limit, compaction markers in the transcript), which is Sherpa's differentiator.
7. **Local models.**
   - The manager shows size, RAM-tier compatibility ("Not compatible" disabled), recommended badge, Wi-Fi-only default and resumable downloads with checksum, plus Load/Unload, a benchmark (TTFT, prefill/decode tok/s, peak RSS), and keep-awake only while generating.
   - Mark clearly when a turn leaves the device.
   - Watch the Play wake-lock vital.
8. **CI.**
   - Adopt the layout above: `core` → (`app-tests`, `android`, `ios`) on PRs, plus nightly emulator perf and a device lab.
   - Goldens on Linux only, with fonts loaded in `flutter_test_config.dart`.
   - Fake-provider transcript replay for deterministic agent tests.
   - `patrol` for native dialogs.
   - Fix the workspace first: add `app` as a member and delete `app/pubspec.lock`.
9. **Perf budgets.** Gate APK/IPA size on every PR. Gate emulator frame stats loosely (catastrophic only) and device frame stats tightly, using JSON baselines with a review label. Targets: p90 build < 8 ms and p99 raster < 16 ms during 4k-token streaming on the mid-tier GLES device, and zero scroll drift while detached (functional test).
10. **Device-cloud strategy.** Use FTL for Android and iOS now, but **plan the migration to Developer Device Platform before 2027-09-30**. Keep AWS Device Farm or a self-hosted Mac mini + Pixel as the iOS fallback, because DDP has no iOS yet.

## Risks

- **SDK split churn:** `material_ui` ships weekly. Dependencies lag on SDK types, so you can get type mismatches the bridge can't fix, plus double-import confusion. A deprecation wave lands in the November stable.
- **iOS 26/27 look:** users may perceive non-glass Cupertino chrome as dated. Third-party glass packages are experimental, GPU-heavy (one backdrop copy per layer) and need the Flutter GPU preview.
- **Device fragmentation:** Impeller-GLES devices (Adreno ≤ 650) and Skia devices (API < 29) render and perform differently, and goldens (software Skia) catch neither.
- **Accessibility:** live-region misuse floods TalkBack/VoiceOver. Android deprecates announcements (`supportsAnnounce` false), so cross-platform parity needs two code paths.
- **Emulator perf noise:** SwiftShader CPU rendering, and the `disable-animations` default changes app behavior (5% animation durations). False positives or negatives are likely without device runs.
- **FTL shutdown:** shutdown on 2027-09-30. The DDP successor is Preview and Android-only, so iOS device-farm coverage may need AWS Device Farm or self-hosting.
- **macOS CI cost and capacity:** arm64 runners have 3 vCPU / 7 GB and no nested virtualization. Xcode 27 adoption plus UIScene requirements could break builds when the runner default changes.
- **Store policy:** the 16 KB page-size deadline (2027-02-01) for native inference libraries, and the excessive-wake-lock vital for long background agent runs and local inference.
- **Streaming markdown:** third-party renderers (`gpt_markdown`) are single-vendor. `flutter_markdown_plus` has no streaming story, so we may own a parser.

## Open questions for the product owner

1. Minimum Android API: keep Flutter's default 24 (Skia on 24–28), or set 29+ (Impeller only, better local-LLM baseline)? And iOS minimum: 15 (Flutter's floor) or higher?
2. Is an iOS 26/27 glass look a v1 requirement, or is a neutral Sherpa design system acceptable on both platforms?
3. Should Sherpa show a **context/token meter** and compaction events to all users, or only in an "advanced" mode?
4. Approval policy defaults: which tool classes are auto-allowed, ask-once-per-chat, or always-ask? Must approvals be answerable from notifications (lock screen)?
5. Will agent runs continue in the background (foreground service on Android, background tasks on iOS)? This decides wake-lock and energy budgets and the Play vitals risk.
6. Local model scope for v1: which runtimes (llama.cpp/GGUF, LiteRT-LM, MLX, MLC), which size cap (GB), and are cellular downloads allowed?
7. Device-lab budget: FTL/DDP minutes vs AWS Device Farm vs a self-hosted Pixel + iPhone + Mac mini? Is the repo public (4-vCPU free Linux runners) or private (2 vCPU, billed macOS minutes)?
8. Which reference devices define the perf budgets? At least one Adreno ≤ 650 (GLES path), one 4–6 GB RAM phone and one ProMotion iPhone.
9. Accessibility bar: is WCAG 2.2 AA plus manual TalkBack/VoiceOver sign-off a release gate?

## Verification log (10 most load-bearing claims)

| # | Claim | How verified | Result |
|---|---|---|---|
| 1 | Material/Cupertino ship as `material_ui`/`cupertino_ui` 1.x from 3.47; the in-SDK libraries will be deprecated | Fetched docs.flutter.dev breaking-change page + 3.47 blog. pub.dev API `/api/packages/material_ui` gives latest 1.7.0, published 2026-10-14T18:39Z, `flutter: >=3.47.0`. Changelogs for both packages | Confirmed; deprecation date is "upcoming" (blog: November) |
| 2 | M3 Expressive is limited to the `StyleVariant` enum honored by IconButton; SDK says Expressive springs are unsupported | Downloaded `material_ui-1.7.0.tar.gz` and grepped `material3Expressive` (4 files: theme_data, icon_button_theme, icon_button, button_style). SDK `page_transitions_theme.dart:468`, `color_scheme.dart:51` | Confirmed |
| 3 | Android default page transition is `PredictiveBackPageTransitionsBuilder` (since 3.38), 450 ms; fallback FadeForwards | SDK `page_transitions_theme.dart:764-771`, `predictive_back_page_transitions_builder.dart`; breaking-change page "Landed 3.37.0-0.0.pre / stable 3.38.0" | Confirmed |
| 4 | Predictive back needs `enableOnBackInvokedCallback="true"` on Android 13–15; Android 16 + targetSdk 36 defaults it on; Sherpa manifest lacks it; template doesn't add it | Flutter predictive-back doc; Android 16 behavior-changes page; `grep -rn enableOnBackInvokedCallback` over templates (0 hits) and over app manifest (0 hits) | Confirmed |
| 5 | Impeller backend selection on Android (Vulkan → Impeller-GLES; Skia for API < 29/Vivante) and Vulkan denylist (Adreno ≤ 650 etc.) | SDK `shell/platform/android/flutter_main.cc:34,268-302`, `android_context_dynamic_impeller.cc:154-161`, `impeller/.../driver_info_vk.cc:377-427`; docs.flutter.dev/perf/impeller | Confirmed in source; per-device outcome depends on the driver at runtime |
| 6 | Live-region label changes re-announce the full label (iOS queued announcement; Android content-change event); Android `supportsAnnounce=false`; `announce` deprecated → `sendAnnouncement` | SDK `SemanticsObject.mm:356-369`, `accessibility_bridge.mm:139-150`, `AccessibilityBridge.java:313-325,580,1705-1707`, `lib/ui/window.dart:974-995`, `semantics_service.dart:51-96` | Confirmed (behavior inferred from source, not tested on device) |
| 7 | iOS Reduce Motion → `reduceMotion` only, not `MediaQuery.disableAnimations`; Android "Remove animations" (transition scale 0) → `disableAnimations`; the emulator action's default sets that | SDK `media_query.dart:663-672`, iOS `AccessibilityFeatures.swift:45`, `AccessibilityBridge.java:583-588`; emulator-runner `src/emulator-manager.ts:104-105` | Confirmed |
| 8 | `flutter test` goldens use software Skia + test fonts unless `--enable-impeller` | SDK `flutter_tools/lib/src/test/flutter_tester_device.dart:113-120` | Confirmed |
| 9 | Firebase Test Lab is deprecated, shutdown 2027-09-30; DDP Preview (2026-08-12), Android-only | firebase.google.com/docs/test-lab/android/get-started and /migrate (banner text); search results for docs.cloud.google.com/developer-device-platform overview and release notes | Confirmed for FTL; DDP details from search snippets of official pages (partially verified) |
| 10 | CI versions: flutter-action `@v2` (cache@v5 internal), checkout v7, cache v6, upload-artifact v7, emulator-runner v2.38.0; `macos-latest` = macOS 26 arm64 with Xcode 26.6 default; `xcode-27` preview label; macOS 14 unsupported 2026-11-02 | raw.githubusercontent.com READMEs/CHANGELOGs for each action; runner-images `README.md` + `images/macos/*-Readme.md`; docs.github.com runner reference | Confirmed (github.com UI blocked; raw files used) |

**Not verified this session:**
- Flutter team's June 2025 Liquid Glass statement (flutter#170310).
- XCTest metric class list and MetricKit details.
- Perfetto `android.power` config syntax.
- Macrobenchmark `FrameTimingMetric` behavior with Flutter.
- AWS Device Farm end-to-end with Flutter.
- Gemini, Le Chat, MLC Chat, LM Playground and Locally AI UX specifics.
- Play wake-lock enforcement after 2026-03-01.
