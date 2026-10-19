/// Form-mode elicitation: the flat `requestedSchema` subset of
/// client/elicitation.md (R01 §7.1) as fields the app can render natively,
/// with validation, defaults and the content the server gets back.
library;

import 'package:flutter/foundation.dart' show immutable;
import 'package:sherpa_core/sherpa_core.dart' show JsonMap;

/// What one field holds.
enum ElicitationFieldKind {
  /// `type: string` (with an optional [ElicitationTextFormat]).
  text,

  /// `type: number`.
  number,

  /// `type: integer`.
  integer,

  /// `type: boolean`.
  boolean,

  /// `type: string` with `enum` (optionally `enumNames`) or titled `oneOf`.
  singleChoice,

  /// `type: array` of string `enum` items or titled `anyOf`.
  multiChoice,
}

/// String format hints the spec allows (`StringSchema.format`).
enum ElicitationTextFormat { plain, email, uri, date, dateTime }

/// One choice of an enum field: the wire [value] and what to show.
@immutable
final class ElicitationOption {
  const ElicitationOption(this.value, this.label);

  final String value;

  /// Server text (the title, or the value itself).
  final String label;
}

/// One property of the requested schema. Every label and description is
/// UNTRUSTED server text: render it as content, never as app UI.
@immutable
final class ElicitationField {
  const ElicitationField({
    required this.key,
    required this.kind,
    this.title,
    this.description,
    this.required = false,
    this.format = ElicitationTextFormat.plain,
    this.minLength,
    this.maxLength,
    this.minimum,
    this.maximum,
    this.minItems,
    this.maxItems,
    this.options = const [],
    this.defaultValue,
  });

  final String key;
  final ElicitationFieldKind kind;
  final String? title;
  final String? description;
  final bool required;
  final ElicitationTextFormat format;
  final int? minLength;
  final int? maxLength;
  final num? minimum;
  final num? maximum;
  final int? minItems;
  final int? maxItems;
  final List<ElicitationOption> options;

  /// The schema's `default`, already checked against the field's type.
  final Object? defaultValue;

  /// The server's title, else the property name.
  String get label => (title == null || title!.trim().isEmpty) ? key : title!;

  /// The value a fresh form starts with: the default (spec: clients that
  /// support defaults SHOULD pre-fill them), `false` for a boolean.
  Object? get initialValue => switch (kind) {
        ElicitationFieldKind.boolean => defaultValue ?? false,
        ElicitationFieldKind.multiChoice => defaultValue ?? const <String>[],
        ElicitationFieldKind.number || ElicitationFieldKind.integer => defaultValue?.toString(),
        _ => defaultValue,
      };

  static final RegExp _email = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
  static final RegExp _date = RegExp(r'^\d{4}-\d{2}-\d{2}$');

