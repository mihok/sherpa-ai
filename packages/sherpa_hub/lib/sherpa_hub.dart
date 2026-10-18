/// Hugging Face Hub model directory for Sherpa (pure Dart, no Flutter).
///
/// - [HfHubClient]: search (filter/sort/Link cursors), model info with
///   blobs + scan status, tree listing, resolve-without-redirect, GGUF
///   header Range peek, rate limits (R08).
/// - [GgufReader] / [GgufMetadata]: header + KV metadata from bytes.
/// - [parseModelName]: repo/file/branch name decoding with tooltips.
/// - [assessFit] / [recommendQuant] / [assessStorage]: device fit.
/// - [planDownload] / [DownloadRecord]: what to fetch and how to resume.
/// - [ModelCatalog] / [HfHubCatalog]: the browser-facing interface.
library;

export 'src/download/download_plan.dart';
export 'src/download/download_record.dart';
export 'src/download/file_safety.dart';
export 'src/download/verify.dart';
export 'src/fit/device_fit.dart';
export 'src/fit/device_profile.dart';
export 'src/fit/fit_constants.dart';
export 'src/fit/model_architecture.dart';
export 'src/gguf/ggml_types.dart';
export 'src/gguf/gguf_metadata.dart';
export 'src/gguf/gguf_reader.dart';
export 'src/hub/catalog.dart';
export 'src/hub/hub_client.dart';
export 'src/hub/hub_exception.dart';
export 'src/hub/hub_models.dart';
export 'src/hub/rate_limit.dart';
export 'src/naming/model_name.dart';
export 'src/naming/name_types.dart';
export 'src/naming/quant_types.dart';
