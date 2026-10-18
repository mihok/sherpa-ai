/// Building blocks shared by every remote adapter: abortable HTTP
/// streaming, error mapping, tool-name sanitizing, tool-call assembly and
/// JSON repair, plus the OpenAI-style message mapper.
library;

export 'endpoint_policy.dart';
export 'error_mapping.dart';
export 'hashing.dart';
export 'http_runner.dart';
export 'json_read.dart';
export 'json_repair.dart';
export 'openai_messages.dart';
export 'stream_guard.dart';
export 'think_splitter.dart';
export 'tool_call_accumulator.dart';
export 'tool_names.dart';
