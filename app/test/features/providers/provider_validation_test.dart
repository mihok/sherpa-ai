import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/features/providers/connection.dart';
import 'package:sherpa/features/providers/provider_validation.dart';

void main() {
  group('base URL (UrlPolicy)', () {
    BaseUrlCheck check(String url, {bool lan = false}) => checkBaseUrl(url, allowLocalNetwork: lan);

    test('public https passes and is normalized', () {
      final r = check('https://api.openai.com/v1/');
      expect(r, isA<BaseUrlOk>());
      expect((r as BaseUrlOk).uri.toString(), 'https://api.openai.com/v1');
    });

    test('a bare host gets https://', () {
      expect((check('openrouter.ai/api/v1') as BaseUrlOk).uri.scheme, 'https');
    });

    test('LAN http needs the opt-in, and the message says so', () {
      final r = check('http://192.168.1.20:11434/v1');
      expect(r, isA<BaseUrlError>());
      expect((r as BaseUrlError).needsLocalNetworkOptIn, isTrue);
      expect(r.message, contains('This is a server on my own network'));
      expect(check('http://192.168.1.20:11434/v1', lan: true), isA<BaseUrlOk>());
    });

    test('private https and .local names also need the opt-in', () {
      expect((check('https://10.0.0.2/v1') as BaseUrlError).needsLocalNetworkOptIn, isTrue);
      expect((check('https://studio.local:1234/v1') as BaseUrlError).needsLocalNetworkOptIn, isTrue);
      expect(check('https://studio.local:1234/v1', lan: true), isA<BaseUrlOk>());
    });

    test('loopback (a server on this phone) is allowed with the opt-in', () {
      expect(check('http://127.0.0.1:8080/v1'), isA<BaseUrlError>());
      expect(check('http://127.0.0.1:8080/v1', lan: true), isA<BaseUrlOk>());
    });

    test('link-local / cloud metadata is refused even with the opt-in', () {
      final r = check('http://169.254.169.254/latest', lan: true);
      expect(r, isA<BaseUrlError>());
      expect((r as BaseUrlError).needsLocalNetworkOptIn, isFalse);
    });

    test('http to a public IP is refused even with the opt-in', () {
      final r = check('http://8.8.8.8/v1', lan: true);
      expect((r as BaseUrlError).message, contains('https'));
    });

    test('plain http to a public host explains the rule', () {
      final r = check('http://api.example.com/v1') as BaseUrlError;
      expect(r.message, contains('http://'));
    });

    test('credentials, other schemes, queries and garbage are refused', () {
      expect((check('https://user:pw@api.example.com') as BaseUrlError).message, contains('password'));
      expect(check('ftp://example.com'), isA<BaseUrlError>());
      expect(check('https://api.example.com/v1?key=1'), isA<BaseUrlError>());
      expect(check(''), isA<BaseUrlError>());
      expect(check('not a url at all'), isA<BaseUrlError>());
    });
  });

  group('extra headers', () {
    const label = 'API key';

    test('credential-looking names are rejected with a pointer to the key field', () {
      for (final name in [
        'Authorization',
        'authorization',
        'Proxy-Authorization',
        'X-API-Key',
        'api_key',
        'x-goog-api-key',
        'Cookie',
        'X-Auth-Token',
        'X-Session-Id',
        'My-Secret',
        'X-Access-Token',
      ]) {
        final e = validateHeaderName(name, keyFieldLabel: label);
        expect(e, isNotNull, reason: name);
        expect(e, contains('API key field'), reason: name);
      }
    });

    test('ordinary headers pass', () {
      for (final name in ['OpenAI-Organization', 'OpenAI-Project', 'HTTP-Referer', 'X-Title', 'anthropic-beta']) {
        expect(validateHeaderName(name, keyFieldLabel: label), isNull, reason: name);
        expect(looksLikeCredentialHeader(name), isFalse, reason: name);
      }
    });

    test('secret-looking values are rejected under any name', () {
      for (final v in ['Bearer abc.def', 'sk-proj-1234567890abcdef', 'hf_abcdefghijklmnop', 'ghp_abcdefghijkl']) {
        expect(validateHeaderValue(v, keyFieldLabel: label), contains('API key field'), reason: v);
      }
      expect(validateHeaderValue('org-123', keyFieldLabel: label), isNull);
    });

    test('malformed names, reserved names, CR/LF and duplicates are rejected', () {
      expect(validateHeaderName('Bad Header', keyFieldLabel: label), isNotNull);
      expect(validateHeaderName('Content-Type', keyFieldLabel: label), contains('Sherpa sets'));
      expect(validateHeaderValue('a\r\nX-Evil: 1', keyFieldLabel: label), isNotNull);
      final errors = validateHeaders(
        [(name: 'X-Title', value: 'a'), (name: 'x-title', value: 'b')],
        keyFieldLabel: label,
      );
      expect(errors[0].name, isNull);
      expect(errors[1].name, contains('already'));
    });

    test('blank rows are ignored', () {
      expect(meaningfulRows([(name: '', value: ' '), (name: 'X-Title', value: 'a')]), hasLength(1));
    });
  });

  test('provider ids are readable and unique', () {
    expect(uniqueProviderId('openai', []), 'openai');
    expect(uniqueProviderId('openai', ['openai']), 'openai-2');
    expect(uniqueProviderId('openai', ['openai', 'openai-2']), 'openai-3');
    expect(uniqueProviderId('LM Studio!', []), 'lm-studio');
  });
}
