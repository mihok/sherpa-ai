import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/features/models/state/download_errors.dart';
import 'package:sherpa_hub/sherpa_hub.dart';

void main() {
  group('downloadStartMessage', () {
    const repo = 'meta-llama/Llama-3.2-1B-Instruct';

    test('a gated model says what to do in a way that works in onboarding too (no Settings yet)', () {
      final signedOut = downloadStartMessage(HubGatedRepoException('Access to model is restricted', repo: repo, statusCode: 401));
      expect(signedOut, allOf(contains('huggingface.co/$repo'), contains('Add token'), contains("the model's page")));
      expect(signedOut, isNot(contains('Settings')), reason: "onboarding can't open Settings");

      final noAccess = downloadStartMessage(HubGatedRepoException('Access to model is restricted', repo: repo, statusCode: 403));
      expect(noAccess, allOf(contains('no access'), contains('huggingface.co/$repo')));
      expect(noAccess, isNot(contains('Add token')), reason: 'already signed in: the terms are what is missing');
      expect(noAccess, isNot(contains('Settings')));
    });
  });
}
