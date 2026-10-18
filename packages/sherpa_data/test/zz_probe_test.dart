import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  test('probe', () {
    final db = sqlite3.openInMemory();
    print('version ${sqlite3.version}');
    print('cipher ${db.select('PRAGMA cipher')}');
    db.close();
  });
}
