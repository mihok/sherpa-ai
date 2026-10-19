/// Every number the device-fit engine relies on, with where it came from.
///
/// Tags: **R04/R06/R07/R08** = research digests in `docs/research/`;
/// **SRC** = vendored llama.cpp source; **PROBE** = measured in R04;
/// **POLICY** = a Sherpa choice (no external source; tune with kill
/// forensics and the perf lab); **UNVERIFIED** = an assumption the digests
/// flag as not reproduced.
library;

const int _mib = 1024 * 1024;

abstract final class FitConstants {
  /// llama.cpp pads `n_ctx` up to a multiple of 256 (1000 → 1024), and pads
  /// each sequence again when `kv_unified` is false. R04 §0.8, §5
  /// (`src/llama-context.cpp:290-305`), PROBE-1.
  static const int contextPadding = 256;

  /// SWA cache size when `swa_full` is false:
  /// `pad256(min(n_ctx, n_swa·(unified ? n_seq : 1) + n_ubatch))`.
  /// R04 §5 (`src/llama-kv-cache-iswa.cpp:73-80`).
  static const int swaPadding = 256;

  // ---- compute buffer (R04 §6, PROBE-1b) ------------------------------------
  //
  // Measured on Qwen3-0.6B (n_embd 1024, n_ff 3072, vocab 151,936), q8_0 KV,
  // n_ctx 4096, flash attention on:
  //   n_ubatch 512, n_outputs 512 → 302.8 MiB;  n_outputs 1 → 30.1 MiB
  //   n_ubatch 256, n_outputs 1   →  15.1 MiB;  n_ubatch 128 → 7.6 MiB
  // Model fitted to those five points (all within 0.5 %):
  //   ffn  = n_ubatch · 4 B · (3·n_embd + 4·n_ff)
  //   out  = n_outputs · n_vocab · 4 B + n_ubatch · 4 B · 3·n_embd
  //   peak = max(ffn, out)   (ggml-alloc reuses buffers, so peaks don't add)
  // One model only — treat as a UI estimate; the engine's `no_alloc` dry run
  // (R04 §6) is the authority before load.

  /// f32 activation width.
  static const int activationBytes = 4;
  static const int computeEmbdFactor = 3;
  static const int computeFfFactor = 4;

  /// When `feed_forward_length` is missing: the common 3–4× ratio, on the
  /// high side. POLICY.
  static const int fallbackFfMultiplier = 4;

  /// When the vocabulary size is missing. POLICY (Llama-2-era minimum).
  static const int fallbackVocab = 32000;

  // ---- platform memory --------------------------------------------------------

  /// iOS budget rule: `weights + KV + activations ≤ 0.6 × os_proc_available_memory()`.
  /// R06 §5 "Budget rule (proposal)".
  static const double iosFitFraction = 0.6;

  /// Android has no published headroom factor; R07 §2.2 only says the peak
  /// must stay below `min(availMem − threshold, limiter)`. POLICY, UNVERIFIED.
  static const double androidFitFraction = 0.75;

  /// Desktop / host tests. POLICY.
  static const double otherFitFraction = 0.75;

  /// Above this share of the budget the model is expected to be killed
  /// (allocator slack, transient spikes). POLICY.
  static const double tightFraction = 0.95;

  /// iOS jetsam limits by device RAM (R06 §5 table, all [2nd]/UNVERIFIED):
  /// 4 GB → "ActiveHard 2098 MB"; 6 GB → "assume ~3 GB"; 8 GB and 12 GB with
  /// `increased-memory-limit` → ~6,144 MB ("~6 GB per-process cap even on
  /// 12 GB iPhones", R06 §0.5).
  static const int ios4GbCap = 2098 * _mib;
  static const int ios6GbCap = 3072 * _mib;
  static const int iosEntitledCap = 6144 * _mib;

  /// 8 GB+ iPhone without the entitlement: no data (R06 §5 "UNVERIFIED");
  /// assume half of RAM, capped at the entitled limit. POLICY.
  static const double iosUnentitledFraction = 0.5;

  /// Android 17 per-app limiter: "2 GB in the foreground and 1 GB in the
  /// background on 4 GB devices" (R07 §2.3). The ratio for other RAM tiers
  /// is extrapolated from that single published point. UNVERIFIED.
  static const double androidLimiterForegroundFraction = 0.5;
  static const int androidLimiterSinceApiRelease = 17;

  /// When `availMem − threshold` is not supplied: share of total RAM that is
  /// typically available on a running phone. POLICY, UNVERIFIED.
  static const double androidAssumedAvailableFraction = 0.45;
  static const double otherAssumedAvailableFraction = 0.5;

