import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_providers/sherpa_providers.dart';
import 'package:test/test.dart';

void main() {
  (String, String) run(List<String> chunks) {
    final s = ThinkTagSplitter();
    final events = [for (final c in chunks) ...s.add(c), ...s.flush()];
    return (
      events.whereType<ReasoningDelta>().map((e) => e.text).join(),
      events.whereType<TextDelta>().map((e) => e.text).join(),
    );
  }

  test('leading think block is routed to reasoning', () {
    expect(run(['<think>plan it</think>\n\nThe answer.']), ('plan it', 'The answer.'));
  });

  test('tags split across chunks at every position', () {
    const full = '<think>step one</think>\n\nDone.';
    for (var i = 1; i < full.length; i++) {
      expect(run([full.substring(0, i), full.substring(i)]), ('step one', 'Done.'), reason: 'split at $i');
    }
  });

  test('character-by-character streaming', () {
    const full = '  <think>a < b, </thin not yet</think>Answer';
    expect(run(full.split('')), ('a < b, </thin not yet', 'Answer'));
  });

  test('content without a leading think tag passes through untouched', () {
    expect(run(['Hello ', 'world']), ('', 'Hello world'));
    expect(run(['Use <think> tags like this']), ('', 'Use <think> tags like this'));
    expect(run(['<thi', 'nk-ish>']), ('', '<think-ish>'));
  });

  test('an unterminated think block is flushed as reasoning', () {
    expect(run(['<think>still going', ' on']), ('still going on', ''));
  });
}