  /// Why [value] (as the form holds it: a `String` for text and number
  /// fields, `bool`, `String?` choice, `List<String>`) is not acceptable,
  /// or null.
  String? validate(Object? value) {
    switch (kind) {
      case ElicitationFieldKind.boolean:
        return null;
      case ElicitationFieldKind.multiChoice:
        final list = value is List ? value : const <Object?>[];
        if (required && list.isEmpty) return 'Choose at least one.';
        if (list.isEmpty) return null;
        if (minItems != null && list.length < minItems!) return 'Choose at least $minItems.';
        if (maxItems != null && list.length > maxItems!) return 'Choose at most $maxItems.';
        return null;
      case ElicitationFieldKind.singleChoice:
        final s = value is String ? value : null;
        if (s == null || s.isEmpty) return required ? 'Choose one.' : null;
        return options.any((o) => o.value == s) ? null : 'Choose one of the options.';
      case ElicitationFieldKind.number || ElicitationFieldKind.integer:
        final s = (value is String ? value : value?.toString() ?? '').trim();
        if (s.isEmpty) return required ? 'Required.' : null;
        final n = parseNumber(s);
        if (n == null) return kind == ElicitationFieldKind.integer ? 'Enter a whole number.' : 'Enter a number.';
        if (minimum != null && n < minimum!) return 'At least ${_fmt(minimum!)}.';
        if (maximum != null && n > maximum!) return 'At most ${_fmt(maximum!)}.';
        return null;
      case ElicitationFieldKind.text:
        final s = value is String ? value : '';
        if (s.trim().isEmpty) return required ? 'Required.' : null;
        final length = s.runes.length;
        if (minLength != null && length < minLength!) return 'At least $minLength characters.';
        if (maxLength != null && length > maxLength!) return 'At most $maxLength characters.';
        switch (format) {
          case ElicitationTextFormat.email:
            if (!_email.hasMatch(s.trim())) return 'Enter an email address.';
          case ElicitationTextFormat.uri:
            final u = Uri.tryParse(s.trim());
            if (u == null || !u.hasScheme || u.scheme.isEmpty) return 'Enter a full address (with https://).';
          case ElicitationTextFormat.date:
            if (!_validDate(s.trim())) return 'Enter a date as YYYY-MM-DD.';
          case ElicitationTextFormat.dateTime:
            if (DateTime.tryParse(s.trim()) == null) return 'Enter a date and time (YYYY-MM-DDTHH:MM).';
          case ElicitationTextFormat.plain:
            break;
        }
        return null;
    }
  }

  /// A real calendar date (DateTime.parse would roll 2026-13-45 over).
  static bool _validDate(String s) {
    final m = _date.firstMatch(s);
    if (m == null) return false;
    final d = DateTime.tryParse(s);
    if (d == null) return false;
    final [y, mo, da] = s.split('-').map(int.parse).toList();
    return d.year == y && d.month == mo && d.day == da;
  }

  /// [s] as this field's number type, or null.
  num? parseNumber(String s) => kind == ElicitationFieldKind.integer ? int.tryParse(s.trim()) : num.tryParse(s.trim());

  /// The wire value of a valid [value], or null to leave it out.
  Object? wireValue(Object? value) => switch (kind) {
        ElicitationFieldKind.boolean => value is bool ? value : false,
        ElicitationFieldKind.multiChoice => value is List && value.isNotEmpty ? [for (final v in value) '$v'] : null,
        ElicitationFieldKind.singleChoice => value is String && value.isNotEmpty ? value : null,
        ElicitationFieldKind.number || ElicitationFieldKind.integer => () {
            final s = (value is String ? value : value?.toString() ?? '').trim();
            return s.isEmpty ? null : parseNumber(s);
          }(),
        ElicitationFieldKind.text => value is String && value.trim().isNotEmpty ? value.trim() : null,
      };

  static String _fmt(num n) => n == n.roundToDouble() ? n.round().toString() : n.toString();
}

/// A parsed `requestedSchema`.
@immutable
final class ElicitationForm {
  const ElicitationForm({required this.fields, this.unsupported = const [], this.unsupportedRequired = const [], this.secretReason});

  /// Parses the flat schema; never throws. Properties outside the spec's
  /// primitive subset (nested objects, arrays of objects, …) land in
  /// [unsupported]; when one of them is required the form cannot be
  /// accepted ([canAccept]).
  factory ElicitationForm.parse(JsonMap schema) {
    final props = schema['properties'];
    final required = {
      if (schema['required'] is List)
        for (final r in schema['required']! as List)
          if (r is String) r,
    };
    final fields = <ElicitationField>[];
    final unsupported = <String>[];
    String? secret;
    if (props is Map) {
      for (final e in props.entries.take(64)) {
        final key = '${e.key}';
        final p = e.value;
        if (p is! Map) {
          unsupported.add(key);
          continue;
        }
        final prop = p.cast<String, Object?>();
        secret ??= sensitiveFieldReason(key, prop);
        final f = _field(key, prop, required.contains(key));
        if (f == null) {
          unsupported.add(key);
        } else {
          fields.add(f);
        }
      }
    }
    return ElicitationForm(
      fields: fields,
      unsupported: unsupported,
      unsupportedRequired: [for (final k in unsupported) if (required.contains(k)) k],
      secretReason: secret,
    );
  }

