/// Tool-argument parsing shared by every parser path (remote adapters and
/// the on-device engine): strict JSON, the R11 §d.3 repairs, and strict
/// mode's refusals (duplicate keys, leaked chat-template tokens, ambiguous
/// unquoted values). Depends on nothing but `sherpa_core` and `meta`.
library;

export 'src/common/json_repair.dart';
