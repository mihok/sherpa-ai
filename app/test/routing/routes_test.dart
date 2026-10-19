import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/routing/routes.dart';

void main() {
  test('chatIdOf keeps the chat selected on its sub-routes', () {
    expect(Routes.chatIdOf(Routes.chat('s1')), 's1');
    expect(Routes.chatIdOf(Routes.chatContext('s1')), 's1', reason: 'context inspector');
    expect(Routes.chatIdOf(Routes.chatHandoff('s1')), 's1', reason: 'handoff review');
    expect(Routes.chatIdOf(Routes.chat('a b/c')), 'a b/c', reason: 'ids are decoded');
  });

  test('chatIdOf ignores everything else', () {
    expect(Routes.chatIdOf(Routes.home), isNull);
    expect(Routes.chatIdOf('/chat'), isNull);
    expect(Routes.chatIdOf('/chat/s1/unknown'), isNull);
    expect(Routes.chatIdOf('/chat/s1/context/extra'), isNull);
    expect(Routes.chatIdOf(Routes.settings), isNull);
    expect(Routes.chatIdOf(Routes.handoffImport), isNull);
  });
}
