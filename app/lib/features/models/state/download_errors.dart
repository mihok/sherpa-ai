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
String downloadStartMessage(Object error) {
  final e = unwrapProviderError(error);
  return switch (e) {
    HubRateLimitedException() => 'Hugging Face is limiting requests from this network. Wait a minute and try again; '
        'signing in to Hugging Face raises the limit.',
    HubNetworkException() || SocketException() || http.ClientException() || TimeoutException() =>
      "Couldn't reach Hugging Face. Check your connection, then try again.",
    HubGatedRepoException() => 'This model is gated. Add your Hugging Face token in Settings › Hugging Face account '
        'and accept its terms on huggingface.co, then try again.',
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
