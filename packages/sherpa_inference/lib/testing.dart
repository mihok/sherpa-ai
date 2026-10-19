/// Test doubles for code above the engine boundary (provider, lifecycle,
/// scheduler, autotune, prefix cache, and app wiring). Kept out of the main
/// library so production code cannot depend on them.
library;

export 'src/testing/fake_engine_host.dart';
