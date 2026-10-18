/// Reads the result of `PRAGMA cipher`.
///
/// SQLite3MultipleCiphers answers with one row whose only value is the
/// cipher name (`[{chacha20: chacha20}]`). Plain SQLite does not know the
/// pragma and answers with no rows, which is how a build that silently lost
/// the `hooks.user_defines.sqlite3.source: sqlite3mc` setting is detected.
String? cipherFromRows(Iterable<Map<String, Object?>> rows) {
  for (final row in rows) {
    for (final value in row.values) {
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
  }
  return null;
}
