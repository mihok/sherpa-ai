import 'dart:io';

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:http/http.dart' as http;
import 'package:sherpa_data/sherpa_data.dart' show JsonDocumentStore;

import '../../services/device/device_profile_source.dart';
import '../../services/downloads/downloads.dart';
import 'state/models_providers.dart';

/// `ProviderScope` overrides that wire the on-device model feature
/// (library, downloads, Hub browser). Spread into `bootstrap()`'s list:
///
/// ```dart
/// ...await modelFeatureOverrides(docs: docs, hubClient: _httpClient()),
/// ```
///
/// - [docs]: the encrypted document store; jobs go to
///   `DocumentCollections.downloads`, models to `.modelLibrary`, browser
///   prefs to `.preferences` (never a token or signed URL).
/// - [hubClient]: the platform HTTP client for Hub API calls (it must
///   honour `followRedirects = false`, which `IOClient` and
///   `CupertinoClient` do); defaults to `http.Client()`.
/// - [device]: the `sherpa_platform` [DeviceProfileSource] once it lands;
///   the conservative fallback is used meanwhile.
/// - [transfers]: replaces background_downloader (tests, previews).
Future<List<Override>> modelFeatureOverrides({
  required JsonDocumentStore docs,
  http.Client? hubClient,
  DeviceProfileSource? device,
  TransferBackend? transfers,
}) async {
  final layout = await ModelStorageLayout.fromSupportDirectory();
  await layout.ensure();
  return [
    modelRecordStoreProvider.overrideWithValue(JsonDocumentRecordStore(docs)),
    modelStorageLayoutProvider.overrideWithValue(layout),
    if (hubClient != null) hubHttpClientProvider.overrideWithValue(hubClient),
    if (device != null) deviceProfileSourceProvider.overrideWithValue(device),
    if (transfers != null) transferBackendProvider.overrideWithValue(transfers),
  ];
}

/// For `bootstrap(inMemory: true)`: volatile records and a temporary
/// directory for model bytes.
Future<List<Override>> inMemoryModelFeatureOverrides({TransferBackend? transfers}) async {
  final dir = await Directory.systemTemp.createTemp('sherpa_models_');
  return [
    modelRecordStoreProvider.overrideWithValue(InMemoryRecordStore()),
    modelStorageLayoutProvider.overrideWithValue(ModelStorageLayout(dir.path)),
    if (transfers != null) transferBackendProvider.overrideWithValue(transfers),
  ];
}
