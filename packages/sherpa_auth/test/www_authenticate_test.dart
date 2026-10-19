import 'dart:math';

import 'package:sherpa_auth/sherpa_auth.dart';
import 'package:test/test.dart';

void main() {
  group('WwwAuthenticate.parse (RFC 9110 §11.6.1)', () {
    test('1: single Bearer challenge with quoted resource_metadata and scope', () {
      final c = BearerChallenge.parse(
          'Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/mcp", scope="files:read"')!;
      expect(c.scheme, 'Bearer');
      expect(c.resourceMetadata, Uri.parse('https://mcp.example.com/.well-known/oauth-protected-resource/mcp'));
      expect(c.scopes, ['files:read']);
      expect(c.error, isNull);
    });

    test('2: unquoted token values and mixed-case scheme/param names', () {
      final h = WwwAuthenticate.parse('bEaReR Error=invalid_token, SCOPE=files:read, Realm=example');
      final c = h.find('Bearer')!;
      expect(c.param('error'), 'invalid_token');
      expect(c.param('Scope'), 'files:read');
      expect(c.params.keys, containsAll(['error', 'scope', 'realm']));
      expect(BearerChallenge.select(h)!.isInvalidToken, isTrue);
    });

    test('3: several challenges in one header and folded header lines', () {
      final one = WwwAuthenticate.parse(
          'DPoP algs="ES256 PS256", Bearer resource_metadata="https://a.example/prm", scope="x y", Basic realm="r"');
      expect(one.challenges.map((c) => c.scheme), ['DPoP', 'Bearer', 'Basic']);
      expect(one.find('dpop')!.param('algs'), 'ES256 PS256');
      expect(one.find('Bearer')!.param('scope'), 'x y');
      expect(one.find('basic')!.param('realm'), 'r');

      // package:http folds repeated header lines with ',' (no space).
      final folded = WwwAuthenticate.parse('Basic realm="legacy",Bearer error="invalid_token", scope="a"');
      expect(folded.challenges.map((c) => c.scheme), ['Basic', 'Bearer']);
      final all = WwwAuthenticate.parseAll(['Negotiate', 'Bearer scope="a b"']);
      expect(all.find('Bearer')!.param('scope'), 'a b');
    });

    test('4: quoted-string with escaped quotes and commas', () {
      final c = WwwAuthenticate.parse(r'Bearer scope="a,b c", error_description="say \"hi\", then go", realm="x\\y"').find('Bearer')!;
      expect(c.param('scope'), 'a,b c');
      expect(c.param('error_description'), 'say "hi", then go');
      expect(c.param('realm'), r'x\y');
    });

    test('5: a scope= inside error_description does not shadow the real scope (SDK regex bug)', () {
      final c = BearerChallenge.parse('Bearer error_description="need scope=x", scope="files:write", error="insufficient_scope"')!;
      expect(c.scopes, ['files:write']);
      expect(c.isInsufficientScope, isTrue);
      final c2 = BearerChallenge.parse('Bearer error_description="resource_metadata=https://evil.example", '
          'resource_metadata="https://good.example/prm"')!;
      expect(c2.resourceMetadata!.host, 'good.example');
    });

    test('RFC 6750 example scope with = & , inside quotes', () {
      final c = BearerChallenge.parse('Bearer realm="example", scope="urn:example:channel=HBO&urn:example:rating=G,PG-13"')!;
      expect(c.scope, 'urn:example:channel=HBO&urn:example:rating=G,PG-13');
    });

    test('6: a duplicate scope param keeps the first and is reported', () {
      final c = BearerChallenge.parse('Bearer scope="first", scope="second"')!;
      expect(c.scope, 'first');
      expect(c.duplicateParams, {'scope'});
    });

    test('7: token68 challenges are kept apart and do not break later ones', () {
      final h = WwwAuthenticate.parse('Negotiate abc==, Basic dXNlcjpwYXNz/+==, Bearer realm="r", scope="s"');
      expect(h.challenges.map((c) => c.scheme), ['Negotiate', 'Basic', 'Bearer']);
      expect(h.find('Negotiate')!.token68, 'abc==');
      expect(h.find('Basic')!.token68, 'dXNlcjpwYXNz/+==');
      expect(h.find('Bearer')!.param('scope'), 's');
      expect(BearerChallenge.parse('Negotiate abc==, Basic xyz'), isNull);
    });

    test('8: a DPoP challenge carrying resource_metadata is honoured', () {
      final dpopOnly = BearerChallenge.parse('DPoP algs="ES256", resource_metadata="https://rs.example/prm", scope="a"')!;
      expect(dpopOnly.scheme, 'DPoP');
      expect(dpopOnly.resourceMetadata, Uri.parse('https://rs.example/prm'));
      expect(dpopOnly.scopes, ['a']);
      final split = BearerChallenge.parse('Bearer scope="b", DPoP resource_metadata="https://rs.example/prm"')!;
      expect(split.scheme, 'Bearer');
      expect(split.scopes, ['b']);
      expect(split.resourceMetadata, Uri.parse('https://rs.example/prm'));
    });

    test('9: an invalid or relative resource_metadata is treated as absent', () {
      for (final bad in [
        '/.well-known/oauth-protected-resource',
        'not a url',
        'javascript:alert(1)',
        'ftp://rs.example/prm',
        'https://user:pw@rs.example/prm',
        'https://rs.example/prm#frag',
        '',
      ]) {
        expect(BearerChallenge.parse('Bearer resource_metadata="$bad"')!.resourceMetadata, isNull, reason: bad);
      }
    });

    test('Bearer with no parameters, realm only, and empty header', () {
      expect(BearerChallenge.parse('Bearer')!.scheme, 'Bearer');
      expect(BearerChallenge.parse('Bearer realm="GitHub"')!.realm, 'GitHub');
      expect(WwwAuthenticate.parse('').challenges, isEmpty);
      expect(WwwAuthenticate.parse(' , ,, ').challenges, isEmpty);
      expect(WwwAuthenticate.fromHeaders(const {}), isNull);
    });

    test('unquoted values containing ":" and "/" (common in the wild) are read whole', () {
      final c = BearerChallenge.parse('Bearer resource_metadata=https://rs.example/.well-known/oauth-protected-resource, scope=files:read')!;
      expect(c.resourceMetadata, Uri.parse('https://rs.example/.well-known/oauth-protected-resource'));
      expect(c.scopes, ['files:read']);
    });

    test('BWS around "=" is accepted', () {
      final c = WwwAuthenticate.parse('Bearer scope = "a" , error= invalid_token').find('bearer')!;
      expect(c.param('scope'), 'a');
      expect(c.param('error'), 'invalid_token');
    });

    test('malformed input never throws', () {
      final samples = [
        'Bearer scope="unterminated',
        '"Bearer"',
        '=====',
        'Bearer ,,, =x, y=',
        'Bearer été="x"',
        'Bearer a="b" c="d" e',
        r'Bearer a="\',
        ', Bearer',
      ];
      for (final s in samples) {
        expect(() => WwwAuthenticate.parse(s), returnsNormally, reason: s);
      }
      final rnd = Random(7);
      const alphabet = 'Bearer DPoP=",\\ \t scope resource_metadata error abc=+/';
      for (var i = 0; i < 2000; i++) {
        final s = String.fromCharCodes(List.generate(rnd.nextInt(60), (_) => alphabet.codeUnitAt(rnd.nextInt(alphabet.length))));
        expect(() => BearerChallenge.parse(s), returnsNormally, reason: s);
      }
    });

    test('an unterminated quote drops only that parameter', () {
      final c = WwwAuthenticate.parse('Bearer scope="a", error_description="oops').find('Bearer')!;
      expect(c.param('scope'), 'a');
      expect(c.param('error_description'), isNull);
    });
  });
}
