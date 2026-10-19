import 'dart:convert';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_providers/src/anthropic/anthropic.dart';
import 'package:test/test.dart';

import 'helpers.dart';

Future<List<String>> golden(String name, {AnthropicToolNames names = AnthropicToolNames.empty}) async =>
    (await decode(fixture(name), names: names)).map(describe).toList();

void main() {
  group('golden fixtures', () {
    test('text: deltas, citations ignored, usage incl. cache reads/writes, end_turn', () async {
      expect(await golden('text'), [
        'usage:in=1225,out=1,cr=3400,cw=1200,r=0',
        'text:Hello',
        'text: from Tōkyō, 18°C 日本',
        'usage:in=1225,out=12,cr=3400,cw=1200,r=0',
        'finish:stop:end_turn',
      ]);
    });

    test('thinking + signature: signature once at block stop, thinking tokens, max_tokens → length', () async {
      expect(await golden('thinking_signature'), [
        'usage:in=120,out=3,cr=0,cw=0,r=0',
        'reasoning:The user wants a haiku.',
        'reasoning: Five, seven, five.',
        'signature:EuYBCkQYAiJAsig1',
        'text:Autumn moonlight—',
        'usage:in=120,out=64,cr=0,cw=0,r=40',
        'finish:length:max_tokens',
      ]);
    });

    test('F4 parallel tool_use: ordinals 0..n, accumulated args, toolCalls', () async {
      expect(await golden('parallel_tool_use'), [
        'usage:in=690,out=2,cr=0,cw=0,r=0',
        'reasoning:Two independent lookups: Paris weather and Tokyo time.',
        'reasoning: Both can run in parallel.',
        'signature:EqQBCgIYAhIM1gbcDa9GJwZA2b3hGgxBdjrkzLoky3dl1pkiMOYds',
        'text:Checking both now.',
        'start:0:toolu_01AbCdEf:get_weather',
        'args:0:{"city": "Par',
        'args:0:is"}',
        'complete:0:toolu_01AbCdEf:get_weather:{"city":"Paris"}',
        'start:1:toolu_01GhIjKl:get_time',
        'args:1:{"timezone": "Asia/Tokyo"}',
        'complete:1:toolu_01GhIjKl:get_time:{"timezone":"Asia/Tokyo"}',
        'usage:in=690,out=118,cr=0,cw=0,r=0',
        'finish:toolCalls:tool_use',
      ]);
    });

    test('interleaved thinking/text/tool_use (progress updates) keeps block order', () async {
      final names = AnthropicToolNames(['fs/read', 'fs/list']);
      expect(names.toWire('fs/read'), 'fs_read');
      expect(await golden('interleaved', names: names), [
        'usage:in=800,out=2,cr=0,cw=0,r=0',
        'reasoning:Plan: read the file, then list the folder.',
        'signature:SIG_A',
        'text:Let me look.',
        'reasoning:Reading README first.',
        'signature:SIG_B',
        // Wire names map back to the Sherpa names.
        'start:0:toolu_01Read:fs/read',
        'args:0:{"path": "README.md"}',
        'complete:0:toolu_01Read:fs/read:{"path":"README.md"}',
        'reasoning:Then the folder listing.',
        'signature:SIG_C',
        'start:1:toolu_01List:fs/list',
        'args:1:{"dir": ',
        'args:1:"."}',
        'complete:1:toolu_01List:fs/list:{"dir":"."}',
        'usage:in=800,out=210,cr=0,cw=0,r=0',
        'finish:toolCalls:tool_use',
      ]);
    });

    test('pause_turn: server tool blocks are skipped with notices', () async {
      expect(await golden('pause_turn'), [
        'usage:in=300,out=1,cr=0,cw=0,r=0',
        'text:Searching the web.',
        'notice:anthropic.server_tool_ignored',
        'notice:anthropic.server_tool_ignored',
        'usage:in=300,out=40,cr=0,cw=0,r=0',
        'finish:pause:pause_turn',
      ]);
    });

    test('refusal: held-back tool calls are discarded, never surfaced', () async {
      final events = await golden('refusal');
      expect(events, [
        'usage:in=400,out=1,cr=0,cw=0,r=0',
        'text:Running the scan now.',
        'notice:anthropic.refusal',
        'usage:in=400,out=30,cr=0,cw=0,r=0',
        'finish:refusal:refusal',
      ]);
      final raw = await decode(fixture('refusal'));
      final notice = raw.whereType<ProviderNotice>().single;
      expect(notice.data['category'], 'cyber');
      expect(notice.message, contains('safety classifier'));
    });

    test('error event mid-stream: partial reasoning delivered, then overloaded', () async {
      final events = await decode(fixture('error_midstream'));
      expect(events.map(describe), [
        'usage:in=690,out=2,cr=0,cw=0,r=0',
        'reasoning:Two independent lookups',
        'error:overloaded',
      ]);
      final e = events.last as ProviderException;
      expect(e.isRetryable, isTrue);
      expect(e.message, contains('Overloaded'));
    });

    test('redacted_thinking: whole block as redactedData, separator before next thinking', () async {
      expect(await golden('redacted_thinking'), [
        'usage:in=50,out=1,cr=0,cw=0,r=0',
        'redacted:EmwKAhgBEgy3va3pzix/LafPsn4aDFIT2Xlxh0L5L8rLVyIwxtE3rAFBa8cr3qpP',
        // Empty text delta: keeps the next thinking block out of the
        // redacted segment in AgentRunner's accumulator.
        'text:',
        'reasoning:Visible part of the reasoning.',
        'signature:SIG_AFTER_REDACTED',
        'text:Done.',
        'usage:in=50,out=20,cr=0,cw=0,r=0',
        'finish:stop:end_turn',
      ]);
    });

    test('display omitted: empty thinking gives a bare signature; empty tool input parses to {}', () async {
      expect(await golden('omitted_display'), [
        'usage:in=690,out=2,cr=0,cw=0,r=0',
        'signature:EqQBCgIYAhIMomitted',
        'start:0:toolu_01NoArgs:get_time',
        'complete:0:toolu_01NoArgs:get_time:{}',
        'usage:in=690,out=20,cr=0,cw=0,r=0',
        'finish:toolCalls:tool_use',
      ]);
    });

    test('every fixture decodes identically when split at every byte offset', () async {
      for (final name in [
        'text',
        'thinking_signature',
        'parallel_tool_use',
        'interleaved',
        'pause_turn',
        'refusal',
        'error_midstream',
        'redacted_thinking',
        'omitted_display',
      ]) {
        final sse = fixture(name);
        final whole = (await decode(sse)).map(describe).toList();
        final length = utf8.encode(sse).length;
        for (var cut = 1; cut < length; cut++) {
          final split = (await decode(sse, splitAt: [cut])).map(describe).toList();
          expect(split, whole, reason: '$name split at byte $cut');
        }
      }
    });
  });

  group('robustness', () {
    test('stream that ends before message_stop and without stop_reason is a network error', () async {
      final sse = fixture('parallel_tool_use');
      final cut = sse.indexOf('event: message_delta');
      final events = await decode(sse.substring(0, cut));
      final err = events.last as ProviderException;
      expect(err.kind, ProviderErrorKind.network);
      expect(err.isRetryable, isTrue);
      // Tool calls were still held back, so nothing half-built is surfaced.
      expect(events.whereType<ToolCallStart>(), isEmpty);
      expect(events.whereType<TextDelta>().single.text, 'Checking both now.');
    });

    test('stop_reason received but socket closed before message_stop still finishes', () async {
      final sse = fixture('text');
      final events = await decode(sse.substring(0, sse.indexOf('event: message_stop')));
      expect(describe(events.last), 'finish:stop:end_turn');
    });

    test('malformed JSON tool input becomes an argumentsError, not a crash', () async {
      const sse = 'event: content_block_start\n'
          'data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"w","input":{}}}\n\n'
          'event: content_block_delta\n'
          'data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"a\\": "}}\n\n'
          'event: content_block_stop\n'
          'data: {"type":"content_block_stop","index":0}\n\n'
          'event: message_delta\n'
          'data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":5}}\n\n'
          'event: message_stop\n'
          'data: {"type":"message_stop"}\n\n';
      final events = await decode(sse);
      final call = events.whereType<ToolCallComplete>().single.call;
      expect(call.isValid, isFalse);
      expect(call.argumentsError, contains('malformed JSON'));
      expect(call.rawArguments, '{"a": ');
      expect(describe(events.last), 'finish:length:max_tokens');
    });

    test('max_tokens: tool input that never arrived, or a block never closed, is truncated (finding 12)', () async {
      const empty = 'data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t1","name":"w","input":{}}}\n\n'
          'data: {"type":"content_block_stop","index":0}\n\n'
          'data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":5}}\n\n'
          'data: {"type":"message_stop"}\n\n';
      final emptyCall = (await decode(empty)).whereType<ToolCallComplete>().single.call;
      expect(emptyCall.isValid, isFalse);
      expect(emptyCall.argumentsError, contains('output-token limit'));

      const unclosed = 'data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t2","name":"w","input":{}}}\n\n'
          'data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"path\\": \\"a"}}\n\n'
          'data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":5}}\n\n'
          'data: {"type":"message_stop"}\n\n';
      final events = await decode(unclosed);
      final call = events.whereType<ToolCallComplete>().single.call;
      expect(call.isValid, isFalse);
      expect(call.rawArguments, '{"path": "a');
      expect(call.argumentsError, contains('output-token limit'));
      expect(events.map(describe), contains('notice:tool_args_truncated'));
      expect(describe(events.last), 'finish:length:max_tokens');

      // A complete call before the cut stands.
      const whole = 'data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t3","name":"w","input":{}}}\n\n'
          'data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"a\\": 1}"}}\n\n'
          'data: {"type":"content_block_stop","index":0}\n\n'
          'data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":5}}\n\n'
          'data: {"type":"message_stop"}\n\n';
      final ok = (await decode(whole)).whereType<ToolCallComplete>().single.call;
      expect(ok.isValid, isTrue);
      expect(ok.arguments, {'a': 1});
    });

    test('non-object tool input is rejected', () async {
      const sse = 'data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t","name":"w","input":{}}}\n\n'
          'data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"[1]"}}\n\n'
          'data: {"type":"content_block_stop","index":0}\n\n'
          'data: {"type":"message_stop"}\n\n';
      final call = (await decode(sse)).whereType<ToolCallComplete>().single.call;
      expect(call.argumentsError, contains('JSON object'));
    });

    test('malformed event data is a server error', () async {
      final events = await decode('event: content_block_delta\ndata: {not json\n\n');
      expect((events.single as ProviderException).kind, ProviderErrorKind.server);
    });

    test('unknown events and block types are tolerated (versioning policy)', () async {
      const sse = 'data: {"type":"message_start","message":{"usage":{"input_tokens":1,"output_tokens":0}}}\n\n'
          'data: {"type":"future_event","x":1}\n\n'
          'data: {"type":"content_block_start","index":0,"content_block":{"type":"hologram","data":"x"}}\n\n'
          'data: {"type":"content_block_delta","index":0,"delta":{"type":"hologram_delta","x":1}}\n\n'
          'data: {"type":"content_block_stop","index":0}\n\n'
          'data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}\n\n'
          'data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"ok"}}\n\n'
          'data: {"type":"content_block_stop","index":1}\n\n'
          'data: {"type":"message_delta","delta":{"stop_reason":"brand_new_reason"},"usage":{"output_tokens":2}}\n\n'
          'data: {"type":"message_stop"}\n\n';
      expect((await decode(sse)).map(describe), [
        'usage:in=1,out=0,cr=0,cw=0,r=0',
        'notice:anthropic.unknown_block',
        'text:ok',
        'usage:in=1,out=2,cr=0,cw=0,r=0',
        'finish:stop:brand_new_reason',
      ]);
    });

    test('stop reason table', () {
      expect(AnthropicStreamDecoder.mapStopReason('end_turn'), FinishReason.stop);
      expect(AnthropicStreamDecoder.mapStopReason('stop_sequence'), FinishReason.stop);
      expect(AnthropicStreamDecoder.mapStopReason('max_tokens'), FinishReason.length);
      expect(AnthropicStreamDecoder.mapStopReason('tool_use'), FinishReason.toolCalls);
      expect(AnthropicStreamDecoder.mapStopReason('pause_turn'), FinishReason.pause);
      expect(AnthropicStreamDecoder.mapStopReason('refusal'), FinishReason.refusal);
      expect(AnthropicStreamDecoder.mapStopReason('model_context_window_exceeded'), FinishReason.contextOverflow);
    });

    test('server-side fallback model is reported', () async {
      final events = await decode(fixture('text'), requestedModel: 'claude-fable-5-1');
      final n = events.whereType<ProviderNotice>().single;
      expect(n.code, 'anthropic.model_fallback');
      expect(n.data['served'], 'claude-opus-5-5');
    });

    test('mid-stream invalid_request_error about signatures gets an actionable message', () async {
      const sse = 'event: error\ndata: {"type":"error","error":{"type":"invalid_request_error",'
          '"message":"messages.1.content.0: Invalid `signature` in `thinking` block. The block is bound to a different conversation."}}\n\n';
      final e = (await decode(sse)).single as ProviderException;
      expect(e.kind, ProviderErrorKind.invalidRequest);
      expect(e.message, contains('conversation before it changed'));
      expect(e.message, contains('Invalid `signature`'));
    });
  });
}
