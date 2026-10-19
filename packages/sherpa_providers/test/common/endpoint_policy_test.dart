import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_net/sherpa_net.dart';
import 'package:sherpa_providers/sherpa_providers.dart';
import 'package:test/test.dart';

import '../support/helpers.dart';

/// Finding 23: the "my own network" opt-in allows plain http only to hosts
/// on the user's network, checked again at connect time.
void main() {
  Future<List<InternetAddress>> dns(String host) async => switch (host) {
        'api.groq.com' => [InternetAddress('104.18.32.47')],
        'studio.local' => [InternetAddress('192.168.1.30')],
        _ => throw const SocketException('no such host'),
      };

  test('the opt-in policy refuses http to a public host by name, allows mDNS and private literals', () async {
    final p = endpointUrlPolicy(allowLocalNetwork: true, resolver: dns);
    await expectLater(p.check('http://api.groq.com/openai/v1'), throwsA(isA<UrlPolicyViolation>()));
    expect((await p.check('http://studio.local:1234/v1')).host, 'studio.local');
    expect((await p.check('http://192.168.1.20:11434/v1')).port, 11434);
    expect((await p.check('https://api.groq.com/openai/v1')).scheme, 'https');
  });

  for (final flavor in ApiFlavor.values) {
    test('${flavor.name}: http to a public address is refused before any request is sent', () async {
      final requests = <http.BaseRequest>[];
      final client = MockClient((r) async {
        requests.add(r);
        return http.Response('{}', 200, headers: {'content-type': 'application/json'});
      });
      final config = ProviderConfig(
        id: 'p',
        flavor: flavor,
        displayName: 'P',
        baseUrl: Uri.parse('http://8.8.8.8/v1'),
        allowLocalNetwork: true,
      );
      final provider = createProvider(config, apiKey: 'secret-key', client: client);
      await expectLater(
        provider.stream(weatherRequest(model: 'm')).drain<void>(),
        throwsA(isA<ProviderException>().having((e) => e.kind, 'kind', ProviderErrorKind.invalidRequest)),
      );
      expect(requests, isEmpty, reason: 'the key and prompt never left the device');
    });
  }
}
