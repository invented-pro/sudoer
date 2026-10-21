/// C2: the provider catalog.
///
/// Prop still talks to the model through exactly one of two adapters
/// ([ProviderKind]); a *preset* is the named, user-facing way to configure one:
/// a base URL, the environment variable that conventionally holds its key, and
/// a starter model list. The catalog is a convenience, not a second adapter
/// layer — every entry resolves to an OpenAI-compatible or ollama endpoint.
///
/// The hand-curated list below is deliberately small; the generated part
/// carries the full OpenAI-compatible provider set from models.dev (the source
/// OpenCode uses). Together they are the offline fallback for `--list-models`
/// and the setup wizard. When an endpoint is reachable, the CLI discovers its
/// live `GET /models` list and merges it over this catalog (`discovery.dart`).
library;

part 'catalog_generated.dart';

/// The two Prop provider adapters (C2).
enum ProviderKind { openAiCompatible, ollama }

extension ProviderKindWire on ProviderKind {
  String get wire => switch (this) {
    ProviderKind.openAiCompatible => 'openai-compatible',
    ProviderKind.ollama => 'ollama',
  };
}

/// One model a preset knows about: its id, a display name, and the context
/// window the agent fits its prompt against (C4).
final class ModelInfo {
  const ModelInfo(this.id, this.name, this.contextWindow);

  final String id;
  final String name;
  final int contextWindow;
}

/// A named provider preset (C2).
final class ProviderPreset {
  const ProviderPreset({
    required this.id,
    required this.name,
    required this.kind,
    required this.baseUrl,
    this.envKeys = const [],
    this.models = const [],
    this.local = false,
    this.requiresKey = true,
    this.docs,
    this.note,
  });

  /// Stable id used in config (`provider.preset`), the auth store, and
  /// `/provider <id>`.
  final String id;
  final String name;
  final ProviderKind kind;

  /// The OpenAI-compatible (or ollama) base URL; null for `custom`, which is
  /// filled by the user.
  final String? baseUrl;

  /// Well-known environment variables, most preferred first.
  final List<String> envKeys;

  /// The offline starter catalog. Live discovery merges over it.
  final List<ModelInfo> models;

  /// A local endpoint (ollama, LM Studio): no key required.
  final bool local;

  /// Whether a key is expected. `custom` may be an unauthenticated proxy, so
  /// it is false there.
  final bool requiresKey;

  final String? docs;

  /// A short caveat shown by the setup wizard / list commands.
  final String? note;

  /// The model selected when the preset is first chosen.
  String get defaultModel => models.isEmpty ? '' : models.first.id;

  ModelInfo? model(String id) {
    for (final model in models) {
      if (model.id == id) return model;
    }
    return null;
  }
}

/// The context window assumed for a model the catalog does not know and the
/// endpoint did not describe. Deliberately conservative: overflow is reported
/// by the provider and blocks the run, never silently truncated.
const int kDefaultContextWindow = 128000;

