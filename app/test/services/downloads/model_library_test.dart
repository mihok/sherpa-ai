import 'dart:io';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa/services/device/device_profile_source.dart';
import 'package:sherpa/services/downloads/downloads.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_hub/sherpa_hub.dart';

import '../support/gguf_fixture.dart';

void main() {
  late Directory dir;
  late ModelLibrary library;
  late ModelStorageLayout layout;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('sherpa_lib_');
    layout = ModelStorageLayout('${dir.path}/models');
    library = ModelLibrary(store: InMemoryRecordStore(), layout: layout, ids: SequentialIdGenerator());
    await library.load();
  });
  tearDown(() async {
    await library.dispose();
    await dir.delete(recursive: true);
  });

  const phone = DeviceProfile(platform: DevicePlatform.android, totalRamBytes: 8 << 30);

  group('import', () {
    test('imports the head of a real Qwen3-0.6B GGUF: header metadata, SHA-256, copy into the library', () async {
      final src = await realGgufHead(dir);
      if (src == null) {
        markTestSkipped('/opt/models/Qwen3-0.6B-Q4_K_M.gguf is not available');
        return;
      }
      final o = await library.importFile(PathModelFile(src), freeStorageBytes: 32 << 30, device: phone);
      expect(o, isA<Imported>(), reason: o is ImportRefused ? o.reason : '$o');
      final m = (o as Imported).model;
      expect(m.source, LibrarySource.imported);
      expect(m.architecture, 'qwen3');
      expect(m.quant, 'Q4_K_M', reason: 'general.file_type 15 from the header, not the name');
      expect(m.contextLength, 40960);
      expect(m.toolUse, isTrue, reason: "Qwen3's template renders tools");
      expect(m.reasoning, isTrue, reason: 'and <think>');
      expect(m.displayName, isNotEmpty);
      expect(m.defaultContextLength, isNotNull, reason: 'fit-derived default context');
      final installed = File(layout.libraryPath(m.loadPath));
      expect(installed.existsSync(), isTrue);
      expect(m.files.single.sha256, sha256Hex(src.readAsBytesSync()));
      expect(m.sizeBytes, src.lengthSync());
      expect(src.existsSync(), isTrue, reason: 'the user file is copied, not moved');
      expect(Directory(layout.partialDir).listSync(), isEmpty);

      // Importing the same bytes again finds the existing entry.
      final again = await library.importFile(PathModelFile(src), freeStorageBytes: 32 << 30);
      expect(again, isA<AlreadyImported>());
      expect(library.models, hasLength(1));
    });

    test('a picked file without a path is streamed in', () async {
      final bytes = syntheticGguf(totalBytes: 600 << 10);
      final o = await library.importFile(_StreamFile('tiny-Q4_K_M.gguf', bytes), freeStorageBytes: 1 << 30);
      expect(o, isA<Imported>(), reason: o is ImportRefused ? o.reason : '');
      expect((o as Imported).model.files.single.sha256, sha256Hex(bytes));
      expect(o.model.displayName, 'Tiny Llama Test', reason: 'general.name wins over the file name');
    });

    test('refuses pickle-family names outright', () async {
      for (final name in ['pytorch_model.bin', 'consolidated.00.pth', 'model.ckpt', 'weights.pt']) {
        final f = File('${dir.path}/$name')..writeAsBytesSync([0x80, 0x02, 0x63]);
        final o = await library.importFile(PathModelFile(f));
        expect(o, isA<ImportRefused>(), reason: name);
        expect((o as ImportRefused).reason, contains('pickle'));
      }
      expect(library.models, isEmpty);
    });

    test('refuses a pickle renamed to .gguf, a non-GGUF, a big-endian GGUF and a removed quant', () async {
      Future<String> refusal(String name, List<int> bytes) async {
        final f = File('${dir.path}/$name')..writeAsBytesSync(bytes);
        final o = await library.importFile(PathModelFile(f));
        expect(o, isA<ImportRefused>(), reason: name);
        return (o as ImportRefused).reason;
      }

      expect(await refusal('sneaky.gguf', [0x80, 0x04, 0x95, 0, 0, 0, 0, 0, 0, 0]), contains('pickle'));
      expect(await refusal('notes.gguf', 'hello world, not a model'.codeUnits), contains('not a GGUF'));
      expect(await refusal('be.gguf', [0x47, 0x47, 0x55, 0x46, 0, 0, 0, 3, 0, 0, 0, 0]), contains('big-endian'));
      expect(await refusal('old-Q4_0_4_4.gguf', syntheticGguf(totalBytes: 64 << 10, fileType: 33)), contains('removed'));
      expect(await refusal('model.safetensors', [1, 2, 3]), contains('Only GGUF'));
      expect(library.models, isEmpty);
      expect(Directory(layout.partialDir).existsSync() ? Directory(layout.partialDir).listSync() : const <FileSystemEntity>[], isEmpty);
    });

    test('refuses when the copy would not fit in free storage', () async {
      final f = File('${dir.path}/tiny.gguf')..writeAsBytesSync(syntheticGguf(totalBytes: 2 << 20));
      final o = await library.importFile(PathModelFile(f), freeStorageBytes: 1 << 20);
      expect((o as ImportRefused).reason, contains('Not enough space'));
    });
  });

  group('helpers', () {
    test('isolate SHA-256 matches package:crypto and reports progress', () async {
      final bytes = Uint8List.fromList(List.generate(5 << 20, (i) => i * 31 & 0xff));
      final f = File('${dir.path}/blob')..writeAsBytesSync(bytes);
      final seen = <int>[];
      final hex = await const IsolateFileHasher(chunkBytes: 1 << 20, progressEvery: 1 << 20)
          .sha256(f.path, onProgress: seen.add);
      expect(hex, sha256Hex(bytes));
      expect(seen.last, bytes.length);
      expect(await const InlineFileHasher().sha256(f.path), hex);
    });

    test('isolate hasher surfaces a missing file as an error', () async {
      await expectLater(const IsolateFileHasher().sha256('${dir.path}/nope'), throwsA(isA<FileSystemException>()));
    });

    test('network kinds from connectivity results', () {
      expect(networkKindOf([ConnectivityResult.wifi]), NetworkKind.wifi);
      expect(networkKindOf([ConnectivityResult.vpn, ConnectivityResult.wifi]), NetworkKind.wifi);
      expect(networkKindOf([ConnectivityResult.mobile]), NetworkKind.cellular);
      expect(networkKindOf([ConnectivityResult.none]), NetworkKind.offline);
      expect(networkKindOf([]), NetworkKind.offline);
      expect(networkKindOf([ConnectivityResult.vpn]), NetworkKind.unknown);
    });

    test('meminfo parsing and the conservative fallback profile', () async {
      expect(parseMeminfoTotal('MemTotal:        3809016 kB\nMemFree: 1 kB'), 3809016 * 1024);
      expect(parseMeminfoTotal('garbage'), isNull);
      final f = File('${dir.path}/meminfo')..writeAsStringSync('MemTotal:        7864320 kB\nMemAvailable: 6000000 kB\n');
      final p = await FallbackDeviceProfileSource(meminfoPath: f.path, platform: DevicePlatform.android).current();
      expect(p.totalRamBytes, 7864320 * 1024);
      expect(p.availableRamBytes, isNull, reason: 'MemAvailable over-states what an app may take');
      final ios = await FallbackDeviceProfileSource(meminfoPath: '${dir.path}/none', platform: DevicePlatform.ios).current();
      expect(ios.totalRamBytes, 4 << 30);
    });

    test('library paths cannot escape the library', () {
      expect(() => layout.libraryPath('../../etc/passwd'), throwsArgumentError);
      expect(layout.libraryPath('a/b.gguf'), endsWith('models/library/a/b.gguf'));
    });

    test('download job JSON never carries the signed URL', () {
      final r = DownloadRecord(
        id: 'dl_1',
        groupId: 'g',
        repo: 'a/b',
        commit: 'c' * 40,
        path: 'x.gguf',
        localPath: 'f/x.gguf',
        role: FileRole.model,
        expectedBytes: 10,
        state: DownloadState.downloading,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        resolvedUrl: Uri.parse('https://us.aws.cdn.hf.co/x?Signature=secret&Expires=1'),
        cdnUrlExpiry: DateTime.utc(2026, 1, 1, 1),
      );
      final j = persistableRecord(r);
      expect(j.containsKey('resolvedUrl'), isFalse);
      expect('$j', isNot(contains('secret')));
      expect(withoutSignedUrl(r).needsResolve(DateTime.utc(2026)), isTrue);
    });
  });
}

final class _StreamFile implements LocalModelFile {
  _StreamFile(this.name, this.bytes);

  @override
  final String name;
  final Uint8List bytes;

  @override
  int? get length => bytes.length;

  @override
  String? get path => null;

  @override
  Stream<List<int>> openRead() async* {
    for (var i = 0; i < bytes.length; i += 64 << 10) {
      yield bytes.sublist(i, i + (64 << 10) > bytes.length ? bytes.length : i + (64 << 10));
    }
  }
}
