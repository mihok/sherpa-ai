import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_apple_ml/src/common/think_splitter.dart';
import 'package:sherpa_core/sherpa_core.dart';

(String, String) run(ThinkSplitter s, List<String> chunks, {bool toolCallAfter = false}) {
  final events = <ModelEvent>[];
  for (final c in chunks) {
    events.addAll(s.add(c));
  }
  if (toolCallAfter) events.addAll(s.closeOnToolCall());
  events.addAll(s.flush());
  return (
    events.whereType<ReasoningDelta>().map((e) => e.text).join(),
    events.whereType<TextDelta>().map((e) => e.text).join(),
  );
}

ThinkSplitter qwen({bool primed = false, List<String> implicit = const []}) =>
    ThinkSplitter(start: '<think>', end: '</think>', implicitEnds: implicit, primed: primed);

void main() {
  test('model-opened span (Qwen3), delimiters split across chunks', () {
    expect(run(qwen(), ['<th', 'ink>a', 'b</thi', 'nk>\n\nAnswer']), ('ab', 'Answer'));
  });

  test('no reasoning at all passes text through, even with "<" in it', () {
    expect(run(qwen(), ['1 < 2 and ', '<b>bold</b>']), ('', '1 < 2 and <b>bold</b>'));
  });

  test('primed template: the stream starts inside', () {
    expect(run(qwen(primed: true), ['let me see', '</think>', 'Yes']), ('let me see', 'Yes'));
  });

  test('an implicit end leaves reasoning and stays in the stream', () {
    expect(run(qwen(primed: true, implicit: ['<tool_call>']), ['plan<tool_', 'call>{}']), ('plan', '<tool_call>{}'));
  });

  test('a tool call closes an open span; flush emits held-back text', () {
    expect(run(qwen(primed: true), ['still thinking </thi'], toolCallAfter: true), ('still thinking </thi', ''));
    expect(run(qwen(), ['Answer <thi']), ('', 'Answer <thi'));
  });

  test('disabled splitter is a pass-through', () {
    final s = ThinkSplitter.disabled();
    expect(run(s, ['<think>x</think>y']), ('', '<think>x</think>y'));
    expect(s.sawReasoning, isFalse);
  });
}
