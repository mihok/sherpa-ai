/// Encrypted local persistence for Sherpa.
///
/// * [SherpaDatabase]: the Drift schema (sessions, message trees, overlays,
///   plans, checkpoints, audit, generic documents) on SQLite3MultipleCiphers.
/// * [openSherpaDatabase]: opens the on-disk database, encrypted and fail
///   closed; [loadOrCreateDatabaseKey] keeps its key in the app's
///   `SecretStore` (Keychain / Android Keystore).
/// * [DriftSessionStore]: the `SessionStore` of `sherpa_core`.
/// * [JsonDocumentStore]: provider configs, preferences, model library, MCP
///   servers and download records as JSON documents.
///
/// Pure Dart (no Flutter): SQLite is bundled by the `sqlite3` package's
/// build hook, so the same code runs in the app and in `dart test`.
library;

export 'src/database/database.dart'
    show SchemaDowngradeException, SchemaUpgrade, SherpaDatabase;
export 'src/database/open.dart'
    show
        DatabaseEncryptionException,
        DatabaseOpenException,
        EncryptionFailure,
        databaseKeySecretName,
        encryptionSetup,
        generateDatabaseKey,
        isValidDatabaseKey,
        loadOrCreateDatabaseKey,
        openSherpaDatabase;
export 'src/drift_session_store.dart';
export 'src/json_document_store.dart';
