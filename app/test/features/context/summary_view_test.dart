import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/features/context/widgets/summary_view.dart';
import 'package:sherpa_core/sherpa_core.dart';

import '../chat/support/harness.dart' show chatTestTheme;

void main() {
  test('a handle line leads with its label when it has one', () {
    expect(
      SummaryView.handleLine(
        const StateHandle(key: 'note_id', value: 'n-42', tool: 'notes.create', label: 'Grocery list'),
      ),
      '“Grocery list” · note_id = n-42 (notes.create)',
    );
    expect(SummaryView.handleLine(const StateHandle(key: 'note_id', value: 'n-7')), 'note_id = n-7');
    expect(SummaryView.handleLine(const StateHandle(key: 'k', value: 'v', label: '  ')), 'k = v');
  });

  testWidgets('state handles show their labels inside the untrusted frame', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: chatTestTheme(Brightness.light),
        home: const Scaffold(
          body: SingleChildScrollView(
            child: SummaryView(
              summary: CompactionSummary(
                goal: 'Plan the week',
                stateHandles: [
                  StateHandle(key: 'note_id', value: 'n-42', tool: 'notes.create', label: 'Grocery list'),
                  StateHandle(key: 'note_id', value: 'n-43', tool: 'notes.create', label: 'Packing list'),
                  StateHandle(key: 'event_id', value: 'e-1'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('Files, links and handles'), findsOneWidget);
    expect(find.text('• “Grocery list” · note_id = n-42 (notes.create)'), findsOneWidget);
    expect(
      find.text('• “Packing list” · note_id = n-43 (notes.create)'),
      findsOneWidget,
      reason: 'two ids of one kind told apart',
    );
    expect(find.text('• event_id = e-1'), findsOneWidget);
    expect(find.text('Collected from tool output: untrusted'), findsOneWidget);
  });
}