  /// Flutter engine + Dart heap + UI, counted only when availability is
  /// *estimated* (a measured `os_proc_available_memory`/`availMem` already
  /// excludes the running app). POLICY, UNVERIFIED — replace with the perf
  /// lab's measured peak RSS (R12 §7).
  static const int appOverheadBytes = 300 * _mib;

  /// llama.cpp runtime beyond weights/KV/compute: backend registry, thread
  /// pool, output buffers, sampler, chat-template state. POLICY, UNVERIFIED.
  static const int androidRuntimeOverheadBytes = 64 * _mib;

  /// iOS adds the Metal library, pipelines and command buffers. POLICY,
  /// UNVERIFIED.
  static const int iosRuntimeOverheadBytes = 128 * _mib;
  static const int otherRuntimeOverheadBytes = 64 * _mib;

  /// iOS counts weights against the process limit: llama.cpp maps them into
  /// Metal buffers and R06's budget rule includes them. Android does not:
  /// file-backed mmap pages are clean and evictable, and the Android 17
  /// limiter counts anonymous RSS + swap only (R07 §2.3). Both still need
  /// the pages resident in physical RAM for usable speed.
  static const bool iosWeightsCountTowardCap = true;

  /// Projector weights are read into backend buffers by `mtmd`/clip rather
  /// than mmapped, so on Android they count as anonymous memory. SRC-based
  /// reading of `tools/mtmd` (R04 §16 says mtmd is UNVERIFIED by probe).
  static const bool mmprojIsAnonymous = true;

  // ---- other runtimes (MLX, LiteRT-LM) --------------------------------------

  /// MLX on top of weights and KV: activations, tokenizer and buffer cache
  /// (`MlxProviderConfig.overheadBytes`, 384 MB) plus the MLX buffer-cache
  /// limit (`cacheLimitBytes`, 32 MB), the same figures sherpa_apple_ml's
  /// load-time admission uses. POLICY, UNVERIFIED on devices.
  static const int mlxRuntimeOverheadBytes = (384 + 32) * _mib;

  /// MLX caches are 8-bit by default (`MlxKvSettings(kvBits: 8)`, group
  /// 64): 1 byte per value plus an fp16 scale and bias per 64 values, i.e.
  /// 1.0625 bytes per value — exactly llama.cpp's q8_0 row size, so the KV
  /// formula is shared.
  static const int mlxKvBits = 8;

  /// LiteRT-LM beyond the model file: engine, tokenizer, activations and
  /// the sampler. POLICY, UNVERIFIED (R07 §1.1 measured 676 MB in total for
  /// Gemma 4 E2B on the GPU backend).
  static const int liteRtRuntimeOverheadBytes = 192 * _mib;

  /// On the CPU backend LiteRT-LM writes an XNNPACK weight cache of about
  /// the model's size into `EngineConfig.cacheDir` and maps it at load
  /// (sherpa_litert README "Storage": 131 MB for a 143 MB file on the host;
  /// the litert author says "about the model size"). Counted in full, for
  /// storage and for memory (packed weights). POLICY.
  static const double liteRtWeightCacheFraction = 1.0;

  // ---- storage --------------------------------------------------------------

  /// Keep at least this much free after a download so the OS, the encrypted
  /// database and KV-state files keep working. POLICY.
  static const int storageMarginFloorBytes = 1024 * _mib;
  static const double storageMarginFraction = 0.05;

  // ---- quant recommendation ------------------------------------------------

  /// Q8_0 is +0.0026 ppl vs F16 at half the bytes (R08 §12, quantize.cpp
  /// notes); above it extra bytes cost decode speed (memory-bound) for no
  /// measurable quality, so unquantized files are recommended only when no
  /// quantized file fits. POLICY.
  static const bool preferQuantizedOverFloat = true;

  // ---- GPU backends (R07 §1.7) --------------------------------------------

  /// llama.cpp OpenCL (Adreno) quant support: "Q1_0, Q4_0, Q4_1, Q5_0, Q5_1,
  /// Q8_0, Q4_K, Q5_K, Q6_K, MXFP4 and IQ4_NL" (main tensor types).
  static const Set<String> openclTensorTypes = {
    'Q1_0', 'Q4_0', 'Q4_1', 'Q5_0', 'Q5_1', 'Q8_0', 'Q4_K', 'Q5_K', 'Q6_K', 'MXFP4', 'IQ4_NL', 'F16', 'F32',
  };
}
