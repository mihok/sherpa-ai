import 'dart:io' show InternetAddress, SocketException;

import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/state/provider_location.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_providers/sherpa_providers.dart';

void main() {
  ProviderConfig at(String url, {bool lan = false}) => ProviderConfig(
        id: 'p',
        flavor: ApiFlavor.openAiChat,
        displayName: 'P',
        baseUrl: Uri.parse(url),
        allowLocalNetwork: lan,
      );

  test('classifies where prompts go', () {
    final verdicts = LocalHostVerdicts();
    ExecutionLocation of(String url, {bool lan = false}) => locationOf(at(url, lan: lan), verdicts: verdicts);
    expect(of('https://api.openai.com/v1'), ExecutionLocation.remote);
    expect(of('http://192.168.1.20:11434/v1', lan: true), ExecutionLocation.localNetwork);
    expect(of('http://10.0.0.5:8080/v1', lan: true), ExecutionLocation.localNetwork);
    expect(of('http://studio.local:1234/v1', lan: true), ExecutionLocation.localNetwork);
    expect(of('http://127.0.0.1:8080/v1', lan: true), ExecutionLocation.onDevice);
    expect(of('http://localhost:8080/v1', lan: true), ExecutionLocation.onDevice);
    expect(of('http://[::1]:8080/v1', lan: true), ExecutionLocation.onDevice);
    // A public IP is remote even if the user claimed it was theirs.
    expect(of('http://8.8.8.8/v1', lan: true), ExecutionLocation.remote);
  });

  test('the "my own network" opt-in alone never makes a host name local', () {
    final verdicts = LocalHostVerdicts();
    final groq = at('http://api.groq.com/openai/v1', lan: true);
    expect(locationOf(groq, verdicts: verdicts), ExecutionLocation.remote);
    expect(isUnverifiedLocal(groq, verdicts: verdicts), isTrue);
    expect(privacyHostLabel(groq, verdicts: verdicts), 'api.groq.com (unverified)');
    // Without the opt-in there is nothing to verify.
    final plain = at('https://api.groq.com/openai/v1');
    expect(isUnverifiedLocal(plain, verdicts: verdicts), isFalse);
    expect(privacyHostLabel(plain, verdicts: verdicts), 'api.groq.com');
    // Literals and local-only names need no DNS.
    expect(isUnverifiedLocal(at('http://192.168.1.20/v1', lan: true), verdicts: verdicts), isFalse);
    expect(isUnverifiedLocal(at('http://studio.local/v1', lan: true), verdicts: verdicts), isFalse);
  });

  test('DNS settles it: private → local network, loopback → on device, public → remote', () async {
    final verdicts = LocalHostVerdicts();
    final dns = {
      'mybox.example.com': [InternetAddress('192.168.1.30')],
      'phone.example.com': [InternetAddress('127.0.0.1')],
      'ollama.myvps.example.com': [InternetAddress('93.184.216.34')],
      'mixed.example.com': [InternetAddress('192.168.1.30'), InternetAddress('93.184.216.34')],
    };
    Future<List<InternetAddress>> resolve(String host) async => dns[host]!;
    var notified = 0;
    verdicts.addListener(() => notified++);

    Future<ExecutionLocation> verify(String url) =>
        verifyLocalHost(at(url, lan: true), resolver: resolve, verdicts: verdicts);
    expect(await verify('http://mybox.example.com:11434/v1'), ExecutionLocation.localNetwork);
    expect(await verify('http://phone.example.com:8080/v1'), ExecutionLocation.onDevice);
    expect(await verify('http://ollama.myvps.example.com:11434/v1'), ExecutionLocation.remote);
    expect(await verify('http://mixed.example.com/v1'), ExecutionLocation.remote, reason: 'any public address');
    expect(notified, 4, reason: 'badges rebuild on every new verdict');

    final box = at('http://mybox.example.com:11434/v1', lan: true);
    expect(locationOf(box, verdicts: verdicts), ExecutionLocation.localNetwork, reason: 'cached, synchronous');
    expect(privacyHostLabel(box, verdicts: verdicts), 'mybox.example.com:11434');
  });

  test('a name that does not resolve stays unverified, and verdicts expire', () async {
    var now = DateTime.utc(2026, 10, 19, 9);
    final verdicts = LocalHostVerdicts(ttl: const Duration(minutes: 30), now: () => now);
    final box = at('http://mybox.example.com/v1', lan: true);
    final offline = await verifyLocalHost(
      box,
      resolver: (_) async => throw const SocketException('Failed host lookup'),
      verdicts: verdicts,
    );
    expect(offline, ExecutionLocation.remote);
    expect(isUnverifiedLocal(box, verdicts: verdicts), isTrue);

    verdicts.record('mybox.example.com', [InternetAddress('10.0.0.7')]);
    expect(locationOf(box, verdicts: verdicts), ExecutionLocation.localNetwork);
    now = now.add(const Duration(minutes: 31));
    expect(isUnverifiedLocal(box, verdicts: verdicts), isTrue, reason: 'DNS answers change');
    expect(locationOf(box, verdicts: verdicts), ExecutionLocation.remote);
  });

  test('badges verify an opt-in host name in the background, once at a time', () async {
    final verdicts = LocalHostVerdicts();
    final nas = at('http://nas.example.org:8080/v1', lan: true);
    var lookups = 0;
    Future<List<InternetAddress>> resolver(String host) async {
      lookups++;
      return [InternetAddress('192.168.1.40')];
    }

    ensureLocalHostVerified(nas, resolver, verdicts: verdicts);
    ensureLocalHostVerified(nas, resolver, verdicts: verdicts);
    await pumpEventQueue();
    expect(lookups, 1);
    expect(locationOf(nas, verdicts: verdicts), ExecutionLocation.localNetwork);
    expect(privacyHostLabel(nas, verdicts: verdicts), 'nas.example.org:8080');
    // Verified: nothing more to look up.
    ensureLocalHostVerified(nas, resolver, verdicts: verdicts);
    await pumpEventQueue();
    expect(lookups, 1);
  });

  test('host labels keep non-default ports', () {
    expect(hostLabel(Uri.parse('https://api.openai.com/v1')), 'api.openai.com');
    expect(hostLabel(Uri.parse('https://api.openai.com:443/v1')), 'api.openai.com');
    expect(hostLabel(Uri.parse('http://192.168.1.20:11434/v1')), '192.168.1.20:11434');
  });
}
