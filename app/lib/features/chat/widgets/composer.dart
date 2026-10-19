import 'dart:async';

import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../../design/tokens.dart';
import '../../../services/mcp/composer_sources.dart';
import '../attachments/attachment_policy.dart';
import '../attachments/composer_attachments.dart';
import '../dictation/dictation.dart';
import 'attachment_views.dart';
import 'chat_style.dart';
import 'source_chips.dart';

/// A built-in `/command`.
@immutable
class SlashCommand {
  const SlashCommand({required this.name, required this.description, required this.icon, this.enabled = true});

  /// Without the slash: `new`, `retry`, `model`.
  final String name;
  final String description;
  final IconData icon;
  final bool enabled;
}

/// What the composer shows while editing an earlier message.
@immutable
class ComposerEditing {
  const ComposerEditing({required this.onCancel});
  final VoidCallback onCancel;
}

/// The message box.
///
/// * Grows from one to six lines, then scrolls.
/// * Send turns into a prominent Stop while a run is active; Stop is the
///   one control that is always visible during a run.
/// * Hardware keyboards: Enter sends, Shift+Enter inserts a newline (and an
///   IME composition is never interrupted), Esc stops, Ctrl/⌘+↑ edits the
///   last message.
/// * Typing `/` lists the built-in commands and the prompts of the chat's
///   tool servers ([promptCommands], `/server:prompt`); ↑/↓ and Enter pick
///   one. A prompt that takes arguments is typed out (`/server:prompt
///   topic="…"`) and runs on send ([onPromptCommand]).
/// * Typing `@` asks for resource suggestions ([onMentionQuery], answered
///   through [mentionSuggestions]); a picked one becomes a chip that is
///   sent with the message.
/// * "Attach" ([onAttach]) adds photos and files to [attachments]; they
///   show as chips with a remove button and go with the next message.
///   Sending waits while a photo is being prepared, and is blocked (with
///   the reason) when the model can't take what is attached.
/// * The microphone ([dictation]) types what the user says into the field
///   (on-device recognition where the platform offers it); nothing is sent
///   until the user taps Send.
class ChatComposer extends StatefulWidget {
  const ChatComposer({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.running,
    required this.canSend,
    required this.onSend,
    required this.onStop,
    required this.commands,
    required this.onCommand,
    this.hintText = 'Message',
    this.editing,
    this.onEditLast,
    this.promptCommands = const [],
    this.onPromptCommand,
    this.mentionSuggestions = const [],
    this.onMentionQuery,
    this.onSendWithMentions,
    this.attachments,
    this.attachmentPolicy = AttachmentPolicy.textOnly,
    this.onAttach,
    this.dictation,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool running;

  /// False while the chat can't send (loading, no provider).
  final bool canSend;
  final void Function(String text) onSend;
  final VoidCallback onStop;
  final List<SlashCommand> commands;
  final void Function(SlashCommand command) onCommand;
  final String hintText;
  final ComposerEditing? editing;
  final VoidCallback? onEditLast;

  /// Slash commands from MCP prompts. Their names, titles and descriptions
  /// come from the server and are shown as such.
  final List<McpPromptCommand> promptCommands;

  /// Runs [McpPromptCommand] with what was typed after it, plus the
  /// resources picked with `@`.
  final void Function(McpPromptCommand command, String arguments, List<McpResourceSuggestion> mentions)?
      onPromptCommand;

  /// Suggestions for the `@` query last reported through [onMentionQuery].
  final List<McpResourceSuggestion> mentionSuggestions;

  /// What the user typed after `@` at the cursor; null when not mentioning.
  /// Null itself: mentions are off.
  final void Function(String? query)? onMentionQuery;

  /// Sends the text together with the picked resources (falls back to
  /// [onSend] when none are picked).
  final void Function(String text, List<McpResourceSuggestion> mentions)? onSendWithMentions;

  /// Photos and files waiting to be sent; the screen takes them on send.
  final ComposerAttachments? attachments;

  /// What the chat's model accepts (to explain a blocked send).
  final AttachmentPolicy attachmentPolicy;

  /// Opens the attach sheet. Null hides the Attach button.
  final VoidCallback? onAttach;

  /// Dictation into the field. Null hides the microphone.
  final ComposerDictation? dictation;

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

/// One row of the composer's pop-up menu (a command or a mention).
final class _MenuEntry {
  const _MenuEntry({
    required this.title,
    required this.description,
    required this.icon,
    required this.onSelect,
    this.source,
    this.enabled = true,
  });

  final String title;
  final String? description;
  final IconData icon;
  final VoidCallback onSelect;

  /// The tool server the entry comes from (its text is the server's).
  final String? source;
  final bool enabled;
}

class _ChatComposerState extends State<ChatComposer> {
  int _highlight = 0;

  /// Resources picked with `@`, sent with the next message.
  final List<McpResourceSuggestion> _mentions = [];

  /// The `@` token at the cursor: where it starts and what follows it.
  ({int start, String query})? _mentionToken;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onText);
    widget.focusNode.addListener(_onFocus);
    widget.attachments?.addListener(_onAttachments);
    widget.dictation?.addListener(_onAttachments);
  }

  void _onAttachments() => setState(() {});

  @override
  void didUpdateWidget(ChatComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onText);
      widget.controller.addListener(_onText);
    }
    if (!identical(oldWidget.focusNode, widget.focusNode)) {
      oldWidget.focusNode.removeListener(_onFocus);
      widget.focusNode.addListener(_onFocus);
    }
    if (!identical(oldWidget.attachments, widget.attachments)) {
      oldWidget.attachments?.removeListener(_onAttachments);
      widget.attachments?.addListener(_onAttachments);
    }
    if (!identical(oldWidget.dictation, widget.dictation)) {
      oldWidget.dictation?.removeListener(_onAttachments);
      widget.dictation?.addListener(_onAttachments);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onText);
    widget.focusNode.removeListener(_onFocus);
    widget.attachments?.removeListener(_onAttachments);
    widget.dictation?.removeListener(_onAttachments);
    super.dispose();
  }

  void _onText() {
    final token = _currentMentionToken();
    final changed = token?.query != _mentionToken?.query || (token == null) != (_mentionToken == null);
    setState(() {
      _highlight = 0;
      _mentionToken = token;
    });
    if (changed) widget.onMentionQuery?.call(token?.query);
  }

  /// `@word` ending at the cursor (after a space or at the start), while
  /// mentions are on and an earlier message isn't being edited.
  ({int start, String query})? _currentMentionToken() {
    if (widget.onMentionQuery == null || widget.editing != null) return null;
    final v = widget.controller.value;
    final caret = v.selection.isValid && v.selection.isCollapsed ? v.selection.baseOffset : v.text.length;
    if (caret < 0 || caret > v.text.length) return null;
    final before = v.text.substring(0, caret);
    final at = before.lastIndexOf('@');
    if (at < 0 || (at > 0 && !RegExp(r'\s').hasMatch(before[at - 1]))) return null;
    final query = before.substring(at + 1);
    if (query.contains(RegExp(r'\s'))) return null;
    return (start: at, query: query);
  }

  void _pickMention(McpResourceSuggestion s) {
    final token = _mentionToken;
    final v = widget.controller.value;
    if (token != null) {
      final end = token.start + 1 + token.query.length;
      final text = v.text.replaceRange(token.start, end.clamp(0, v.text.length), '');
      widget.controller.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: token.start));
    }
    setState(() {
      if (!_mentions.any((m) => m.mention == s.mention)) _mentions.add(s);
      _mentionToken = null;
    });
    widget.onMentionQuery?.call(null);
    widget.focusNode.requestFocus();
  }

  void _removeMention(McpResourceSuggestion s) => setState(() => _mentions.removeWhere((m) => m.mention == s.mention));

  /// The prompt command the text starts with (`/server:prompt`, then a
  /// space or the end).
  ({McpPromptCommand command, String rest})? get _promptInvocation {
    final t = widget.controller.text;
    if (!t.startsWith('/')) return null;
    final m = RegExp(r'^/(\S+)(?:\s+([\s\S]*))?$').firstMatch(t);
    if (m == null) return null;
    final name = m[1]!.toLowerCase();
    final c = widget.promptCommands.where((c) => c.command == name).firstOrNull;
    return c == null ? null : (command: c, rest: m[2] ?? '');
  }

  void _onFocus() => setState(() {});

  bool get _hasText =>
      widget.controller.text.trim().isNotEmpty || _mentions.isNotEmpty || (widget.attachments?.isNotEmpty ?? false);

  /// Why the attachments can't go with this model (it changed since).
  String? get _blocked => widget.attachments?.blockedReason(widget.attachmentPolicy);

  /// A photo is still being prepared, or what is attached can't be sent.
  bool get _attachmentsHold => (widget.attachments?.busy ?? false) || _blocked != null;

  /// Commands matching a leading `/word` (no spaces yet).
  List<SlashCommand> get _matches {
    final t = widget.controller.text;
    if (!t.startsWith('/') || t.contains(RegExp(r'\s'))) return const [];
    final q = t.substring(1).toLowerCase();
    return widget.commands.where((c) => c.name.startsWith(q)).toList();
  }

  /// Prompt commands matching a leading `/word`.
  List<McpPromptCommand> get _promptMatches {
    final t = widget.controller.text;
    if (widget.promptCommands.isEmpty || !t.startsWith('/') || t.contains(RegExp(r'\s'))) return const [];
    final q = t.substring(1).toLowerCase();
    return widget.promptCommands
        .where((c) => c.command.startsWith(q) || c.command.contains(':$q') || c.label.toLowerCase().startsWith(q))
        .toList();
  }

  /// What the pop-up menu shows now: mention suggestions while typing
  /// `@…`, otherwise matching commands.
  List<_MenuEntry> get _menu {
    if (_mentionToken != null) {
      return [
        for (final s in widget.mentionSuggestions)
          _MenuEntry(
            title: '@${s.mention}',
            description: s.label == s.resource.name ? s.resource.description : s.label,
            icon: Icons.alternate_email_rounded,
            source: s.serverName,
            onSelect: () => _pickMention(s),
          ),
      ];
    }
    return [
      for (final c in _matches)
        _MenuEntry(title: '/${c.name}', description: c.description, icon: c.icon, enabled: c.enabled, onSelect: () => _run(c)),
      for (final c in _promptMatches)
        _MenuEntry(
          title: '/${c.command}',
          description: c.description ?? (c.label == c.prompt.name ? null : c.label),
          icon: Icons.extension_outlined,
          source: c.serverName,
          onSelect: () => _pickPrompt(c),
        ),
    ];
  }

  void _submit() {
    if (widget.running || !widget.canSend || !_hasText || _attachmentsHold) return;
    final exact = _matches.where((c) => '/${c.name}' == widget.controller.text.trim()).firstOrNull;
    if (exact != null) return _run(exact);
    final prompt = _promptInvocation;
    if (prompt != null && widget.onPromptCommand != null) return _runPrompt(prompt.command, prompt.rest);
    final mentions = List.of(_mentions);
    if (mentions.isNotEmpty && widget.onSendWithMentions != null) {
      setState(_mentions.clear);
      widget.onSendWithMentions!(widget.controller.text, mentions);
      return;
    }
    widget.onSend(widget.controller.text);
  }

  void _run(SlashCommand c) {
    if (!c.enabled) return;
    widget.controller.clear();
    widget.onCommand(c);
  }

  /// From the menu: a prompt without arguments runs at once; one with
  /// arguments is typed out so they can follow.
  void _pickPrompt(McpPromptCommand c) {
    if (c.arguments.isEmpty) return _runPrompt(c, '');
    final text = '/${c.command} ';
    widget.controller.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
    widget.focusNode.requestFocus();
  }

  void _runPrompt(McpPromptCommand c, String rest) {
    if (widget.running || !widget.canSend) return;
    final mentions = List.of(_mentions);
    setState(_mentions.clear);
    widget.controller.clear();
    widget.onPromptCommand?.call(c, rest, mentions);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    final key = event.logicalKey;
    final matches = _menu;
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      if (keys.isShiftPressed) return KeyEventResult.ignored; // newline
      if (widget.controller.value.composing.isValid) return KeyEventResult.ignored; // IME commit
      if (matches.isNotEmpty) {
        final entry = matches[_highlight.clamp(0, matches.length - 1)];
        if (entry.enabled) entry.onSelect();
      } else {
        _submit();
      }
      return KeyEventResult.handled;
    }
    if (matches.isNotEmpty && (key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.arrowUp)) {
      setState(() {
        final step = key == LogicalKeyboardKey.arrowDown ? 1 : -1;
        _highlight = (_highlight + step) % matches.length;
      });
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (matches.isNotEmpty && _mentionToken != null) {
        setState(() => _mentionToken = null);
        widget.onMentionQuery?.call(null);
        return KeyEventResult.handled;
      }
      if (matches.isNotEmpty) {
        widget.controller.clear();
        return KeyEventResult.handled;
      }
      if (widget.running) {
        widget.onStop();
        return KeyEventResult.handled;
      }
      if (widget.editing != null) {
        widget.editing!.onCancel();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.arrowUp &&
        (keys.isControlPressed || keys.isMetaPressed) &&
        widget.controller.text.isEmpty &&
        widget.onEditLast != null) {
      widget.onEditLast!();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final motion = chatMotionOf(context);
    final matches = _menu;
    final invocation = _promptInvocation;
    final showAttach = widget.onAttach != null && widget.attachments != null && widget.editing == null;
    final sendable = widget.canSend && _hasText && !_attachmentsHold;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (matches.isNotEmpty)
          _SlashMenu(
            entries: matches,
            highlight: _highlight.clamp(0, matches.length - 1),
            label: _mentionToken != null ? 'Resources' : 'Commands',
          ),
        if (invocation != null && invocation.command.arguments.isNotEmpty && matches.isEmpty)
          _PromptHint(command: invocation.command, rest: invocation.rest),
        if (widget.attachments case final attachments? when attachments.isNotEmpty)
          ComposerAttachmentChips(attachments: attachments, blockedReason: _blocked),
        if (_mentions.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(bottom: tokens.space.xs),
            child: Wrap(
              spacing: tokens.space.xs,
              runSpacing: tokens.space.xs,
              children: [
                for (final m in _mentions)
                  ResourceChip(
                    key: ValueKey('mention:${m.mention}'),
                    label: m.label,
                    serverName: m.serverName,
                    onRemove: () => _removeMention(m),
                  ),
              ],
            ),
          ),
        if (widget.dictation case final d? when d.listening || d.problem != null)
          _DictationLine(dictation: d),
        if (widget.editing != null)
          Padding(
            padding: EdgeInsets.only(bottom: tokens.space.xs),
            child: Row(
              children: [
                SizedBox(width: tokens.space.md),
                Icon(Icons.edit_outlined, size: ChatIconSize.small, color: theme.colorScheme.primary),
                SizedBox(width: tokens.space.sm),
                Expanded(
                  child: Text(
                    'Editing your message — sending creates a new version',
                    style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary),
                  ),
                ),
                TextButton(onPressed: widget.editing!.onCancel, child: const Text('Cancel')),
              ],
            ),
          ),
        DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(tokens.radius.xl),
            border: Border.all(
              color: widget.focusNode.hasFocus ? theme.colorScheme.outline : theme.colorScheme.outlineVariant,
            ),
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              showAttach ? tokens.space.xxs : tokens.space.lg,
              tokens.space.xxs,
              tokens.space.xs,
              tokens.space.xxs,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (showAttach)
                  IconButton(
                    key: const ValueKey('composer-attach'),
                    tooltip: 'Attach photos or files',
                    onPressed: widget.onAttach,
                    style: IconButton.styleFrom(minimumSize: Size.square(tokens.space.minTouchTarget)),
                    icon: const Icon(Icons.add_rounded),
                  ),
                Expanded(
                  child: Focus(
                    canRequestFocus: false,
                    skipTraversal: true,
                    onKeyEvent: _onKey,
                    // The field's own padding (not an outer Padding) makes the
                    // whole 48dp row tappable and focusable.
                    child: TextField(
                      controller: widget.controller,
                      focusNode: widget.focusNode,
                      minLines: 1,
                      maxLines: 6,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      textCapitalization: TextCapitalization.sentences,
                      style: theme.textTheme.bodyLarge,
                      decoration: InputDecoration(
                        isCollapsed: true,
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(vertical: tokens.space.md),
                        constraints: BoxConstraints(minHeight: tokens.space.minTouchTarget),
                        hintText: widget.hintText,
                        hintMaxLines: 1,
                        hintStyle: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ),
                ),
                if (widget.dictation case final d?)
                  IconButton(
                    key: const ValueKey('composer-dictate'),
                    tooltip: d.listening ? 'Stop dictation' : 'Dictate',
                    isSelected: d.listening,
                    onPressed: () => unawaited(d.toggle()),
                    style: IconButton.styleFrom(minimumSize: Size.square(tokens.space.minTouchTarget)),
                    icon: const Icon(Icons.mic_none_rounded),
                    selectedIcon: Icon(Icons.mic_rounded, color: theme.colorScheme.primary),
                  ),
                SizedBox(width: tokens.space.xs),
                AnimatedSwitcher(
                  duration: motion.fast,
                  switchInCurve: motion.standard,
                  transitionBuilder: (child, a) => ScaleTransition(scale: a, child: child),
                  // Each button is its own semantics node with the tap action:
                  // `excludeSemantics` drops the IconButton's, and without
                  // `container` the label would merge into the screen-wide
                  // node above, which has no tap (TalkBack couldn't Stop).
                  child: widget.running
                      ? Semantics(
                          key: const ValueKey('stop'),
                          container: true,
                          button: true,
                          label: 'Stop response',
                          onTap: widget.onStop,
                          excludeSemantics: true,
                          child: IconButton.filled(
                            tooltip: 'Stop (Esc)',
                            onPressed: widget.onStop,
                            style: IconButton.styleFrom(
                              backgroundColor: theme.colorScheme.inverseSurface,
                              foregroundColor: theme.colorScheme.onInverseSurface,
                              minimumSize: Size.square(tokens.space.minTouchTarget),
                            ),
                            icon: const Icon(Icons.stop_rounded),
                          ),
                        )
                      : Semantics(
                          key: const ValueKey('send'),
                          container: true,
                          button: true,
                          enabled: sendable,
                          label: (widget.attachments?.busy ?? false) ? 'Send message, waiting for a photo' : 'Send message',
                          onTap: sendable ? _submit : null,
                          excludeSemantics: true,
                          child: IconButton.filled(
                            tooltip: 'Send',
                            onPressed: sendable ? _submit : null,
                            style: IconButton.styleFrom(minimumSize: Size.square(tokens.space.minTouchTarget)),
                            icon: const Icon(Icons.arrow_upward_rounded),
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// "Listening…" with what happens to the user's voice, or why dictation
/// stopped.
class _DictationLine extends StatelessWidget {
  const _DictationLine({required this.dictation});

  final ComposerDictation dictation;

  @override
  Widget build(BuildContext context) {
    final tokens = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final problem = dictation.problem;
    final color = problem != null ? tokens.semantic.warning : theme.colorScheme.primary;
    return Padding(
      padding: EdgeInsets.only(bottom: tokens.space.xs, left: tokens.space.md, right: tokens.space.xs),
      child: Semantics(
        liveRegion: true,
        container: true,
        child: Row(
          children: [
            Icon(problem != null ? Icons.mic_off_rounded : Icons.mic_rounded, size: ChatIconSize.small, color: color),
            SizedBox(width: tokens.space.sm),
            Expanded(
              child: Text.rich(
                TextSpan(children: [
                  if (problem == null) ...[
                    TextSpan(text: 'Listening… ', style: TextStyle(color: color, fontWeight: FontWeight.w600)),
                    TextSpan(text: dictation.privacyNote),
                  ] else
                    TextSpan(text: problem),
                ]),
                style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            if (problem != null)
              IconButton(
                tooltip: 'Dismiss',
                visualDensity: VisualDensity.compact,
                iconSize: ChatIconSize.small,
                onPressed: dictation.dismissProblem,
                icon: const Icon(Icons.close_rounded),
              ),
          ],
        ),
      ),
    );
  }
}

class _SlashMenu extends StatelessWidget {
  const _SlashMenu({required this.entries, required this.highlight, required this.label});

  final List<_MenuEntry> entries;
  final int highlight;
  final String label;

  @override
  Widget build(BuildContext context) {
    final tokens = SherpaTokens.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: tokens.space.sm),
      child: Material(
        color: theme.colorScheme.surfaceContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tokens.radius.lg),
          side: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: Semantics(
          container: true,
          role: SemanticsRole.menu,
          label: label,
          explicitChildNodes: true,
          child: ConstrainedBox(
            // Many servers can offer many prompts: the menu scrolls rather
            // than pushing the composer off screen.
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.4),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (i, c) in entries.indexed)
                    Semantics(
                      role: SemanticsRole.menuItem,
                      selected: i == highlight,
                      child: InkWell(
                        onTap: c.enabled ? c.onSelect : null,
                        child: Container(
                          constraints: BoxConstraints(minHeight: tokens.space.minTouchTarget),
                          color: i == highlight ? theme.colorScheme.surfaceContainerHighest : null,
                          padding: EdgeInsets.symmetric(horizontal: tokens.space.lg, vertical: tokens.space.sm),
                          child: Row(
                            children: [
                              Icon(c.icon, size: ChatIconSize.medium, color: theme.colorScheme.onSurfaceVariant),
                              SizedBox(width: tokens.space.md),
                              Flexible(
                                flex: c.source == null ? 0 : 1,
                                child: Text(
                                  c.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: chatMonoStyle(context).copyWith(fontWeight: FontWeight.w600),
                                ),
                              ),
                              SizedBox(width: tokens.space.md),
                              Expanded(
                                flex: c.source == null ? 1 : 2,
                                child: c.source == null
                                    ? Text(
                                        c.enabled ? c.description ?? '' : '${c.description ?? ''} (not available now)',
                                        style: theme.textTheme.bodyMedium?.copyWith(
                                          color: c.enabled ? theme.colorScheme.onSurface : theme.colorScheme.onSurfaceVariant,
                                        ),
                                      )
                                    : _ServerText(description: c.description, source: c.source!),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A server's own description, with the server named under it: the text
/// is the server's, not Sherpa's.
class _ServerText extends StatelessWidget {
  const _ServerText({required this.description, required this.source});

  final String? description;
  final String source;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (description != null && description!.trim().isNotEmpty)
          Text(
            description!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface),
          ),
        Text('from $source', style: theme.textTheme.labelSmall?.copyWith(color: muted)),
      ],
    );
  }
}

/// Under `/server:prompt …`: which arguments the prompt takes and which
/// are still missing.
class _PromptHint extends StatelessWidget {
  const _PromptHint({required this.command, required this.rest});

  final McpPromptCommand command;
  final String rest;

  @override
  Widget build(BuildContext context) {
    final tokens = SherpaTokens.of(context);
    final theme = Theme.of(context);
    final missing = command.missing(command.parseArguments(rest)).toSet();
    final parts = [
      for (final a in command.arguments)
        '${a.name}${a.required ? (missing.contains(a.name) ? ' (required)' : ' ✓') : ' (optional)'}',
    ];
    final color = missing.isEmpty ? theme.colorScheme.onSurfaceVariant : tokens.semantic.warning;
    return Padding(
      padding: EdgeInsets.only(bottom: tokens.space.xs, left: tokens.space.md, right: tokens.space.md),
      child: Semantics(
        liveRegion: true,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.extension_outlined, size: ChatIconSize.small, color: color),
            SizedBox(width: tokens.space.sm),
            Expanded(
              child: Text(
                '${command.label} from ${command.serverName} takes ${parts.join(', ')}. '
                '${command.arguments.length == 1 ? 'Type it after the command.' : 'Type them in order, or as name="value".'}',
                style: theme.textTheme.labelMedium?.copyWith(color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