/// The hand-curated presets: the common providers plus the local/custom
/// entries, kept rich enough to work offline. The generated part adds every
/// OpenAI-compatible models.dev provider.
const List<ProviderPreset> kCuratedProviderPresets = [
  ProviderPreset(
    id: 'openai',
    name: 'OpenAI',
    kind: ProviderKind.openAiCompatible,
    baseUrl: 'https://api.openai.com/v1',
    envKeys: ['OPENAI_API_KEY'],
    docs: 'https://platform.openai.com/docs',
    models: [
      ModelInfo('gpt-6-astra-pro', 'GPT-6 Astra Pro', 1050000),
      ModelInfo('gpt-6-astra', 'GPT-6 Astra', 1050000),
      ModelInfo('gpt-5.6-terra-pro', 'GPT-5.6 Terra Pro', 1050000),
      ModelInfo('gpt-5.6-terra', 'GPT-5.6 Terra', 1050000),
      ModelInfo('gpt-5.6-sol', 'GPT-5.6 Sol', 1050000),
      ModelInfo('gpt-5-nano', 'GPT-5 Nano', 400000),
    ],
  ),
  ProviderPreset(
    id: 'anthropic',
    name: 'Anthropic Claude',
    kind: ProviderKind.openAiCompatible,
    baseUrl: 'https://api.anthropic.com/v1',
    envKeys: ['ANTHROPIC_API_KEY'],
    docs: 'https://docs.anthropic.com',
    note: 'Uses Anthropic\'s OpenAI compatibility layer (beta).',
    models: [
      ModelInfo('claude-sonnet-5', 'Claude Sonnet 5', 1000000),
      ModelInfo('claude-opus-5', 'Claude Opus 5', 1000000),
      ModelInfo('claude-fable-5-1', 'Claude Fable 5.1', 1000000),
      ModelInfo('claude-opus-5-fast', 'Claude Opus 5 Fast', 1000000),
      ModelInfo('claude-opus-4-8', 'Claude Opus 4.8', 1000000),
      ModelInfo('claude-sonnet-4-6', 'Claude Sonnet 4.6', 1000000),
    ],
  ),
  ProviderPreset(
    id: 'google',
    name: 'Google Gemini',
    kind: ProviderKind.openAiCompatible,
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
    envKeys: ['GEMINI_API_KEY', 'GOOGLE_GENERATIVE_AI_API_KEY'],
    docs: 'https://ai.google.dev',
    models: [
      ModelInfo('gemini-3.8-flash', 'Gemini 3.8 Flash', 1048576),
      ModelInfo('gemini-3.7-flash', 'Gemini 3.7 Flash', 1048576),
      ModelInfo('gemini-3.6-flash', 'Gemini 3.6 Flash', 1048576),
      ModelInfo('gemini-3.5-flash', 'Gemini 3.5 Flash', 1048576),
      ModelInfo('gemini-3.1-pro-preview', 'Gemini 3.1 Pro Preview', 1048576),
      ModelInfo('gemini-2.5-pro', 'Gemini 2.5 Pro', 1048576),
    ],
  ),
  ProviderPreset(
    id: 'openrouter',
    name: 'OpenRouter',
    kind: ProviderKind.openAiCompatible,
    baseUrl: 'https://openrouter.ai/api/v1',
    envKeys: ['OPENROUTER_API_KEY'],
    docs: 'https://openrouter.ai/docs',
    models: [
      ModelInfo('anthropic/claude-sonnet-5', 'Claude Sonnet 5', 1000000),
      ModelInfo('z-ai/glm-5.3', 'GLM-5.3', 1310720),
      ModelInfo('deepseek/deepseek-v4-pro', 'DeepSeek V4 Pro', 1048576),
      ModelInfo('qwen/qwen3.8-max', 'Qwen3.8 Max', 1000000),
      ModelInfo(
        'deepseek/deepseek-v4-flash-vision-exp',
        'DeepSeek V4 Flash Vision Exp',
        1048576,
      ),
      ModelInfo('z-ai/glm-5.3-flash', 'GLM-5.3-Flash', 1310720),
    ],
  ),
  ProviderPreset(
    id: 'groq',
    name: 'Groq',
    kind: ProviderKind.openAiCompatible,
    baseUrl: 'https://api.groq.com/openai/v1',
    envKeys: ['GROQ_API_KEY'],
    docs: 'https://console.groq.com/docs',
    models: [
      ModelInfo('qwen/qwen3.8-27b', 'Qwen3.8 27B', 131042),
      ModelInfo('openai/gpt-oss-120b', 'GPT OSS 120B', 131072),
      ModelInfo('openai/gpt-oss-20b', 'GPT OSS 20B', 131072),
      ModelInfo('llama-3.3-70b-versatile', 'Llama 3.3 70B', 131072),
      ModelInfo('llama-3.1-8b-instant', 'Llama 3.1 8B', 131072),
    ],
  ),
  ProviderPreset(
    id: 'deepseek',
    name: 'DeepSeek',
    kind: ProviderKind.openAiCompatible,
    baseUrl: 'https://api.deepseek.com',
    envKeys: ['DEEPSEEK_API_KEY'],
    docs: 'https://api-docs.deepseek.com',
    models: [
      ModelInfo('deepseek-v4-pro', 'DeepSeek V4 Pro', 1000000),
      ModelInfo('deepseek-v4-flash', 'DeepSeek V4 Flash', 1000000),
      ModelInfo(
        'deepseek-v4-flash-vision-exp',
        'DeepSeek V4 Flash Vision Exp',
        1000000,
      ),
    ],
  ),
  ProviderPreset(
    id: 'mistral',
    name: 'Mistral',
    kind: ProviderKind.openAiCompatible,
    baseUrl: 'https://api.mistral.ai/v1',
    envKeys: ['MISTRAL_API_KEY'],
    docs: 'https://docs.mistral.ai',
    models: [
      ModelInfo('mistral-medium-latest', 'Mistral Medium (latest)', 262144),
      ModelInfo('devstral-latest', 'Devstral 2', 262144),
      ModelInfo('mistral-small-latest', 'Mistral Small (latest)', 256000),
      ModelInfo('labs-devstral-small-2512', 'Devstral Small 2', 256000),
    ],
  ),
  ProviderPreset(
    id: 'xai',
    name: 'xAI Grok',
    kind: ProviderKind.openAiCompatible,
    baseUrl: 'https://api.x.ai/v1',
    envKeys: ['XAI_API_KEY'],
    docs: 'https://docs.x.ai',
    models: [
      ModelInfo('grok-4.6', 'Grok 4.6', 500000),
      ModelInfo('grok-4.5', 'Grok 4.5', 500000),
      ModelInfo('grok-4.3', 'Grok 4.3', 1000000),
      ModelInfo('grok-build-0.1', 'Grok Build 0.1', 256000),
    ],
  ),
  ProviderPreset(
    id: 'zhipuai',
    name: 'Zhipu AI (GLM)',
    kind: ProviderKind.openAiCompatible,
    baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
    envKeys: ['ZHIPUAI_API_KEY'],
    docs: 'https://docs.bigmodel.cn',
    models: [
      ModelInfo('glm-5.3', 'GLM-5.3', 1000000),
      ModelInfo('glm-5.3-flash', 'GLM-5.3-Flash', 1000000),
      ModelInfo('glm-5.2', 'GLM-5.2', 1000000),
      ModelInfo('glm-5.1', 'GLM-5.1', 200000),
      ModelInfo('glm-4.7-flash', 'GLM-4.7-Flash', 200000),
    ],
  ),
  ProviderPreset(
    id: 'moonshotai',
    name: 'Moonshot (Kimi)',
    kind: ProviderKind.openAiCompatible,
    baseUrl: 'https://api.moonshot.ai/v1',
    envKeys: ['MOONSHOT_API_KEY'],
    docs: 'https://platform.moonshot.ai/docs',
    models: [
      ModelInfo('kimi-k3', 'Kimi K3', 1048576),
      ModelInfo('kimi-k2.7-code', 'Kimi K2.7 Code', 262144),
      ModelInfo('kimi-k2.7-code-highspeed', 'Kimi K2.7 Code HighSpeed', 262144),
      ModelInfo('kimi-k2.6', 'Kimi K2.6', 262144),
    ],
  ),
  ProviderPreset(
    id: 'minimax',
    name: 'MiniMax',
    kind: ProviderKind.openAiCompatible,
    baseUrl: 'https://api.minimax.io/v1',
    envKeys: ['MINIMAX_API_KEY'],
    docs: 'https://platform.minimax.io/docs',
    note:
        'International region; keys are region-specific. Use minimax-cn '
        'for a key from platform.minimaxi.com.',
    models: [
      ModelInfo('MiniMax-M3', 'MiniMax-M3', 1048576),
      ModelInfo('MiniMax-M2.7', 'MiniMax-M2.7', 204800),
      ModelInfo('MiniMax-M2.7-highspeed', 'MiniMax-M2.7-highspeed', 204800),
      ModelInfo('MiniMax-M2.5', 'MiniMax-M2.5', 204800),
    ],
  ),
  ProviderPreset(
    id: 'minimax-cn',
    name: 'MiniMax (China)',
    kind: ProviderKind.openAiCompatible,
    baseUrl: 'https://api.minimax.cn/v1',
    envKeys: ['MINIMAX_CN_API_KEY', 'MINIMAX_API_KEY'],
    docs: 'https://platform.minimaxi.com/docs',
    note:
        'China region; keys are region-specific. Use minimax for a key from '
        'platform.minimax.io.',
    models: [
      ModelInfo('MiniMax-M3', 'MiniMax-M3', 1048576),
      ModelInfo('MiniMax-M2.7', 'MiniMax-M2.7', 204800),
      ModelInfo('MiniMax-M2.7-highspeed', 'MiniMax-M2.7-highspeed', 204800),
      ModelInfo('MiniMax-M2.5', 'MiniMax-M2.5', 204800),
    ],
  ),
  ProviderPreset(
    id: 'minimax-coding-plan',
    name: 'MiniMax Token Plan (International)',
    kind: ProviderKind.openAiCompatible,
    baseUrl: 'https://api.minimax.io/v1',
    envKeys: ['MINIMAX_API_KEY'],
    docs: 'https://platform.minimax.io/docs/token-plan/intro',
    note: 'Token-plan subscription; international region.',
    models: [
      ModelInfo('MiniMax-M3', 'MiniMax-M3', 1048576),
      ModelInfo('MiniMax-M2.7', 'MiniMax-M2.7', 204800),
      ModelInfo('MiniMax-M2.7-highspeed', 'MiniMax-M2.7-highspeed', 204800),
      ModelInfo('MiniMax-M2.5', 'MiniMax-M2.5', 204800),
    ],
  ),
  ProviderPreset(
    id: 'minimax-cn-coding-plan',
    name: 'MiniMax Token Plan (China)',
    kind: ProviderKind.openAiCompatible,
    baseUrl: 'https://api.minimax.cn/v1',
    envKeys: ['MINIMAX_CN_API_KEY', 'MINIMAX_API_KEY'],
    docs: 'https://platform.minimaxi.com/docs/token-plan/intro',
    note: 'Token-plan subscription; China region.',
    models: [
      ModelInfo('MiniMax-M3', 'MiniMax-M3', 1048576),
      ModelInfo('MiniMax-M2.7', 'MiniMax-M2.7', 204800),
      ModelInfo('MiniMax-M2.7-highspeed', 'MiniMax-M2.7-highspeed', 204800),
      ModelInfo('MiniMax-M2.5', 'MiniMax-M2.5', 204800),
    ],
  ),
  ProviderPreset(
    id: 'cohere',
    name: 'Cohere',
    kind: ProviderKind.openAiCompatible,
    baseUrl: 'https://api.cohere.ai/compatibility/v1',
    envKeys: ['COHERE_API_KEY'],
    docs: 'https://docs.cohere.com',
    models: [
      ModelInfo('command-a-plus-05-2026', 'Command A Plus', 128000),
      ModelInfo('command-a-reasoning-08-2025', 'Command A Reasoning', 256000),
      ModelInfo('command-a-03-2025', 'Command A', 256000),
      ModelInfo('north-mini-code-1-0', 'North Mini Code', 256000),
    ],
  ),
  ProviderPreset(
    id: 'fireworks-ai',
    name: 'Fireworks AI',
    kind: ProviderKind.openAiCompatible,
    baseUrl: 'https://api.fireworks.ai/inference/v1',
    envKeys: ['FIREWORKS_API_KEY'],
    docs: 'https://docs.fireworks.ai',
    models: [
      ModelInfo('accounts/fireworks/models/glm-5p3', 'GLM 5.3', 1048573),
      ModelInfo(
        'accounts/fireworks/models/glm-5p3-flash',
        'GLM 5.3 Flash',
        1048573,
      ),
      ModelInfo(
        'accounts/fireworks/models/deepseek-v4-pro-0813',
        'DeepSeek V4 Pro 0813',
        1000000,
      ),
      ModelInfo(
        'accounts/fireworks/models/qwen3p8-2p4t-a95b',
        'Qwen3.8 2.4T A95B',
        262144,
      ),
    ],
  ),
  ProviderPreset(
    id: 'deepinfra',
    name: 'DeepInfra',
    kind: ProviderKind.openAiCompatible,
    baseUrl: 'https://api.deepinfra.com/v1/openai',
    envKeys: ['DEEPINFRA_API_KEY'],
    docs: 'https://deepinfra.com/docs',
    models: [
      ModelInfo('zai-org/GLM-5.3', 'GLM-5.3', 1048576),
      ModelInfo(
        'deepseek-ai/DeepSeek-V4-Pro-0813',
        'DeepSeek V4 Pro 0813',
        1048576,
      ),
      ModelInfo('Qwen/Qwen3.8-Max', 'Qwen3.8 Max', 256000),
      ModelInfo('Qwen/Qwen3.8-2.4T-A95B', 'Qwen3.8 2.4T A95B', 262144),
    ],
  ),
  ProviderPreset(
    id: 'cerebras',
    name: 'Cerebras',
    kind: ProviderKind.openAiCompatible,
    baseUrl: 'https://api.cerebras.ai/v1',
    envKeys: ['CEREBRAS_API_KEY'],
    docs: 'https://inference-docs.cerebras.ai',
    models: [
      ModelInfo('gpt-oss-120b', 'GPT OSS 120B', 131072),
      ModelInfo('qwen-3.8-27b', 'Qwen3.8 27B', 65536),
    ],
  ),
  ProviderPreset(
    id: 'ollama-cloud',
    name: 'Ollama Cloud',
    kind: ProviderKind.openAiCompatible,
    baseUrl: 'https://ollama.com/v1',
    envKeys: ['OLLAMA_API_KEY'],
    docs: 'https://docs.ollama.com',
    models: [
      ModelInfo('glm-5.3', 'GLM-5.3', 1048576),
      ModelInfo('kimi-k3', 'Kimi K3', 1048576),
      ModelInfo('deepseek-v4-flash:0731', 'DeepSeek V4 Flash 0731', 1048576),
      ModelInfo('glm-5.2', 'GLM-5.2', 976000),
    ],
  ),
  ProviderPreset(
    id: 'ollama',
    name: 'Ollama (local)',
    kind: ProviderKind.ollama,
    baseUrl: 'http://localhost:11434',
    local: true,
    requiresKey: false,
    docs: 'https://ollama.com',
    note: 'Models are discovered from the running daemon.',
    models: [
      ModelInfo('qwen3-coder:30b', 'Qwen3 Coder 30B (local)', 262144),
      ModelInfo('qwen2.5-coder:7b', 'Qwen2.5 Coder 7B (local)', 32768),
      ModelInfo('llama3.1:8b', 'Llama 3.1 8B (local)', 131072),
      ModelInfo('deepseek-r1:8b', 'DeepSeek R1 8B (local)', 131072),
      ModelInfo('gemma3:12b', 'Gemma 3 12B (local)', 131072),
    ],
  ),
  ProviderPreset(
    id: 'lmstudio',
    name: 'LM Studio (local)',
    kind: ProviderKind.openAiCompatible,
    baseUrl: 'http://localhost:1234/v1',
    local: true,
    requiresKey: false,
    docs: 'https://lmstudio.ai/docs',
    note: 'Models are discovered from the running LM Studio server.',
    models: [
      ModelInfo('qwen/qwen3-coder-30b', 'Qwen3 Coder 30B (local)', 262144),
      ModelInfo('openai/gpt-oss-20b', 'GPT OSS 20B (local)', 131072),
    ],
  ),
  ProviderPreset(
    id: 'custom',
    name: 'Custom (OpenAI-compatible)',
    kind: ProviderKind.openAiCompatible,
    baseUrl: null,
    requiresKey: false,
    note: 'Enter any OpenAI-compatible base URL (typically ending in /v1).',
    docs: null,
  ),
];

