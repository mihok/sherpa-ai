/// iOS on-device model providers for Sherpa: MLX Swift (mlx-swift-lm) and
/// Apple Foundation Models, behind Pigeon.
///
/// On Android, desktop and host tests every class still compiles and the
/// availability APIs report [AppleMlStatus.unsupported].
library;

export 'src/availability.dart';
export 'src/backend.dart' show AppleMl, AppleMlBackend, PigeonAppleMlBackend, UnsupportedAppleMlBackend;
export 'src/common/errors.dart' show AppleMlErrorCode, errorKindForCode;
export 'src/common/history_planner.dart' show AppendShape, HistoryPlan, HistoryPlanner, SessionLedger;
export 'src/fm/fm_provider.dart' show AppleFoundationModelsProvider, FmProviderConfig;
export 'src/fm/fm_schema.dart' show FmSchemaConverter, FmSchemaResult;
export 'src/messages.pigeon.dart' show AmEvent, AmEventKind;
export 'src/mlx/mlx_config.dart';
export 'src/mlx/mlx_mapping.dart' show MlxLoadedModel;
export 'src/mlx/mlx_model_dir.dart';
export 'src/mlx/mlx_provider.dart';
