/// Pure-Dart agent core for Sherpa.
///
/// Layering: this package depends on nothing but `meta`. Providers, MCP,
/// the Hub client, persistence and the Flutter app all depend on it, never
/// the other way round.
library;

export 'src/agent/agent_event.dart';
export 'src/agent/agent_runner.dart';
export 'src/agent/approval_handler.dart';
export 'src/agent/prompt_boundary.dart';
export 'src/common/cancellation.dart';
export 'src/common/clock.dart';
export 'src/common/ids.dart';
export 'src/common/json.dart';
export 'src/common/secrets.dart';
export 'src/context/budget.dart';
export 'src/context/compaction.dart';
export 'src/context/context_manager.dart';
export 'src/context/overlay.dart';
export 'src/context/part_rewrite.dart';
export 'src/context/passthrough_context_manager.dart';
export 'src/context/token_estimator.dart';
export 'src/memory/memory_monitor.dart';
export 'src/model/content.dart';
export 'src/model/message.dart';
export 'src/model/tool.dart';
export 'src/provider/capabilities.dart';
export 'src/provider/model_event.dart';
export 'src/provider/model_provider.dart';
export 'src/session/checkpoint.dart';
export 'src/session/in_memory_store.dart';
export 'src/session/plan.dart';
export 'src/session/session_store.dart';
export 'src/tools/approval.dart';
export 'src/tools/composite_router.dart';
export 'src/tools/plan_tool.dart';
export 'src/tools/tool_router.dart';