/// Every preset: the curated core first, then the generated models.dev set.
/// IDs are unique; the generator excludes curated ids.
const List<ProviderPreset> kProviderPresets = [
  ...kCuratedProviderPresets,
  ...kGeneratedProviderPresets,
];

/// Look up a preset by id, or null when it is unknown. A few historical
/// aliases keep older configs working while the canonical id follows
/// models.dev/OpenCode.
const Map<String, String> _presetAliases = {'fireworks': 'fireworks-ai'};

ProviderPreset? providerPreset(String? id) {
  if (id == null) return null;
  final canonical = _presetAliases[id] ?? id;
  for (final preset in kProviderPresets) {
    if (preset.id == canonical) return preset;
  }
  return null;
}

/// A one-line, key-free hint when a MiniMax 401 is likely a region mismatch.
///
/// MiniMax issues region-scoped keys: `platform.minimax.io` keys work with
/// `api.minimax.io`, while `platform.minimaxi.com` keys need the China
/// endpoint (`api.minimax.cn`, or the legacy `api.minimaxi.com`/`.chat`
/// hosts). The hint never includes a credential.
String minimaxRegionHint({String? presetId, String? baseUrl}) {
  final url = (baseUrl ?? '').toLowerCase();
  final urlChina =
      url.contains('api.minimax.cn') ||
      url.contains('api.minimaxi.com') ||
      url.contains('api.minimax.chat');
  final urlInternational = url.contains('api.minimax.io');
  // An explicit base URL wins: it says which endpoint actually answered.
  final china = urlChina || (!urlInternational && presetId == 'minimax-cn');
  final international =
      urlInternational || (!urlChina && presetId == 'minimax');
  if (china) {
    return 'MiniMax keys are region-specific: a key from platform.minimax.io '
        'needs the minimax preset (https://api.minimax.io/v1).';
  }
  if (international) {
    return 'MiniMax keys are region-specific: a key from platform.minimaxi.com '
        'needs the minimax-cn preset (https://api.minimax.cn/v1).';
  }
  return '';
}

/// The preset whose base URL matches [baseUrl] (used to label a config that
/// predates presets). Null when no preset matches.
ProviderPreset? presetForBaseUrl(String? baseUrl) {
  if (baseUrl == null) return null;
  final normalized = baseUrl.replaceAll(RegExp(r'/+$'), '');
  for (final preset in kProviderPresets) {
    if (preset.baseUrl == null) continue;
    if (preset.baseUrl!.replaceAll(RegExp(r'/+$'), '') == normalized) {
      return preset;
    }
  }
  return null;
}
