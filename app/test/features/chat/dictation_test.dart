import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sherpa/features/chat/dictation/dictation.dart';

import 'support/harness.dart';
import 'support/pump.dart';

final class _FakeDictation implements ChatDictation {
  bool available = true;
  int listens = 0;
  int stops = 0;
  void Function(String words, bool isFinal)? words;
  void Function(String? problem)? done;

  @override
  String get privacyNote => 'Your voice stays on this phone.';

  @override
  Future<bool> prepare() async => available;

  @override
  Future<void> listen({
    required void Function(String words, bool isFinal) onWords,
    required void Function(String? problem) onDone,
  }) async {
    listens++;
    words = onWords;
    done = onDone;
  }

  @override
  Future<void> stop() async {
    stops++;
    done?.call(null);
  }
}

String _field(WidgetTester tester) => tester.widget<TextField>(find.byType(TextField)).controller!.text;

void main() {
  late ChatHarness h;
  late _FakeDictation dictation;

  setUp(() {
    dictation = _FakeDictation();
    h = ChatHarness(overrides: [chatDictationProvider.overrideWithValue(dictation)]);
  });
  tearDown(() => h.dispose());

  testWidgets('dictated words are typed after the text, partial results replaced; nothing is sent', (tester) async {
    await h.createSession();
    await pumpChatScreen(tester, h);
    await tester.enterText(find.byType(TextField), 'Note:');
    await tester.tap(find.byTooltip('Dictate'));
    await tester.pumpAndSettle();
    expect(dictation.listens, 1);
    expect(find.textContaining('Listening…'), findsOneWidget);
    expect(find.textContaining('Your voice stays on this phone.'), findsOneWidget, reason: 'the privacy note');
    expect(find.byTooltip('Stop dictation'), findsOneWidget);

    dictation.words!('buy milk', false);
    await tester.pump();
    expect(_field(tester), 'Note: buy milk');
    dictation.words!('buy milk and eggs', true);
    await tester.pump();
    expect(_field(tester), 'Note: buy milk and eggs', reason: 'the partial result was replaced, not appended');

    await tester.tap(find.byTooltip('Stop dictation'));
    await tester.pumpAndSettle();
    expect(dictation.stops, 1);
    expect(find.textContaining('Listening…'), findsNothing);
    expect(find.byTooltip('Dictate'), findsOneWidget);
    expect(h.scripted.requests, isEmpty, reason: 'dictating never sends');
    expect(_field(tester), 'Note: buy milk and eggs');
  });

  testWidgets('problems are explained and can be dismissed', (tester) async {
    await h.createSession();
    await pumpChatScreen(tester, h);
    dictation.available = false;
    await tester.tap(find.byTooltip('Dictate'));
    await tester.pumpAndSettle();
    expect(find.textContaining("Dictation isn't available"), findsOneWidget);
    expect(dictation.listens, 0);
    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.textContaining("Dictation isn't available"), findsNothing);

    dictation.available = true;
    await tester.tap(find.byTooltip('Dictate'));
    await tester.pumpAndSettle();
    dictation.done!(dictationProblem('error_permission'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Allow it for Sherpa in Settings'), findsOneWidget);
  });

  testWidgets('no recognizer: no microphone', (tester) async {
    final none = ChatHarness(overrides: [chatDictationProvider.overrideWithValue(null)]);
    addTearDown(none.dispose);
    await none.createSession();
    await pumpChatScreen(tester, none);
    expect(find.byTooltip('Dictate'), findsNothing);
  });

  test('recognizer errors in plain words; silence says nothing', () {
    expect(dictationProblem('error_no_match'), isNull);
    expect(dictationProblem('error_speech_timeout'), isNull);
    expect(dictationProblem('error_network'), contains('only asks for offline dictation'));
    expect(dictationProblem('error_language_not_supported'), contains('On-device dictation'));
    expect(dictationProblem('error_weird'), 'Dictation stopped (error_weird).');
  });

  test('the platform recognizer is asked to stay on the device', () {
    expect(SpeechToTextDictation().privacyNote, anyOf(contains('offline'), contains('not sent anywhere')));
  });
}
