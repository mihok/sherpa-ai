import 'package:material_ui/material_ui.dart';
import 'package:sherpa_providers/sherpa_providers.dart';

enum KeyRequirement { required, optional }

enum PresetGroup {
  cloud('Cloud services'),
  network('A server on your network'),
  custom('Something else');

  const PresetGroup(this.label);
  final String label;
}

/// A starting point for connecting a model: flavor, server profile and base
/// URL filled in, so most people only paste a key.
@immutable
final class ProviderPreset {
  const ProviderPreset({
    required this.id,
    required this.name,
    required this.blurb,
    required this.flavor,
    required this.group,
    required this.icon,
    this.profile = ServerProfile.auto,
    this.baseUrl,
    this.urlHint,
    this.key = KeyRequirement.required,
    this.keyHint,
    this.keyLabel = 'API key',
  });

  final String id;
  final String name;

  /// One line on what this is and when to pick it.
  final String blurb;
  final ApiFlavor flavor;
  final ServerProfile profile;
  final PresetGroup group;
  final IconData icon;

  /// Prefilled base URL; null when the user must supply one.
  final String? baseUrl;

  /// Example shown in an empty URL field.
  final String? urlHint;
  final KeyRequirement key;

  /// Where to get a key. Plain text only: we never open links for the user
  /// from a credential screen.
  final String? keyHint;
  final String keyLabel;

  /// LAN presets need http and private addresses.
  bool get isLocalServer => group == PresetGroup.network;
}

abstract final class ProviderPresets {
  static const openAi = ProviderPreset(
    id: 'openai',
    name: 'OpenAI',
    blurb: 'GPT models from api.openai.com.',
    flavor: ApiFlavor.openAiResponses,
    profile: ServerProfile.openAi,
    group: PresetGroup.cloud,
    icon: Icons.cloud_outlined,
    baseUrl: 'https://api.openai.com/v1',
    keyHint: 'Create a key at platform.openai.com → API keys.',
  );

  static const anthropic = ProviderPreset(
    id: 'anthropic',
    name: 'Anthropic',
    blurb: 'Claude models from api.anthropic.com.',
    flavor: ApiFlavor.anthropic,
    group: PresetGroup.cloud,
    icon: Icons.cloud_outlined,
    baseUrl: 'https://api.anthropic.com',
    keyHint: 'Create a key at console.anthropic.com → API keys.',
  );

  static const openRouter = ProviderPreset(
    id: 'openrouter',
    name: 'OpenRouter',
    blurb: 'Hundreds of models behind one key.',
    flavor: ApiFlavor.openAiChat,
    profile: ServerProfile.openRouter,
    group: PresetGroup.cloud,
    icon: Icons.hub_outlined,
    baseUrl: 'https://openrouter.ai/api/v1',
    keyHint: 'Create a key at openrouter.ai → Keys.',
  );

  static const huggingFace = ProviderPreset(
    id: 'huggingface',
    name: 'Hugging Face',
    blurb: 'Open models via Inference Providers.',
    flavor: ApiFlavor.openAiChat,
    profile: ServerProfile.huggingFaceRouter,
    group: PresetGroup.cloud,
    icon: Icons.hub_outlined,
    baseUrl: 'https://router.huggingface.co/v1',
    keyLabel: 'Access token',
    keyHint: 'Create a fine-grained token at huggingface.co → Settings → Access Tokens '
        'with "Make calls to Inference Providers".',
  );

  static const ollama = ProviderPreset(
    id: 'ollama',
    name: 'Ollama',
    blurb: 'Models running on a computer on this network.',
    flavor: ApiFlavor.openAiChat,
    profile: ServerProfile.ollama,
    group: PresetGroup.network,
    icon: Icons.dns_outlined,
    urlHint: 'http://192.168.1.20:11434/v1',
    key: KeyRequirement.optional,
    keyHint: 'Ollama needs no key. Start it with OLLAMA_HOST=0.0.0.0 so other devices can reach it.',
  );

  static const lmStudio = ProviderPreset(
    id: 'lmstudio',
    name: 'LM Studio',
    blurb: 'The LM Studio server on a computer on this network.',
    flavor: ApiFlavor.openAiChat,
    profile: ServerProfile.lmStudio,
    group: PresetGroup.network,
    icon: Icons.dns_outlined,
    urlHint: 'http://192.168.1.20:1234/v1',
    key: KeyRequirement.optional,
    keyLabel: 'API token',
    keyHint: 'Only needed if you turned on authentication in LM Studio. '
        'Enable "Serve on Local Network" in its server settings.',
  );

  static const llamaCpp = ProviderPreset(
    id: 'llamacpp',
    name: 'llama.cpp server',
    blurb: 'llama-server on this network (or on this phone).',
    flavor: ApiFlavor.openAiChat,
    profile: ServerProfile.llamaCpp,
    group: PresetGroup.network,
    icon: Icons.dns_outlined,
    urlHint: 'http://192.168.1.20:8080/v1',
    key: KeyRequirement.optional,
    keyHint: 'Only needed if you started llama-server with --api-key.',
  );

  static const custom = ProviderPreset(
    id: 'custom',
    name: 'Custom OpenAI-compatible',
    blurb: 'Any server that speaks the Chat Completions API.',
    flavor: ApiFlavor.openAiChat,
    group: PresetGroup.custom,
    icon: Icons.tune_rounded,
    urlHint: 'https://llm.example.com/v1',
    key: KeyRequirement.optional,
  );

  static const all = [openAi, anthropic, openRouter, huggingFace, ollama, lmStudio, llamaCpp, custom];

  static ProviderPreset? byId(String? id) {
    for (final p in all) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Best-effort match for an existing config (edit screen).
  static ProviderPreset forConfig(ProviderConfig c) {
    for (final p in all) {
      if (p.baseUrl != null && Uri.parse(p.baseUrl!).host == c.baseUrl.host) return p;
    }
    for (final p in all) {
      if (p.profile != ServerProfile.auto && p.profile == c.profile) return p;
    }
    return custom;
  }
}

/// Human name for a wire protocol.
String flavorLabel(ApiFlavor f) => switch (f) {
      ApiFlavor.openAiChat => 'OpenAI-compatible (Chat Completions)',
      ApiFlavor.openAiResponses => 'OpenAI Responses',
      ApiFlavor.anthropic => 'Anthropic Messages',
    };
