/// Test doubles for code above the engine boundary (provider, lifecycle,
/// scheduler, autotune, prefix cache, and app wiring), plus the process
/// host's transport seam ([InferenceTransport] and the Pigeon messages) for
/// driving a [ProcessEngineHost] without a device. Kept out of the main
/// library so production code cannot depend on them.
library;

export 'src/engine/process_messages.pigeon.dart';
export 'src/engine/process_transport.dart';
export 'src/testing/fake_engine_host.dart';
