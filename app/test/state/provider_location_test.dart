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
    expect(locationOf(at('https://api.openai.com/v1')), ExecutionLocation.remote);
    expect(locationOf(at('http://192.168.1.20:11434/v1', lan: true)), ExecutionLocation.localNetwork);
    expect(locationOf(at('http://10.0.0.5:8080/v1', lan: true)), ExecutionLocation.localNetwork);
    expect(locationOf(at('http://studio.local:1234/v1', lan: true)), ExecutionLocation.localNetwork);
    expect(locationOf(at('http://127.0.0.1:8080/v1', lan: true)), ExecutionLocation.onDevice);
    expect(locationOf(at('http://localhost:8080/v1', lan: true)), ExecutionLocation.onDevice);
    expect(locationOf(at('http://[::1]:8080/v1', lan: true)), ExecutionLocation.onDevice);
    expect(locationOf(at('https://mybox.example.com/v1', lan: true)), ExecutionLocation.localNetwork);
    // A public IP is remote even if the user claimed it was theirs.
    expect(locationOf(at('http://8.8.8.8/v1', lan: true)), ExecutionLocation.remote);
  });

  test('host labels keep non-default ports', () {
    expect(hostLabel(Uri.parse('https://api.openai.com/v1')), 'api.openai.com');
    expect(hostLabel(Uri.parse('https://api.openai.com:443/v1')), 'api.openai.com');
    expect(hostLabel(Uri.parse('http://192.168.1.20:11434/v1')), '192.168.1.20:11434');
  });
}
