import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sherpa_hub/sherpa_hub.dart';

import '../../services/device/device_profile_source.dart';
import '../diagnostics/app_error_ring.dart';
import '../models/state/download_errors.dart';
import '../models/state/model_fit.dart';
import '../models/state/models_providers.dart';

/// Small open instruct models with tool use, best first, for onboarding's
/// "Run a model on this phone". GGUF, so llama.cpp runs them on Android
/// and iOS alike; each repo's own recommended variant (the Hub directory's
/// "highest quality that fits with headroom") is what gets downloaded.
const List<String> kStarterModelRepos = [
  'unsloth/Qwen3-1.7B-GGUF',
  'bartowski/Llama-3.2-1B-Instruct-GGUF',
  'unsloth/Qwen3-0.6B-GGUF',
];

/// POLICY: a first download stays under this size (a few minutes on
/// Wi-Fi); larger recommended variants move on to the next, smaller model.
const int kStarterMaxDownloadBytes = 2 << 30;

/// The model onboarding offers: a repo, its recommended variant and the
/// header shape that sized it.
@immutable
final class StarterPick {
  const StarterPick({required this.details, required this.row, required this.shape});

  final CatalogModelDetails details;
  final VariantRow row;
  final ModelShape shape;

  String get name => details.name.displayName;
}

/// No starter model can be offered; [reason] is user-facing.
final class StarterUnavailable implements Exception {
  const StarterUnavailable(this.reason, {this.cause});

  final String reason;

  /// The last error behind it (a Hub or network failure), for diagnostics.
  final Object? cause;

  @override
  String toString() => 'StarterUnavailable: $reason';
}

/// Picks the first of [repos] whose recommended variant Fits this device
/// with headroom and stays under [maxDownloadBytes]: one Hub details call
/// and one GGUF header peek per repo tried, stopping at the first that
/// fits. Throws [StarterUnavailable] when none does.
Future<StarterPick> pickStarterModel({
  required ModelCatalog catalog,
  required ModelShapeSource shapes,
  required DeviceProfile device,
  List<String> repos = kStarterModelRepos,
  int maxDownloadBytes = kStarterMaxDownloadBytes,
}) async {
  Object? failure;
  var tooBig = false;
  for (final repo in repos) {
    try {
      final d = await catalog.details(repo);
      final target = peekTarget(d);
      if (target == null) continue;
      final shape = await shapes.peek(d.id, d.commit, target.path);
      final rec = assessVariants(d, device, shape: shape).recommended;
      if (rec == null || rec.kind != FitBadgeKind.fits) continue;
      if (rec.downloadBytes > maxDownloadBytes) {
        tooBig = true;
        continue;
      }
      return StarterPick(details: d, row: rec, shape: shape);
    } on Object catch (e) {
      failure = e;
    }
  }
  if (failure != null && !tooBig) {
    throw StarterUnavailable(switch (failure) {
      HubNetworkException() => "Couldn't reach Hugging Face to pick a model. Check your connection and try again.",
      HubRateLimitedException() => 'Hugging Face is limiting requests right now. Try again in a minute.',
      _ => "Couldn't pick a model for this phone right now. Try again, or choose a model from Hugging Face below.",
    }, cause: failure);
  }
  throw const StarterUnavailable(
    "None of the starter models fits this phone's free memory with headroom. Close other apps and try again, "
    'or choose a smaller model from Hugging Face below.',
  );
}

/// [pickStarterModel] for this device (refresh by invalidating it).
final starterModelProvider = FutureProvider.autoDispose<StarterPick>((ref) async {
  final device = await ref.watch(deviceProfileSourceProvider).current();
  try {
    return await pickStarterModel(
      catalog: ref.watch(modelCatalogProvider),
      shapes: ref.watch(modelShapeSourceProvider),
      device: device,
    );
  } on StarterUnavailable catch (e) {
    // The provider observer records StarterUnavailable; keep what caused it.
    final cause = e.cause;
    if (cause != null) recordDownloadError(ref.read(appErrorRingProvider), cause, source: 'onboarding', step: 'starter_pick');
    rethrow;
  }
}, name: 'starterModelProvider');
