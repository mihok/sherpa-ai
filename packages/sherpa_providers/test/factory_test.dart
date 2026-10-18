import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sherpa_providers/sherpa_providers.dart';
import 'package:test/test.dart';

void main() {
  final client = MockClient((_) async => http.Response('{}', 404));

  ProviderConfig cfg(ApiFlavor f, String url) =>
      ProviderConfig(id: 'p-${f.name}', flavor: f, displayName: f.name, baseUrl: Uri.parse(url));

  test('maps every flavor to its provider', () {
    expect(createProvider(cfg(ApiFlavor.anthropic, 'https://api.anthropic.com'), apiKey: 'k', client: client),
        isA<AnthropicProvider>());
    expect(createProvider(cfg(ApiFlavor.openAiChat, 'https://openrouter.ai/api/v1'), apiKey: 'k', client: client),
        isA<OpenAiChatProvider>());
    expect(createProvider(cfg(ApiFlavor.openAiResponses, 'https://api.openai.com/v1'), apiKey: 'k', client: client),
        isA<OpenAiResponsesProvider>());
  });

  test('providers report the configured id and a remote location', () {
    final p = createProvider(cfg(ApiFlavor.anthropic, 'https://api.anthropic.com'), apiKey: null, client: client);
    expect(p.info.id, 'p-anthropic');
    expect(p.info.dataLeavesDevice, isTrue);
  });
}
