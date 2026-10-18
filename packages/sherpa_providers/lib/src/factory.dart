import 'package:http/http.dart' as http;
import 'package:sherpa_core/sherpa_core.dart';

import 'anthropic/anthropic_provider.dart';
import 'config.dart';
import 'openai/chat_provider.dart';
import 'openai/responses_provider.dart';

/// Builds the [ModelProvider] for a configured endpoint. The only place that
/// maps an [ApiFlavor] to an implementation, so the app never imports a
/// concrete provider class.
ModelProvider createProvider(
  ProviderConfig config, {
  required String? apiKey,
  required http.Client client,
  Clock clock = const SystemClock(),
}) =>
    switch (config.flavor) {
      ApiFlavor.anthropic => AnthropicProvider(config: config, apiKey: apiKey, client: client, clock: clock),
      ApiFlavor.openAiChat => OpenAiChatProvider(config: config, apiKey: apiKey, client: client, clock: clock),
      ApiFlavor.openAiResponses =>
        OpenAiResponsesProvider(config: config, apiKey: apiKey, client: client, clock: clock),
    };
