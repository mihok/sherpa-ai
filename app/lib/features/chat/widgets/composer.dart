import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../../design/tokens.dart';
import 'chat_style.dart';

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
/// * Typing `/` lists the built-in commands; ↑/↓ and Enter pick one.
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

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer> {
  int _highlight = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onText);
    widget.focusNode.addListener(_onFocus);
  }

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
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onText);
    widget.focusNode.removeListener(_onFocus);
    super.dispose();
  }

  void _onText() => setState(() => _highlight = 0);

  void _onFocus() => setState(() {});

  bool get _hasText => widget.controller.text.trim().isNotEmpty;

  /// Commands matching a leading `/word` (no spaces yet).
  List<SlashCommand> get _matches {
    final t = widget.controller.text;
    if (!t.startsWith('/') || t.contains(RegExp(r'\s'))) return const [];
    final q = t.substring(1).toLowerCase();
    return widget.commands.where((c) => c.name.startsWith(q)).toList();
  }

  void _submit() {
    if (widget.running || !widget.canSend || !_hasText) return;
    final exact = _matches.where((c) => '/${c.name}' == widget.controller.text.trim()).firstOrNull;
    if (exact != null) return _run(exact);
    widget.onSend(widget.controller.text);
  }

  void _run(SlashCommand c) {
    if (!c.enabled) return;
    widget.controller.clear();
    widget.onCommand(c);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    final key = event.logicalKey;
    final matches = _matches;
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      if (keys.isShiftPressed) return KeyEventResult.ignored; // newline
      if (widget.controller.value.composing.isValid) return KeyEventResult.ignored; // IME commit
      if (matches.isNotEmpty) {
        _run(matches[_highlight.clamp(0, matches.length - 1)]);
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
    final matches = _matches;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (matches.isNotEmpty)
          _SlashMenu(commands: matches, highlight: _highlight.clamp(0, matches.length - 1), onSelect: _run),
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
            padding: EdgeInsets.fromLTRB(tokens.space.lg, tokens.space.xxs, tokens.space.xs, tokens.space.xxs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
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
                          enabled: widget.canSend && _hasText,
                          label: 'Send message',
                          onTap: widget.canSend && _hasText ? _submit : null,
                          excludeSemantics: true,
                          child: IconButton.filled(
                            tooltip: 'Send',
                            onPressed: widget.canSend && _hasText ? _submit : null,
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

class _SlashMenu extends StatelessWidget {
  const _SlashMenu({required this.commands, required this.highlight, required this.onSelect});

  final List<SlashCommand> commands;
  final int highlight;
  final void Function(SlashCommand c) onSelect;

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
          label: 'Commands',
          explicitChildNodes: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (i, c) in commands.indexed)
                Semantics(
                  role: SemanticsRole.menuItem,
                  selected: i == highlight,
                  child: InkWell(
                    onTap: c.enabled ? () => onSelect(c) : null,
                    child: Container(
                      constraints: BoxConstraints(minHeight: tokens.space.minTouchTarget),
                      color: i == highlight ? theme.colorScheme.surfaceContainerHighest : null,
                      padding: EdgeInsets.symmetric(horizontal: tokens.space.lg, vertical: tokens.space.sm),
                      child: Row(
                        children: [
                          Icon(c.icon, size: ChatIconSize.medium, color: theme.colorScheme.onSurfaceVariant),
                          SizedBox(width: tokens.space.md),
                          Text('/${c.name}', style: chatMonoStyle(context).copyWith(fontWeight: FontWeight.w600)),
                          SizedBox(width: tokens.space.md),
                          Expanded(
                            child: Text(
                              c.enabled ? c.description : '${c.description} (not available now)',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: c.enabled ? theme.colorScheme.onSurface : theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
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
    );
  }
}
