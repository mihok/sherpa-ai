import 'support/harnesses.dart';
import 'support/session_store_contract.dart';

void main() {
  sessionStoreContract('InMemorySessionStore', () async => InMemoryHarness());
  sessionStoreContract('DriftSessionStore (in-memory)', () async => DriftMemoryHarness());
  sessionStoreContract('DriftSessionStore (encrypted file, background isolate)', DriftFileHarness.open);
  sessionStoreContract(
    'DriftSessionStore (encrypted file, same isolate)',
    () => DriftFileHarness.open(background: false),
  );
}
