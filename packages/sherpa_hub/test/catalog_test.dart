import 'dart:io';

import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_hub/sherpa_hub.dart';
import 'package:sherpa_hub/testing.dart';
import 'package:test/test.dart';

void main() {
  test('FixtureModelCatalog pages and filters', () async {
    final entries = [
      for (final id in ['bartowski/A-1B-GGUF', 'unsloth/B-2B-GGUF', 'bartowski/C-3B-GGUF'])
        CatalogEntry(id: id, name: parseModelName(id), tags: const ['gguf']),
    ];
    final c = FixtureModelCatalog(entries: entries);
    final p1 = await c.search(const ModelSearchQuery(authors: ['bartowski'], limit: 1));
    expect(p1.items.single.id, 'bartowski/A-1B-GGUF');
    final p2 = await c.search(const ModelSearchQuery(authors: ['bartowski'], limit: 1), cursor: p1.nextCursor);
    expect(p2.items.single.id, 'bartowski/C-3B-GGUF');
    expect(p2.hasMore, isFalse);
    expect((await c.search(const ModelSearchQuery(format: HubFormatFilter.mlx))).items, isEmpty);
  });

  test('local capabilities come from the file\'s own header', () {
    final raf = File('/opt/models/Qwen3-0.6B-Q4_K_M.gguf').openSync();
    addTearDown(raf.closeSync);
    final h = GgufReader.parse(raf.readSync(6 << 20), readTensorInfo: false) as GgufHeader;
    final caps = localModelCapabilities(metadata: h.metadata, contextLength: 8192, parameterCount: 596049920);
    expect(caps.toolCallFormat, ToolCallFormat.jsonGrammar);
    expect(caps.reasoning, ReasoningSupport.optional);
    expect(caps.quantization, 'Q4_K_M');
    expect(caps.historyPolicy, HistoryPolicy.appendOnly);
    expect(caps.tokenizerFamily, 'qwen2');
    expect(ModelCapabilities.fromJson(caps.toJson()).toJson(), caps.toJson());
  }, skip: File('/opt/models/Qwen3-0.6B-Q4_K_M.gguf').existsSync() ? false : 'needs the local model');

  test('DeviceProfile from a MemoryMonitor sample', () {
    const s = MemoryState(
        pressure: MemoryPressure.moderate, availableBytes: 3 << 30, totalBytes: 8 << 30, thermal: ThermalLevel.serious);
    final d = DeviceProfile.fromMemoryState(s, platform: DevicePlatform.ios, totalRamBytes: 0, osVersion: '26.1');
    expect(d.availableRamBytes, 3 << 30);
    expect(d.totalRamBytes, 8 << 30);
    expect(d.thermal, ThermalLevel.serious);
    expect(d.osMajor, 26);
  });
}
