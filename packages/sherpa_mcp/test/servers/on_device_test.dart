import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_mcp/sherpa_mcp.dart';
import 'package:test/test.dart';

import '../router/harness.dart' show textOf;

void main() {
  late OnDeviceServers onDevice;
  late McpServerManager manager;
  late McpToolRouter router;
  late InMemoryNoteStorage kv;
  final clock = FakeClock(DateTime.utc(2026, 10, 19, 12, 30));

  setUp(() {
    kv = InMemoryNoteStorage();
    onDevice = OnDeviceServers()
      ..register(memoryMcpServer(MemoryNotes(store: kv, clock: clock, ids: SequentialIdGenerator())),
          id: 'memory', name: 'Memory')
      ..register(
        deviceMcpServer(
          clock: clock,
          provider: const StaticDeviceFactsProvider(DeviceFacts(
            appName: 'Sherpa',
            appVersion: '0.4.0',
            platform: 'android',
            osVersion: '17',
            deviceModel: 'Pixel 9',
            locale: 'de-CH',
            timeZone: 'Europe/Zurich',
            timeZoneOffset: Duration(hours: 2),
          )),
        ),
        id: 'device',
        name: 'Device',
      );
    manager = McpServerManager(
      servers: onDevice.configs,
      transportFactory: onDevice.transportFor,
      options: const McpClientOptions(timeouts: McpTimeouts(inProcessProbe: Duration(milliseconds: 500))),
    );
    router = McpToolRouter(manager: manager, clock: clock);
  });

  tearDown(() async {
    await router.dispose();
    await manager.dispose();
    await onDevice.close();
  });

  ToolExecutionContext ctx() => ToolExecutionContext(sessionId: 's', cancel: CancellationToken());

  Future<ToolResult> call(String name, [JsonMap args = const {}]) =>
      router.execute(ToolCall(id: 'c', name: name, arguments: args), ctx());

  test('built-ins appear like any server: namespaced, on-device source, trusted annotations, auto-pinned', () async {
    final tools = await router.toolsForTurn(sessionId: 's');
    expect([for (final t in tools) t.name], [
      'memory__save_note',
      'memory__search_notes',
      'memory__delete_note',
      'device__current_time',
      'device__device_info',
    ]);
    for (final t in tools) {
      expect(t.source.kind, ToolSourceKind.onDevice);
      expect(router.hygieneFor(t.name)!.flagged, isFalse, reason: '${t.name} must not trip the scanner');
    }
    final search = router.lookup('memory__search_notes')!;
    expect(search.annotations.isReadOnly, isTrue);
    expect(search.annotations.isOpenWorld, isFalse);
    expect(router.lookup('memory__save_note')!.annotations.isDestructive, isFalse);
    expect(router.lookup('memory__delete_note')!.annotations.isDestructive, isTrue);
    expect(router.lookup('device__current_time')!.annotations.isIdempotent, isTrue);
    expect(router.entryFor('memory__save_note')!.review.pin!.origin, PinOrigin.builtin);
    final policy = ApprovalPolicy(trustedServers: manager.trustedServerIds);
    expect(policy.evaluate(search, 's'), isA<AutoApprove>());
    expect(policy.evaluate(router.lookup('memory__delete_note')!, 's'), isA<NeedsConfirmation>());
  });

  test('memory: save, update, search (BM25 + tags), delete', () async {
    final saved = await call('memory__save_note', {
      'text': 'The user prefers window seats on trains.',
      'title': 'Travel',
      'tags': ['Travel', 'prefs'],
    });
    expect(textOf(saved), 'Saved note note_1.');
    expect(saved.structured, {'id': 'note_1', 'created': true});
    await call('memory__save_note', {'text': 'Dentist appointment is on Friday.', 'tags': 'health'});
    final found = await call('memory__search_notes', {'query': 'train seat'});
    expect(textOf(found), allOf(contains('1 note:'), contains('(note_1) Travel: The user prefers window seats'), contains('[travel, prefs]')));
    expect(textOf(await call('memory__search_notes', {'tag': 'health'})), contains('Dentist'));
    expect(textOf(await call('memory__search_notes', {'query': 'quantum'})), 'No matching notes.');
    final updated = await call('memory__save_note', {'id': 'note_1', 'text': 'The user prefers aisle seats.'});
    expect(textOf(updated), 'Updated note note_1.');
    expect(textOf(await call('memory__save_note', {'id': 'nope', 'text': 'x'})), contains('there is no note'));
    expect(textOf(await call('memory__search_notes')), contains('aisle'));
    final deleted = await call('memory__delete_note', {'id': 'note_2'});
    expect(textOf(deleted), 'Deleted note note_2.');
    expect((await call('memory__delete_note', {'id': 'note_2'})).isError, isTrue);
    expect(kv.data.keys, ['memory/note/note_1']);
    expect(textOf(await call('memory__save_note', {'text': '   '})), contains('empty'));
  });

  test('device: current time in the user time zone, and app/device facts', () async {
    final t = await call('device__current_time');
    expect(textOf(t), 'It is Monday, 2026-10-19T14:30:00+02:00 (time zone Europe/Zurich, UTC+02:00). UTC: 2026-10-19T12:30:00Z.');
    expect(t.structured!['utcOffsetMinutes'], 120);
    final info = await call('device__device_info');
    expect(textOf(info), allOf(contains('app: Sherpa 0.4.0'), contains('deviceModel: Pixel 9'), contains('locale: de-CH')));
  });

  test('an unregistered on-device config is an error server, not a crash', () async {
    expect(onDevice.transportFor(McpServerConfig(id: 'x', name: 'x', url: Uri.parse('https://x.example'))), isNull);
    expect(() => onDevice.register(memoryMcpServer(MemoryNotes(store: kv)), id: 'memory', name: 'again'), throwsArgumentError);
  });
}