  final List<ElicitationField> fields;

  /// Property names Sherpa cannot render.
  final List<String> unsupported;

  /// Of [unsupported], the required ones.
  final List<String> unsupportedRequired;

  /// Set when a field asks for a secret (password, API key, token, payment
  /// or bank details, one-time code): servers MUST NOT request those in
  /// form mode (client/elicitation.md), so Sherpa refuses the form.
  final String? secretReason;

  bool get asksForSecret => secretReason != null;

  /// The user can send this form at all.
  bool get canAccept => !asksForSecret && unsupportedRequired.isEmpty;

  /// Every field's starting value, by key.
  Map<String, Object?> initialValues() => {for (final f in fields) f.key: f.initialValue};

  /// Errors by key for [values] (empty: valid).
  Map<String, String> validate(Map<String, Object?> values) => {
        for (final f in fields)
          if (f.validate(values[f.key]) case final String error) f.key: error,
      };

  /// The `ElicitResult.content` for valid [values]: filled fields only,
  /// typed as the schema says (`string | number | boolean | string[]`).
  Map<String, Object?> content(Map<String, Object?> values) => {
        for (final f in fields)
          if (f.wireValue(values[f.key]) case final Object v) f.key: v,
      };

  static ElicitationField? _field(String key, Map<String, Object?> p, bool required) {
    String? str(String k) => p[k] is String ? p[k]! as String : null;
    int? integer(String k) => p[k] is int ? p[k]! as int : (p[k] is double ? (p[k]! as double).toInt() : null);
    num? number(String k) => p[k] is num ? p[k]! as num : null;
    final type = p['type'];
    final title = str('title');
    final description = str('description');
    switch (type) {
      case 'string':
        final options = _stringOptions(p);
        if (options != null) {
          if (options.isEmpty) return null;
          final d = p['default'];
          return ElicitationField(
            key: key,
            kind: ElicitationFieldKind.singleChoice,
            title: title,
            description: description,
            required: required,
            options: options,
            defaultValue: d is String && options.any((o) => o.value == d) ? d : null,
          );
        }
        final format = switch (str('format')) {
          'email' => ElicitationTextFormat.email,
          'uri' => ElicitationTextFormat.uri,
          'date' => ElicitationTextFormat.date,
          'date-time' => ElicitationTextFormat.dateTime,
          _ => ElicitationTextFormat.plain,
        };
        final d = p['default'];
        return ElicitationField(
          key: key,
          kind: ElicitationFieldKind.text,
          title: title,
          description: description,
          required: required,
          format: format,
          minLength: integer('minLength'),
          maxLength: integer('maxLength'),
          defaultValue: d is String ? d : null,
        );
      case 'number' || 'integer':
        final isInt = type == 'integer';
        final d = p['default'];
        return ElicitationField(
          key: key,
          kind: isInt ? ElicitationFieldKind.integer : ElicitationFieldKind.number,
          title: title,
          description: description,
          required: required,
          minimum: number('minimum'),
          maximum: number('maximum'),
          defaultValue: d is num && (!isInt || d == d.roundToDouble()) ? (isInt ? d.toInt() : d) : null,
        );
      case 'boolean':
        final d = p['default'];
        return ElicitationField(
          key: key,
          kind: ElicitationFieldKind.boolean,
          title: title,
          description: description,
          required: required,
          defaultValue: d is bool ? d : null,
        );
      case 'array':
        final items = p['items'];
        if (items is! Map) return null;
        final options = _stringOptions(items.cast<String, Object?>());
        if (options == null || options.isEmpty) return null;
        final d = p['default'];
        return ElicitationField(
          key: key,
          kind: ElicitationFieldKind.multiChoice,
          title: title,
          description: description,
          required: required,
          minItems: integer('minItems'),
          maxItems: integer('maxItems'),
          options: options,
          defaultValue: d is List
              ? [
                  for (final v in d)
                    if (v is String && options.any((o) => o.value == v)) v,
                ]
              : null,
        );
      default:
        return null;
    }
  }

