import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../design/tokens.dart';
import '../../state/sessions.dart';

/// Filters the sessions list as you type. The query lives in a provider, so
/// it survives the phone ↔ tablet layout switch; the text survives process
/// death through state restoration.
class SessionSearchField extends ConsumerStatefulWidget {
  const SessionSearchField({super.key});

  @override
  ConsumerState<SessionSearchField> createState() => _SessionSearchFieldState();
}

class _SessionSearchFieldState extends ConsumerState<SessionSearchField> with RestorationMixin {
  final RestorableTextEditingController _controller = RestorableTextEditingController();

  @override
  String get restorationId => 'session-search';

  @override
  void restoreState(RestorationBucket? oldBucket, bool initialRestore) {
    registerForRestoration(_controller, 'query');
    final current = ref.read(sessionQueryProvider);
    if (_controller.value.text.isEmpty && current.isNotEmpty) {
      _controller.value.text = current;
    } else if (_controller.value.text.isNotEmpty) {
      // Restored after process death: re-apply the filter.
      Future.microtask(() => ref.read(sessionQueryProvider.notifier).set(_controller.value.text));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = SherpaTokens.of(context);
    // Clearing from elsewhere (e.g. "Clear search" in the no-results state).
    ref.listen(sessionQueryProvider, (_, next) {
      if (next != _controller.value.text) _controller.value.text = next;
    });
    return Padding(
      padding: EdgeInsets.fromLTRB(t.space.lg, t.space.xs, t.space.lg, t.space.sm),
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: _controller.value,
        // A plain TextField rather than SearchBar: SearchBar's inner field is
        // only 24dp tall, which fails the 48dp tap-target guideline for
        // screen-reader and switch users even though the bar looks bigger.
        builder: (context, value, _) {
          final scheme = Theme.of(context).colorScheme;
          final pill = OutlineInputBorder(
            borderRadius: BorderRadius.circular(t.radius.pill),
            borderSide: BorderSide.none,
          );
          return TextField(
            controller: _controller.value,
            textInputAction: TextInputAction.search,
            onChanged: (q) => ref.read(sessionQueryProvider.notifier).set(q),
            decoration: InputDecoration(
              hintText: 'Search chats',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: value.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        _controller.value.clear();
                        ref.read(sessionQueryProvider.notifier).set('');
                      },
                    ),
              filled: true,
              fillColor: scheme.surfaceContainerHigh,
              border: pill,
              enabledBorder: pill,
              focusedBorder: pill.copyWith(borderSide: BorderSide(color: scheme.primary, width: 2)),
              contentPadding: EdgeInsets.symmetric(horizontal: t.space.lg, vertical: t.space.md),
            ),
          );
        },
      ),
    );
  }
}
