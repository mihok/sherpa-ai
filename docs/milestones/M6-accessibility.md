# M6 — Accessibility and polish audit

Status: **done for every screen outside chat, home and the shell** (2026-10-19). Those three are not
covered here; they were being changed while this audit ran, and their findings are listed at the end for
that work. They have since been audited and fixed the same way: see [Chat, home and shell](#chat-home-and-shell). Everything was checked by widget tests in this container. Nothing has been checked with
TalkBack or VoiceOver yet; see [What needs a device](#what-needs-a-device).

## What was audited

The shared helper is `app/test/support/a11y_audit.dart`. `auditScreen('name', open)` registers one test
for each view in the matrix:

- phone at 360×740;
- tablet at 1200×840;
- text at 1× and at 2×;
- phone in dark mode.

Each test opens the screen through its feature's rig. `expectAudit` then checks the screen at the top and
again after each 0.8-viewport scroll, down to the end:

| Check | How |
|---|---|
| Tap targets | `androidTapTargetGuideline` (48×48) and `iOSTapTargetGuideline` (44×44). After a scroll, `InViewTapTargetGuideline` is used instead, because the stock guidelines measure targets that are clipped off screen |
| Labels | `labeledTapTargetGuideline`; every icon-only button has a tooltip; `excludeSemantics` over something tappable must keep the action and be a `container` |
| Contrast | `textContrastGuideline` (pixel sampling), and `expectExactTextContrast`, which uses the colours in the widget tree. The exact check blends translucent layers, gives large text 3:1, and exempts disabled controls (WCAG 1.4.3) |
| Layout | No RenderFlex overflow (every visible `Row`/`Column` is measured, so overflows count even after their first report) and no exception, so no "A RenderFlex overflowed" either |
| Headings | Every screen has a heading, and no heading is read after the text around it |

**Where pixel contrast was skipped, and why.** `textContrastGuideline` takes the most frequent "dark"
pixel in each text box. On the views below, that pixel is not the glyph colour. The exact check still runs
on every one of them, and passes.

| Screens | Views | What the sample picks up |
|---|---|---|
| Add a provider (OpenAI form); Privacy & data (both states) | tablet 1× (Privacy also phone 1×) | 12 px helper text: an anti-aliasing shade |
| Edit a provider; default model sheet | tablet 1× | a short model name ("gpt-b") has too few solid glyph pixels |
| Export my data and Delete all data dialogs | phone 2× | the scrolling text's box reaches past the dialog onto the dimmed page |
| Diagnostics preview | phone 1× | an `OutlinedButton` label: the outline outnumbers the glyphs |
| Onboarding: connect OpenAI, connect Ollama, key rejected | 1× | small text beside a tinted badge or an icon |
| Model detail (all three states); Hugging Face account, signed out | 1× | 12 px text whose box holds more of the neighbouring surface |
| Tools & servers | phone 2× | a heading under the floating "Add a server" button |
| Add a server (two states), MCP Registry (two states), app: use the internet | tablet 1× | 12–13 px text |
| A chat's tools sheet; form and web page request sheets; app: send a message, open a link | 1× (form sheet also dark; web page sheet phone 1× only) | 12–13 px text |
| What the model sees (and an item); hand off; review an imported handoff | 1× (hand off also dark; review phone 1× only) | 12 px notes beside a card surface |
| Performance lab: Overview, Benchmark, Compare | 1× and dark | 12 px lab notes and chart captions |

**Screens.** There are 79 `auditScreen` entries, so 395 audit tests.

- **Settings** (`test/a11y/audit_settings_test.dart`):
  - Settings, with and without anything set up;
  - Model providers, populated and empty;
  - Add a provider: presets, the OpenAI, Ollama and custom-server forms (with Advanced open);
  - Edit a provider with a saved key; provider not found;
  - Privacy & data (two states); About; page not found;
  - the Export my data, Delete all data and Remove provider dialogs;
  - the Default model sheet; the Diagnostics preview.
- **Onboarding** (`test/a11y/audit_onboarding_test.dart`):
  - Welcome;
  - "Where should your models run", with and without on-device wiring;
  - the on-device teaser sheet;
  - connect OpenAI, connect Ollama (own network), key rejected;
  - pick a model, and none listed;
  - run a model on this phone.
- **Models** (`test/a11y/audit_models_test.dart`):
  - the library, empty and with models; the Delete model dialog;
  - Browse models, including nothing matches;
  - the trusted quantizers sheet and its explanation;
  - model detail: normal, on a 4 GB phone and gated;
  - the "Memory will be tight" sheet;
  - Downloads, populated and empty; the Cancel download dialog;
  - the Hugging Face account, signed out and signed in.
- **Tools & servers** (`test/a11y/audit_mcp_test.dart`):
  - the server list, and built-ins only;
  - Add a server, and after a check;
  - the MCP Registry, and unreachable;
  - server detail, remote and built in; server not found; the server console;
  - review a new tool; the Remove server dialog;
  - Remembered approvals, populated and empty;
  - the sign-in consent sheet; a chat's tools sheet;
  - the input request banner; the form, web page and sampling request sheets;
  - MCP Apps prompts: send a message, open a link, use the internet, run a tool.
- **Context** (`test/a11y/audit_context_test.dart`):
  - What the model sees, and one item; the How context works sheet;
  - Hand off; import a handoff, review it, and a refused import.
- **Performance lab** (`test/features/perf/perf_lab_screen_test.dart`): Overview, Benchmark and Compare.
- **RTL** (`test/a11y/rtl_test.dart`):
  - Settings, Privacy, the library, Browse models, Downloads and the Hugging Face account, under a forced
    right-to-left `Directionality`, with the layout and target checks;
  - the download tile's mirrored geometry;
  - the context level bar painting from the right.

**Source rules** (`test/a11y/source_rules_test.dart`) cover what a widget test can't see, over every
audited file in `lib/`:

- no hard-coded left or right (`EdgeInsets.only(left:)`, an asymmetric `fromLTRB`, `Alignment.centerLeft`,
  `Border(left:)`, `TextAlign.left`, `Positioned(left:)`, `BorderRadius.only(topLeft:)`);
- every `showModalBottomSheet`, `showDialog`, `ExpansionTile` and `DefaultTabController` is given the
  reduced-motion style or duration;
- no `MaterialPageRoute` and no literal animation durations;
- headings go through `Heading`.

## What was fixed

### Semantics

- **Headings.** The new `Heading` in `app/lib/design/widgets/a11y.dart` sets `headingLevel` and
  `header`. In Flutter 3.47, `headingLevel` is what TalkBack (`setHeading`) and VoiceOver
  (`UIAccessibilityTraitHeader`) announce; `header: true` alone is not. Every heading in the audited
  screens uses it, including:
  - `SectionHeader`;
  - `StateView` titles;
  - every `AlertDialog` title;
  - the sub-labels on server detail (level 3).

  `HeadingGroup` fixes groups whose heading was read last: without it, the text next to a heading merged
  into a node that wrapped the heading. It now wraps:
  - cards and sheets: the gated model card, the system models section, the default model sheet's provider
    groups, Privacy's location groups;
  - MCP: the input sheet header, tool review, the MCP Apps and sampling sections;
  - handoff: the facts card, the connections list, the markdown view;
  - the context summary sections and the recommendation banner;
  - the performance lab's Overview, Benchmark and Compare panels.

  Markdown list items in the handoff review are merged into one node each.
- **List counts.** `SectionHeader(count:)` speaks a length after the title without drawing it:
  - the library ("2 models");
  - each Downloads section;
  - Built in and Your servers ("none yet");
  - a server's Tools;
  - Remembered approvals (a new "Allowed without asking" header);
  - the Registry results.

  Browse models sets `semanticChildCount` and a `semanticIndexCallback`, so only the cards count as list
  items. The lazy Resources and Prompts rows on server detail say whether they are expanded and how many
  items they hold.
- **Live regions, only at milestones.** `LiveAnnouncement` puts the announcement in its own label;
  fast-moving text (bytes, tokens per second) stays in child nodes and is never announced. It is used for:
  - download status, through `downloadAnnouncement()`: the phase, plus 25 % steps while downloading;
  - on-device setup and Gemini Nano progress, in onboarding and Settings.

  Plain live regions are used for:
  - server status;
  - onboarding's "Step x of y";
  - the sampling and URL request sheet titles as their stage changes;
  - the Add a server check report and the scanner hints;
  - the model detail fit summary;
  - the Registry's result count.

  The recommendation banner's live region moved from the whole card to its title.
- **Progress indicators** all have labels. Determinate ones also have values:
  - reading a handoff;
  - "The model is writing";
  - Registry search;
  - loading resources;
  - the Hugging Face account;
  - loading more models;
  - the default model sheet;
  - onboarding's "Setup progress, step x of y".

  In 3.47 a non-numeric `semanticsValue` on a progress bar throws.
- **Tap semantics.** The model card and the variant tile used `excludeSemantics` with a tap, but no
  `container`; both now have it. The other fixes:
  - **Tooltips** were made specific: "Copy log", "Clear log", "Add account", and the header's name in the
    headers editor.
  - **Trusted quantizers.** The 32 dp tooltip icon is now a 48 dp "About trusted quantizers" button that
    opens an explanation. This is a visual change.
  - **Gated link.** It was a `SelectableText` with a tiny tap target. It is now plain text; the Copy link
    button already covers it.
  - **Decorative images.** The Hugging Face avatar is excluded from semantics, and the scanner preview is
    labelled "Camera view".

### Reduced motion

- `MotionTokens.style` is `AnimationStyle.noAnimation` when `MediaQuery.disableAnimations` is on, and
  `motionStyleOf(context)` reads it. Every audited bottom sheet, dialog and `ExpansionTile` passes it; the
  framework's own animations for these ignore `disableAnimations`.
- `MotionPageRoute` (`app/lib/design/motion.dart`) replaces `MaterialPageRoute`. It has zero-length
  transitions under reduced motion, and is used by About, the handoff QR pages and the Add a server
  scanner.
- The performance lab's tab swipe uses `motion.tabs`.
- `test/a11y/reduced_motion_test.dart` checks that the default model sheet, the Remove provider dialog,
  the Advanced expansion tile and a pushed page animate normally and open at once under reduced motion.

### Right to left

- Padding, alignment and borders became directional (`EdgeInsetsDirectional`, `AlignmentDirectional`,
  `BorderDirectional`) in 16 files across context, handoff, models, diagnostics, the performance
  lab and providers.
- The context level bar's painter mirrors itself in RTL.
- The benchmark history chart's semantics follow the ambient direction instead of a hard-coded LTR.

### Large text and layout (real overflows the audit found)

- **Model cards** overflowed their metrics row at 2×. At large text the estimate and fit badge now stack
  below the metrics, metrics flex, and names get up to 3 lines (`scaledMaxLines`). Names in download
  tiles, library tiles and server resources get the same extra lines.
- **The "Memory will be tight" sheet** overflowed by 185 px at 2×. It now scrolls, and its buttons wrap
  (`OverflowBar`).
- **The performance lab** app bar shows only the model name at large text. The full title stays as the
  semantics label.

### Polish

- **Width.** On tablets, the model detail download bar and the server console are now held to the
  640 dp reading width (`layout.maxContentWidth`). `SettingsPage` and the list screens already used it.
- **Empty, loading and error states** are audited for:
  - the library, Downloads and providers when empty;
  - Browse models with nothing matching;
  - no remembered approvals;
  - the Registry when unreachable;
  - a refused handoff;
  - providers, servers and pages that are not found.

  The Registry and the Hugging Face account now use `LoadingState` instead of a bare spinner.
- **Copy:**
  - "Remembered approvals" is now the same on the Tools & servers row and the page title;
  - "On-device models" became "Models & downloads", as in Settings, in the Privacy text and the providers
    empty state;
  - "Verifying SHA-256" became "Checking the file is intact (SHA-256)".
- **Dark mode** is in every audit's matrix, with the exact contrast check.
- **Settings › Keep working in the background.** The background-runs tile was added to Settings and
  audited: 48 dp, 2× text, a single labelled switch (`test/a11y/semantics_test.dart`).

### Goldens regenerated (intended)

- `app/test/features/models/goldens/model_directory_{light,dark}.png`: the 48 dp trusted-quantizers
  button moves the content down 16 px.
- `app/test/goldens/goldens/privacy_compact_{light,dark}.png`: the "Models & downloads" copy.

## How to verify

```sh
dart analyze --fatal-infos app
cd app
flutter test --no-pub --concurrency=2 test/a11y test/design/a11y_widgets_test.dart
flutter test --no-pub --concurrency=2 test/features/perf/perf_lab_screen_test.dart --plain-name 'performance lab'
```

`test/a11y/semantics_test.dart` covers the following:

- the counted headings;
- the live announcements (including the 50 % download milestone);
- the labelled progress bars;
- one-node model cards;
- dialog titles as headings;
- focus order in a form sheet (title, who asks, the form, Cancel, Send) and in a dialog (title, body,
  Cancel before the destructive action).

## What needs a device

These are not testable in a widget test, or the tests only show the semantics tree and not what the screen
reader does with it.

- **Live-region timing.** TalkBack (polite) and VoiceOver both announce label changes, but whether a 25 %
  download step interrupts reading in progress, and whether two regions changing together (server status
  and a pill) are both spoken, needs a device.
- **Heading navigation.** Check TalkBack's heading reading control and the VoiceOver rotor on Settings,
  model detail, server detail and the handoff review: every section, in order, with the count after the
  title.
- **Focus into sheets and dialogs.** Check that focus moves to the sheet or dialog title when it opens and
  back to the button that opened it on close. Do this for the default model sheet, the input request
  sheets, the sign-in consent sheet and Remove dialogs.
- **Onboarding step changes.** Onboarding changes step without a route change. Check that "Step 2 of 3"
  is announced and that focus moves to the new step's heading, not to the top of the page.
- **List counts.** On VoiceOver, check list counts on Browse models: iOS does not read
  `semanticChildCount` the way TalkBack reads collection info.
- **Camera scanner pages** (Add a server › Scan, handoff QR): check the "Camera view" label, the live hint
  and the way out with a screen reader on.
- **Framework widgets:**
  - The `DropdownMenu` in the provider form (API flavour) and the lab's dropdowns: check the menu's own
    semantics.
  - `showDatePicker` in elicitation forms: it has no animation style, so it ignores reduced motion.
  - `showLicensePage` from About: a framework route that is not reduced-motion aware.
- **System settings, end to end:**
  - Dynamic Type and Android font scale up to 200 %, compared with the 2× test scale. Real fonts wrap
    differently from the test font.
  - iOS Reduce Motion and Android "Remove animations".
  - Bold text and high contrast.
- **A real RTL locale.** The app ships English only, so RTL was forced in tests. The performance lab's
  history and range charts are not mirrored; only their semantics follow the direction.
- **Switch Access and keyboard** traversal on tablets.

## Findings for chat, home and the shell

These came from the same rules, run over `app/lib/features/chat/**`, `app/lib/features/home/**` and
`app/lib/shell/**`. They were not changed here.

- **Sheets that ignore reduced motion.** These have no `sheetAnimationStyle: motionStyleOf(ctx)`:
  - `chat/model_picker_sheet.dart:40`;
  - `chat/links/reply_links.dart:167`;
  - `chat/widgets/approval_card.dart:465`;
  - `chat/widgets/attachment_views.dart:186`;
  - `chat/widgets/context_ring.dart:169`;
  - `home/sessions_list.dart:198`.
- **Hard-coded left/right (RTL):**
  - `EdgeInsets.only(left/right)`:
    - `chat/widgets/composer.dart:601` and `:767`;
    - `chat/widgets/chat_notices.dart:186`;
    - `chat/widgets/attachment_views.dart:51`;
    - `chat/widgets/context_ring.dart:321`.
  - `Alignment.centerLeft/Right`: `home/sessions_list.dart:165` and `:172`.
  - Asymmetric `EdgeInsets.fromLTRB`:
    - `chat/widgets/composer.dart:476`;
    - `chat/widgets/chat_notices.dart:134` and `:318`;
    - `chat/background/background_widgets.dart:31`;
    - `chat/widgets/approval_card.dart:436`;
    - `chat/widgets/tool_call_card.dart:368`;
    - `chat/widgets/json_view.dart:114`;
    - `home/sessions_pane.dart:73`.
- **Headings.** These use a raw `Semantics(headingLevel:)` instead of `Heading` (or `HeadingGroup`
  around their group), so `header` is missing and the text next to them can be read first:
  - `chat/chat_screen.dart:508` and `:595`;
  - `chat/local_model_picker_section.dart:95`;
  - `chat/model_picker_sheet.dart:99` and `:202`;
  - `chat/prompt_arguments_sheet.dart:79`;
  - `chat/links/reply_links.dart:190`;
  - `chat/widgets/approval_card.dart:149`;
  - `chat/widgets/assistant_turn.dart:123`;
  - `chat/widgets/attachment_views.dart:223`;
  - `chat/widgets/chat_notices.dart:150` and `:273`;
  - `chat/widgets/context_ring.dart:200`;
  - `chat/widgets/user_message.dart:92` and `:212`;
  - `home/sessions_pane.dart:26` and `:78`.
- **Excluded from the source rules.** To cover these paths, remove them from `_audited` in
  `source_rules_test.dart` once the issues above are fixed.

## Chat, home and shell

Status: **done** (2026-10-19), with the same helper, matrix and rules as above. Every finding listed in
the previous section is fixed, and the audit found more, listed below. As before, nothing has been
checked with TalkBack or VoiceOver yet; see [What needs a device](#what-needs-a-device-1).

### What was audited

There are 31 more `auditScreen` entries, so 147 more audit tests. 5 of them are skipped (see
[Outside these areas](#outside-these-areas)).

- **Chat** (`test/a11y/audit_chat_test.dart`, over `ChatHarness` with the app's `SherpaTheme`; the rig is
  `test/a11y/support/chat_rig.dart`):
  - a new chat; no model set up;
  - a reply streaming (mid-reply, Stop showing);
  - tool cards: one opened, and a group of three opened;
  - an approval: a sheet on phones, docked on tablets;
  - an approval waiting: the reminder bar after the sheet is swiped away (phone views only: tablets
    keep the card docked);
  - an MCP App view on sherpa_webview's fake platform (the rig moved to
    `test/features/chat/support/app_chat.dart`);
  - attachments: a sent photo and file under the bubble, and both waiting in the composer;
  - the composer: the command menu, mention suggestions with a picked chip, and a prompt's argument
    hint;
  - notices (a cut-off tool call), a stopped reply, an error with Details open, an interrupted run;
  - sheets: the attach sheet, prompt arguments, the model picker (also with models on this device), the
    context ring sheet, and the link confirm sheet.
- **Home and the shell** (`test/a11y/audit_home_test.dart`, the real router and shell over `Harness`):
  - the chats list. On tablets this is the rail, the sessions pane and the "pick a chat" pane;
  - nothing set up; the first chat; a search with no matches; no archived chats;
  - a chat's actions (long press);
  - a chat open: the real chat screen, full screen on phones and beside the list on tablets;
  - offline (the banner);
  - Settings from the rail (tablet views only: phones have no rail);
  - the rail beside one pane, at a medium 720 × 1000 window, 1× and 2×. The matrix's phone and large
    tablet never show this layout.

**Where pixel contrast was skipped, and why.** The exact check still runs on every one of these and
passes. For example, the context sheet's token counts are `#171d1d` on `#eff5f5` (16:1), but at 14 px
the thin digits of "111" leave fewer glyph pixels than anti-aliasing shades.

| Screens | Views | What the sample picks up |
|---|---|---|
| An approval | 1× | 12 px risk detail in a tinted box: the tint and its border |
| Attach sheet; a stopped reply; link confirm sheet; home's first chat | 1× (link sheet and home tablet only) | 12 px text: an anti-aliasing shade |
| Context ring sheet | 1× | 14 px digits ("111 tokens") |

**Other tests:**
- `test/a11y/chat_semantics_test.dart`:
  - **Streaming.** A reply streams 20 tokens. The only things any live region says are "Assistant is
    responding" and, once it ends, "Response complete". The reply text is never in a live region.
  - **Turns.** Each turn is a level-2 heading ("You", "Sherpa") with its actions, and the message is a
    separate node under it.
  - **Approval.** The approval heading comes before the risk.
  - **Model chip.** At large text on a phone, the model chip moves below the title.
- `test/a11y/rtl_test.dart`:
  - the chat, audited right to left: the user's bubble is at the left (trailing) edge, replies start at
    the right, and the composer is mirrored;
  - home, audited right to left: a swipe towards the end edge reveals Archive at the start edge;
  - the rail sits at the start edge, and with a notch on each side every pane keeps only its outer inset
    (LTR and RTL).
- `test/a11y/reduced_motion_test.dart`: the model picker, the chat's More menu and a chat's long-press
  actions open at once under reduced motion.

### What was fixed

- **Reduced motion:**
  - Every sheet passes `sheetAnimationStyle: motionStyleOf(context)`: the model picker, prompt
    arguments, the link sheet, the approval sheet, the attach sheet, the context sheet and a chat's
    actions. Prompt arguments was missed by the source rule, which did not read nested type arguments
    (`showModalBottomSheet<Map<String, String>>`).
  - Popup menus ignore `disableAnimations` too. The chat's More menu, home's More menu and a message's
    Edit/Copy menu pass `popUpAnimationStyle`.
  - A chat's swipe uses the framework's timings, or none under reduced motion.
  - These areas have no dialogs, expansion tiles or `MaterialPageRoute`.
- **Right to left:**
  - Every listed padding and alignment is directional (`EdgeInsetsDirectional`, `AlignmentDirectional`);
    symmetric `fromLTRB` stays.
  - The user's bubble stays at the end edge in both directions; its tail corner was already directional.
  - Found by re-grepping:
    - **The shell's insets.** The shell removed the rail's right inset and the detail pane's left one,
      so in RTL each pane lost its outer inset and kept its inner one. It now picks the side from the
      text direction.
    - **The reasoning chevron.** It mirrors in RTL, so it pointed up when opened; it now turns the other
      way.
    - **The archived empty state** said "Swipe a chat to the right"; it now follows the text direction.
- **Headings:**
  - Every `Semantics(headingLevel:)` is a `Heading`, and so is the notifications prompt's
    `header: true`. In 3.47 `header: true` alone is not announced.
  - **Turns.** "You" and "Sherpa" go through a new `TurnHeading` (`chat/widgets/transcript.dart`): a
    level-2 heading that carries the turn's actions, with the message, chips and buttons as separate
    nodes under it.
  - **`HeadingGroup` wraps:**
    - the empty chat;
    - the sheets: link, prompt arguments, attach and context;
    - the model picker's provider and on-device sections;
    - the error card and the setup panel;
    - the notifications prompt;
    - the approval card.
  - **The approval card's heading** now says "Approval needed. Allow “…”?". The group around it is no
    longer labelled, so the heading is read first, not after a summary.
  - **A chat's actions sheet** now has the chat's title as its heading, so it says which chat it acts
    on. This is a visual change.
- **Semantics** (found by the audit):
  - **The transcript's label.** The transcript was a container labelled "Conversation", so every turn's
    heading was read after it. It is now unlabelled; the turns name themselves.
  - **Live regions with `container`.** Three live regions had no `container`, so their text merged into
    the screen around them: the prompt argument hint, the blocked-attachment reason and "Getting
    /prompt…". The hint was read before the empty chat's heading.
  - **Session rows.** Each row used `excludeSemantics` with a tap but no `container`, like the M6 model
    cards; it now has `container`.
  - **Jump to latest** keeps its action while hidden; `ExcludeSemantics` already removes it then.
  - **Tool cards.** An open tool card's details are separate nodes, and its header is excluded, because
    the card's own node already says the header and toggles it.
  - **Selectable text.** Tool results, JSON previews, error details and a link's full address were
    `SelectableText`: a focusable text-field node one line tall, whose long-press target failed 48 dp.
    They are now `Text` in a `SelectionArea`: still selectable, and Copy buttons cover all of them.
- **Tap targets.** The remove buttons on the composer's attachment and resource chips, and the
  dictation line's Dismiss, used compact density (40 dp). They are now 48 dp, which makes those chips
  4 dp taller.
- **Large text** (real problems):
  - **The chat's title.** In the shell at 2× on a 360 dp phone, the back button, the model chip, the
    context ring and the menu left the title 42 dp, and it drew nothing at all. At 1.2× and above on a
    phone, the model chip now has its own row under the title. This is a visual change, only at large
    text.
  - **Loading rows.** "Checking which models fit…" and "Loading models…" overflowed the model picker at
    2× (by 81 px); their text now wraps.

**Source rules.** Chat, home and the shell are no longer in `_audited`'s exclusions; only `lib/state/` and
`lib/services/`, which draw no UI, still are. The rules changed in these ways:

- **The call scanner.** It reads nested type arguments, and a self-test covers it.
- **Left/right on whole calls.** `EdgeInsets.only`, `Border`, `BorderRadius.only` and `Positioned` are
  checked on their top-level arguments, so a call split over lines is still caught.
- **One physical side.** A literal `SafeArea(left/right: false)` or `removePadding(removeLeft/Right:
  true)` on one side only fails; this would have caught the shell.
- **`header: true`** without `Heading` fails.
- **SnackBar display times** split over lines are not taken for animation durations.

**Goldens.** None were regenerated. All of them, the chat goldens included, are unchanged: the RTL and
padding fixes are invisible in LTR, and none of the visual changes above (the large-text chip row, the
48 dp chip buttons, the actions sheet's title) is in a golden.

### Outside these areas

These were found but not changed, because they are outside chat, home and the shell:

- **The MCP App view's "Open full screen" button.** In `packages/sherpa_webview/lib/src/widget/view.dart`
  (`McpAppSourceLabel`), it is 40 dp (`VisualDensity.compact`). With the standard density, the
  "chat: an MCP App view" audit passes in all five views. That was checked, then reverted. Until it is
  fixed, the entry is skipped by `_webviewExpandButtonAt40dp` in `audit_chat_test.dart`.
- **Settings › Model providers.** The More menu (`features/settings/providers_screen.dart`) has no
  `popUpAnimationStyle`. A source rule for popup menus would flag it, so none was added.
- **Snack bars** slide in under reduced motion. `MaterialApp.snackBarAnimationStyle` is not set
  (`lib/app.dart`).

### What needs a device

- **Streaming.** Check that TalkBack and VoiceOver say "Assistant is responding" once, stay quiet while
  the reply streams, and say "Response complete" when it ends. Also check this while the user is reading
  an earlier message.
- **Turns.** Check heading navigation (TalkBack's reading control, the VoiceOver rotor) from turn to
  turn. Also check that a turn's custom actions (Copy, Edit, Retry) are offered on its heading.
- **The approval sheet.** Check that focus moves to "Approval needed…" when the sheet opens by itself,
  and back to the composer when it closes. Check the same for the reminder bar's Review.
- **Swipes.** Check a chat's custom actions (Archive, Delete) and its long press with a screen reader,
  and the swipe with Switch Access.
- **Selection.** `SelectionArea` in tool results and error details, with TalkBack's and VoiceOver's text
  selection.
- **The model chip row** at real 130–200 % font sizes, on a small and a large phone.
- **RTL.** A real RTL locale for the chat, the sessions list and the rail. Check a notch in landscape on
  both sides.
- **MCP App views.** The WebView's own accessibility: the platform view's content is not in Flutter's
  semantics tree.