  /// The choices of an enum schema: untitled `enum` (+ legacy `enumNames`),
  /// titled `oneOf` / `anyOf` of `{const, title}`. Null when [p] is not an
  /// enum.
  static List<ElicitationOption>? _stringOptions(Map<String, Object?> p) {
    final e = p['enum'];
    if (e is List) {
      final names = p['enumNames'] is List ? p['enumNames']! as List : const <Object?>[];
      return [
        for (final (i, v) in e.take(200).indexed)
          if (v is String) ElicitationOption(v, i < names.length && names[i] is String ? names[i]! as String : v),
      ];
    }
    final titled = p['oneOf'] ?? p['anyOf'];
    if (titled is List) {
      return [
        for (final o in titled.take(200))
          if (o is Map && o['const'] is String)
            ElicitationOption(o['const']! as String, o['title'] is String ? o['title']! as String : o['const']! as String),
      ];
    }
    return null;
  }
}

/// Why the property [key] ([prop]) asks for a secret, or null.
///
/// client/elicitation.md: servers MUST NOT use form mode to request
/// sensitive information such as passwords, API keys, access tokens or
/// payment credentials (those belong in URL mode, where the user types
/// them into the service's own page). Checked on the property name, its
/// title and its format; descriptions are not, because "we will never ask
/// for your password" must not trip it.
String? sensitiveFieldReason(String key, Map<String, Object?> prop) {
  if (prop['format'] == 'password' || prop['writeOnly'] == true) return 'a password or other secret';
  for (final raw in [key, if (prop['title'] is String) prop['title']! as String]) {
    final words = _words(raw);
    for (final (pattern, what) in _sensitive) {
      if (pattern.hasMatch(words)) return what;
    }
  }
  return null;
}

/// `apiKey` / `api_key` / `API-Key` → ` api key `.
String _words(String s) {
  final spaced = s
      .replaceAllMapped(RegExp('([a-z0-9])([A-Z])'), (m) => '${m[1]} ${m[2]}')
      .replaceAll(RegExp(r'[_\-./:]+'), ' ')
      .toLowerCase();
  return ' ${spaced.replaceAll(RegExp(r'\s+'), ' ').trim()} ';
}

final List<(RegExp, String)> _sensitive = [
  (RegExp(r' (password|passwd|passphrase|passcode|pass code|pwd) '), 'a password'),
  (RegExp(r' pin( code| number)? '), 'a PIN'),
  (RegExp(r' (api|access|secret|private|signing|license) key '), 'an API key or private key'),
  (RegExp(r' apikey '), 'an API key'),
  (RegExp(r' (client )?secret '), 'a secret'),
  (RegExp(r' ((access|auth|bearer|refresh|session|api|personal access|id) )?token '), 'an access token'),
  (RegExp(r' (credit|debit) card '), 'payment card details'),
  (RegExp(r' card (number|no|num) '), 'payment card details'),
  (RegExp(r' (cvv|cvc|csc|cvv2|security code) '), 'a card security code'),
  (RegExp(r' (iban|swift|bic|routing number|sort code|bank account|account number) '), 'bank details'),
  (RegExp(r' (ssn|social security( number)?) '), 'a social security number'),
  (RegExp(r' (otp|one time (pass)?code|one time password|2fa( code)?|mfa( code)?|totp|verification code|auth code|authentication code) '), 'a one-time sign-in code'),
  (RegExp(r' (seed phrase|recovery phrase|mnemonic|private key) '), 'a wallet recovery phrase or private key'),
];
