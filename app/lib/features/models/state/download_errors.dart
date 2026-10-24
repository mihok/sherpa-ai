import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/misc.dart' as rp show ProviderException;
import 'package:http/http.dart' as http show ClientException;
import 'package:sherpa_hub/sherpa_hub.dart';

import '../../../services/downloads/downloads.dart';
import '../../diagnostics/app_error_ring.dart';

/// The error behind a provider failure (a provider that read a failed
/// provider rethrows it wrapped).
Object unwrapProviderError(Object error) {
  var e = error;
  while (e is rp.ProviderException) {
    e = e.exception;
  }
  return e;
}

/// What the user reads when a download could not be started: what went
/// wrong and what to do about it. Never a bare "couldn't start".
///
/// Shown in onboarding too, where Settings can't be opened yet: a gated
/// model points to its own page's Add token button, which works in both.
String downloadStartMessage(Object error) {
  final e = unwrapProviderError(error);
  return switch (e) {
    HubRateLimitedException() => 'Hugging Face is limiting requests from this network. Wait a minute and try again; '
        'signing in to Hugging Face raises the limit.',
    HubNetworkException() || SocketException() || http.ClientException() || TimeoutException() =>
      "Couldn't reach Hugging Face. Check your connection, then try again.",
    HubGatedRepoException(:final repo, :final needsSignIn) => needsSignIn
        ? 'This model is gated. Accept its terms at huggingface.co/$repo, add your Hugging Face token with '
            "Add token on the model's page, then try again."
        : 'Your Hugging Face account has no access to this model yet. Accept its terms at huggingface.co/$repo '
            '(some authors approve requests by hand), then try again.',
    HubException(:final code) => 'Hugging Face refused the download ($code). Try again, or choose another model.',
    FileSystemException() => DownloadManager.initFailureMessage(e),
    _ => "Sherpa's download service didn't start (${e.runtimeType}). Try again; if it keeps happening, restart "
        'Sherpa and export diagnostics from Settings › About.',
  };
}

/// What the user reads for a refusal that came without reasons.
const String refusedWithoutReason =
    'Sherpa refused this download without saying why. Try again, or choose another model.';

/// Records [error] in the diagnostics ring: its type, and its own code when
/// it has one (`hub_network`, `os_28`, …), else [step] (which step failed:
/// `download_manager`, `enqueue`, …).
void recordDownloadError(AppErrorRing ring, Object error, {required String source, required String step}) {
  final e = unwrapProviderError(error);
  ring.record(e, source: source, code: AppErrorRing.codeOf(e) ?? step);
}
