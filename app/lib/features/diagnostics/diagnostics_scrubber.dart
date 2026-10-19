import 'package:sherpa_core/sherpa_core.dart' show HandoffScrubbers;
import 'package:sherpa_net/sherpa_net.dart';

/// The last line of defense for the diagnostics export: every string in
/// the bundle and its summary goes through [text], after the collector has
/// already copied only allowlisted fields.
///
/// In order:
/// 1. every value from the secret store (API keys, OAuth and HF tokens) is
///    masked wherever it appears verbatim, whatever its format;
/// 2. URLs are cut down to `scheme://host[:port]`: no user info, path,
///    query or fragment (a URL with no host is masked whole);
/// 3. token-shaped text ([Redactor.text]) and `key=value` / `"key": "value"`
///    secrets ([HandoffScrubbers.basic]);
/// 4. file paths under a home or app-data directory, the user's own home
///    directory by value, and e-mail addresses.
final class DiagnosticsScrubber {
  DiagnosticsScrubber({Iterable<String> knownSecrets = const [], Iterable<String> homePaths = const []})
      : _secrets = _longestFirst(knownSecrets.where((s) => s.length >= minSecretLength)),
        _homes = [
          for (final h in _longestFirst(homePaths.map(_trimSlash).where((p) => p.length >= 4)))
            RegExp('${RegExp.escape(h)}$_pathTail'),
        ];

  static const String mask = Redactor.mask;
  static const String pathMask = '«path»';
  static const String emailMask = '«email»';

  /// Shorter stored values are not masked by value (a 4-character value
  /// would blank out ordinary words); the patterns still apply.
  static const int minSecretLength = 8;

  /// Strings longer than this are cut (no field needs more).
  static const int maxLength = 600;

  final List<String> _secrets;

  /// Each private directory and whatever path follows it.
  final List<RegExp> _homes;

  /// The rest of a path: up to whitespace, a quote or a separator.
  static const String _pathTail = r'''[^\s"'<>,;)\]]*''';

  static String _trimSlash(String p) => p.length > 1 && p.endsWith('/') ? p.substring(0, p.length - 1) : p;

  static List<String> _longestFirst(Iterable<String> values) =>
      values.toSet().toList()..sort((a, b) => b.length.compareTo(a.length));

  static final RegExp _url = RegExp(r'''\b[a-zA-Z][a-zA-Z0-9+.\-]{1,15}://[^\s"'<>\\`]+''');

  /// Directories that hold user or app data on Android, iOS, macOS, Linux
  /// and Windows; whatever follows them is the user's business.
  static final RegExp _dataPath = RegExp(
    r'''(?:/(?:home|Users|root)/|/data/(?:user(?:_de)?/\d+|data|app|local|media)/|/storage/(?:emulated/\d+|self|[0-9A-F]{4}-[0-9A-F]{4})/|/sdcard/|/mnt/(?:sdcard|user)/|/(?:private/)?var/(?:mobile|containers|folders)/|[A-Za-z]:\\(?:Users|Documents and Settings)\\|~/)'''
    '$_pathTail',
  );

  static final RegExp _email = RegExp(r'\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)+\b');

  /// [input] scrubbed, cut to [limit] characters (null: uncut).
  String text(String input, {int? limit = maxLength}) {
    var s = input;
    for (final secret in _secrets) {
      if (s.contains(secret)) s = s.replaceAll(secret, mask);
    }
    s = s.replaceAllMapped(_url, (m) => urlToOrigin(m[0]!));
    s = HandoffScrubbers.basic(Redactor.text(s)).replaceAll(_dataPath, pathMask);
    for (final home in _homes) {
      s = s.replaceAll(home, pathMask);
    }
    s = s.replaceAll(_email, emailMask);
    return limit != null && s.length > limit ? '${s.substring(0, limit - 1)}…' : s;
  }

  /// `https://user:pw@host:8443/v1?key=x#f` → `https://host:8443`.
  static String urlToOrigin(String raw) {
    final u = Uri.tryParse(raw);
    if (u == null || u.host.isEmpty) return mask;
    final defaultPort = (u.scheme == 'https' && u.port == 443) || (u.scheme == 'http' && u.port == 80);
    return '${u.scheme}://${u.host}${!u.hasPort || defaultPort ? '' : ':${u.port}'}';
  }

  /// Every string in a JSON-like tree (map keys included) through [text].
  Object? tree(Object? v) => switch (v) {
        final String s => text(s),
        final Map<Object?, Object?> m => <String, Object?>{for (final e in m.entries) text('${e.key}'): tree(e.value)},
        final List<Object?> l => [for (final e in l) tree(e)],
        _ => v,
      };

  /// The known secret values that occur in [encoded] (a self-check: empty
  /// for every bundle this scrubber produced).
  List<String> leaks(String encoded) => [for (final s in _secrets) if (encoded.contains(s)) s];
}
