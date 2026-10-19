import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show debugPrint, immutable;
import 'package:flutter/widgets.dart' show AppLifecycleListener, WidgetsBinding;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_core/sherpa_core.dart';
import 'package:sherpa_hub/sherpa_hub.dart' show DeviceProfile;
import 'package:sherpa_inference/sherpa_inference.dart';
import 'package:sherpa_platform/sherpa_platform.dart' show ProcessPhase, ProcessStateRecorder, ProcessStateSummary;

import '../../app_info.dart';
import '../../state/services.dart' show localProviderId;
import '../device/device_profile_source.dart';
import '../downloads/model_library.dart';
import '../downloads/storage_layout.dart';
import 'autotune_scheduler.dart';
import 'local_engine_host.dart';
import 'local_model_provider.dart';
import 'local_model_specs.dart';
import 'record_key_value_store.dart';

/// Where the on-device engine is in its life.
enum LocalEngineState {
  /// Not started yet (it starts after the first frame, or on first use).
  idle,
  starting,
  ready,

  /// The engine can't run here (no library in this build, wrong ABI, the
  /// host failed to start). Local models show as unavailable with
  /// [LocalEngineStatus.reason]; nothing else is affected.
  unavailable,
}

/// What the UI shows about the engine.
@immutable
final class LocalEngineStatus {
  const LocalEngineStatus({
    required this.state,
    this.reason,
    this.crashReport,
    this.engineVersion,
    this.hostKind,
    this.canRetry = false,
  });

  static const LocalEngineStatus idle = LocalEngineStatus(state: LocalEngineState.idle);

  final LocalEngineState state;

  /// Why the engine is unavailable (a sentence fragment).
  final String? reason;

  /// The previous run ended while the engine was busy; shown until the user
  /// dismisses it ([LocalInference.acknowledgeCrashReport]).
  final EngineCrashReport? crashReport;

  /// `se_version_string()` once ready.
  final String? engineVersion;
  final EngineHostKind? hostKind;

  /// The engine process stopped after crashing repeatedly; the user may try
  /// again ([LocalInference.retryEngine]).
  final bool canRetry;

  bool get isReady => state == LocalEngineState.ready;

  bool get isUnavailable => state == LocalEngineState.unavailable;

  /// The sentence the picker and the library show for an unavailable engine.
  String? get unavailableMessage =>
      isUnavailable ? 'On-device models are unavailable: ${reason ?? 'the engine did not start'}.' : null;

  LocalEngineStatus withoutCrashReport() => LocalEngineStatus(
      state: state, reason: reason, engineVersion: engineVersion, hostKind: hostKind, canRetry: canRetry);

  LocalEngineStatus copyWith({
    LocalEngineState? state,
    String? reason,
    EngineCrashReport? crashReport,
    bool? canRetry,
  }) =>
      LocalEngineStatus(
        state: state ?? this.state,
        reason: reason ?? this.reason,
        crashReport: crashReport ?? this.crashReport,
        engineVersion: engineVersion,
        hostKind: hostKind,
        canRetry: canRetry ?? this.canRetry,
      );
}

/// Where the engine keeps its files, and how it behaves. Built once in
/// bootstrap ([platformDefault] or [temporary]).
@immutable
final class LocalInferenceConfig {
  const LocalInferenceConfig({
    required this.supportDirectory,
    required this.cacheDirectory,
    this.hostFactory = createLocalEngineHost,
    this.backgroundPolicy,
    this.recordProcessState,
    this.autoStart = true,
    this.startDelay = const Duration(seconds: 2),
    this.observeAppLifecycle = true,
    this.autotune = const AutotunePolicy(),
    this.sessionDefaults = const SessionConfig(),
    this.maxContext = kMaxDefaultLocalContext,
    this.appVersion = AppInfo.version,
  });

  /// `<app support>` and `<app caches>` from path_provider.
  static Future<LocalInferenceConfig> platformDefault() async {
    final support = await getApplicationSupportDirectory();
    final caches = await getApplicationCacheDirectory();
    return LocalInferenceConfig(supportDirectory: support.path, cacheDirectory: caches.path);
  }

  /// A throwaway directory (`bootstrap(inMemory: true)`).
  static Future<LocalInferenceConfig> temporary({EngineHostFactory hostFactory = createLocalEngineHost}) async {
    final dir = await Directory.systemTemp.createTemp('sherpa_inference_');
    return LocalInferenceConfig(
      supportDirectory: p.join(dir.path, 'support'),
      cacheDirectory: p.join(dir.path, 'caches'),
      hostFactory: hostFactory,
    );
  }

  /// Engine crash forensics live in `<support>/engine`.
  final String supportDirectory;

  /// Persisted KV prefixes live in `<caches>/kv` (the OS may purge them;
  /// they only save a prefill).
  final String cacheDirectory;
  final EngineHostFactory hostFactory;

  /// Null = the platform default: iOS pauses, persists and unloads in the
  /// background (no GPU work, jetsam); Android keeps generating and
  /// persists the prefix (foreground service); elsewhere nothing.
  final BackgroundPolicy? backgroundPolicy;

  /// Null = on Android only: phase changes go to `setProcessStateSummary`
  /// so the next launch can tell an LMK kill during a load from a crash.
  final bool? recordProcessState;

  /// Start the engine [startDelay] after the first frame. Off: it starts on
  /// first use (a chat or the picker resolving the local provider).
  final bool autoStart;
  final Duration startDelay;

  /// Forward app pause/resume to the lifecycle manager.
  final bool observeAppLifecycle;
  final AutotunePolicy autotune;

  /// Base session parameters for every library model (tests pin threads).
  final SessionConfig sessionDefaults;

  /// The largest context any library model asks for.
  final int maxContext;
  final String appVersion;

  BackgroundPolicy get effectiveBackgroundPolicy =>
      backgroundPolicy ??
      (Platform.isIOS
          ? BackgroundPolicy.pauseAndPersist
          : Platform.isAndroid
              ? BackgroundPolicy.persistOnly
              : BackgroundPolicy.none);
}

/// On-device inference for the app: owns the engine host, crash
/// forensics, the [ModelLifecycleManager], the [LlamaCppProvider] and
/// first-use autotune, and keeps the lifecycle's registrations in sync with
/// the [ModelLibrary].
///
/// * **Lazy.** Constructing it does no IO. [start] (idempotent, never
///   throws) runs on first use or [scheduleStart]'s post-first-frame timer,
///   so the engine never delays app launch.
/// * **Graceful.** A missing engine library or a host that fails to start
///   ends in [LocalEngineState.unavailable] with a reason; [provider] then
///   fails requests with `ProviderException(unsupported)` and the UI shows
///   local models as unavailable.
/// * **Library sync.** Every runnable GGUF in the library is registered as
///   a [LocalModelSpec] (verified SHA-256 as identity, paired projector,
///   context default); removed or broken models are unregistered (and
///   unloaded when warm).
/// * **Crash report.** The report `lifecycle.start()` returns stays in
///   [status] until [acknowledgeCrashReport], and is delivered once to the
///   next local reply as a `ProviderNotice` ([kEngineCrashNoticeCode]).
/// * **App lifecycle.** Pause/resume go to `onAppBackground` /
///   `onAppForeground`; backgrounding also cancels a running autotune.
final class LocalInference {
  LocalInference({
    required this.library,
    required this.layout,
    required KeyValueStore store,
    required this.config,
    MemoryMonitor? memory,
    DeviceProfileSource? device,
    Clock clock = const SystemClock(),
  })  : _store = store,
        _memory = memory,
        _device = device,
        _clock = clock,
        _prefix = PrefixCacheStore(directory: Directory(p.join(config.cacheDirectory, 'kv')), clock: clock);

  final ModelLibrary library;
  final ModelStorageLayout layout;
  final LocalInferenceConfig config;
  final KeyValueStore _store;
  final MemoryMonitor? _memory;
  final DeviceProfileSource? _device;
  final Clock _clock;
  final PrefixCacheStore _prefix;

  /// The built-in local provider (stable across engine states).
  late final LocalModelProvider provider = LocalModelProvider(this);

  final StreamController<LocalEngineStatus> _statusChanges = StreamController.broadcast();
  final StreamController<void> _modelChanges = StreamController.broadcast();
  LocalEngineStatus _status = LocalEngineStatus.idle;
  Future<LocalEngineStatus>? _starting;
  Timer? _startTimer;
  bool _startScheduled = false;
  AppLifecycleListener? _appLifecycle;
  bool _backgrounded = false;
  bool _disposed = false;

  EngineHost? _host;
  ModelLifecycleManager? _lifecycle;
  LlamaCppProvider? _engine;
  AutotuneScheduler? _autotune;
  EngineCrashReport? _crashForChat;
  StreamSubscription<List<LibraryModel>>? _librarySub;
  StreamSubscription<EngineHostEvent>? _hostSub;
  StreamSubscription<EngineProcessCrash>? _crashSub;

  /// Context caps recorded after live engine crashes, by model id.
  final Map<String, int> _caps = {};

  /// The last busy phase the lifecycle entered, and when it went idle.
  PhaseRecord? _lastBusy;
  DateTime? _idleSince;

  LocalEngineStatus get status => _status;

  /// Every status change (broadcast).
  Stream<LocalEngineStatus> get statusChanges => _statusChanges.stream;

  /// The set of local models (or their names) changed.
  Stream<void> get modelChanges => _modelChanges.stream;

  EngineHost? get host => _host;

  ModelLifecycleManager? get lifecycle => _lifecycle;

  /// The llama.cpp provider, once the engine is ready.
  LlamaCppProvider? get engine => _engine;

  AutotuneScheduler? get autotune => _autotune;

  PrefixCacheStore get prefixCache => _prefix;

  /// The warm model's library id, if any.
  String? get loadedModelId => _lifecycle?.loaded?.spec.id;

  bool get isBackgrounded => _backgrounded;

  void _setStatus(LocalEngineStatus s) {
    _status = s;
    if (!_statusChanges.isClosed) _statusChanges.add(s);
  }

  // ---------------------------------------------------------------------------
  // Start

  /// Starts the engine [LocalInferenceConfig.startDelay] after the next
  /// frame (no-op when already started or scheduled).
  void scheduleStart() {
    if (_startScheduled || _starting != null || _disposed) return;
    _startScheduled = true;
    void arm() {
      if (_disposed || _starting != null) return;
      _startTimer = Timer(config.startDelay, () => unawaited(start()));
    }

    try {
      WidgetsBinding.instance.addPostFrameCallback((_) => arm());
    } on Object {
      arm(); // No binding (a plain Dart test): just wait the delay.
    }
  }

  /// Starts the engine once; later calls return the same result. Never
  /// throws: failures end in [LocalEngineState.unavailable].
  Future<LocalEngineStatus> start() => _starting ??= _start();

  Future<LocalEngineStatus> _start() async {
    _startTimer?.cancel();
    _setStatus(const LocalEngineStatus(state: LocalEngineState.starting));
    EngineHost? host;
    ModelLifecycleManager? lifecycle;
    try {
      final forensics = EngineForensics(Directory(p.join(config.supportDirectory, 'engine')));
      await forensics.directory.create(recursive: true);
      host = await config.hostFactory(crashBreadcrumbPath: forensics.engineBreadcrumbPath);
      final info = await host.start();
      final system = _systemInfo(await host.systemInfoJson());
      final device = await _deviceProfile();
      final cores = system?.performanceCores ?? 0;
      final autotuner = Autotuner(
        host: host,
        store: _store,
        clock: _clock,
        environment: AutotuneEnvironment(
          deviceId: device?.model ?? 'unknown ${device?.platform.name ?? Platform.operatingSystem}',
          osVersion: device?.osVersion ?? Platform.operatingSystemVersion,
          appVersion: config.appVersion,
          engineVersion: info.version,
          performanceCores: cores > 0 ? cores : math.max(1, Platform.numberOfProcessors ~/ 2),
        ),
      );
      lifecycle = ModelLifecycleManager(
        host: host,
        memory: _memory,
        device: device,
        forensics: forensics,
        store: _store,
        prefixCache: _prefix,
        autotuner: autotuner,
        backgroundPolicy: config.effectiveBackgroundPolicy,
        onPhase: _onPhase,
        clock: _clock,
      );
      await library.load();
      await _loadCaps(library.models);
      _syncSpecs(lifecycle, library.models, notify: false);
      // Registered first, so a crash downgrade knows the model's floor.
      final crash = await lifecycle.start();
      final engine = LlamaCppProvider(lifecycle: lifecycle, id: localProviderId, displayName: kLocalProviderName);
      final tuner = AutotuneScheduler(
        scheduler: engine.scheduler,
        policy: config.autotune,
        isTuned: (id) async => await autotuner.cached(id) != null,
        run: (id, cancel) async {
          final m = await (_memory?.sample() ?? Future.value(MemoryState.unknown));
          // Benching on battery saver measures the throttle, not the device.
          if (m.lowPowerMode) return false;
          return await lifecycle!.autotune(id, cancel: cancel) != null;
        },
      );
      if (_disposed) {
        await tuner.dispose();
        await lifecycle.dispose();
        await host.dispose();
        return _status;
      }
      _host = host;
      _lifecycle = lifecycle;
      _engine = engine;
      _autotune = tuner;
      _crashForChat = crash;
      _librarySub = library.changes.listen((models) => _syncSpecs(lifecycle!, models));
      _watchCrashes(host);
      _setStatus(LocalEngineStatus(
        state: LocalEngineState.ready,
        crashReport: crash,
        engineVersion: info.version,
        hostKind: info.hostKind,
      ));
      // Went to the background while starting.
      if (_backgrounded) unawaited(lifecycle.onAppBackground().catchError((Object _) {}));
      // The registrations may have changed during start.
      _syncSpecs(lifecycle, library.models);
    } on Object catch (e) {
      debugPrint('Local inference unavailable: ${e.runtimeType}');
      try {
        await lifecycle?.dispose();
        await host?.dispose();
      } on Object {
        // Already broken; nothing more to release.
      }
      if (!_disposed) _setStatus(LocalEngineStatus(state: LocalEngineState.unavailable, reason: unavailableReason(e)));
    }
    return _status;
  }

  /// The user-facing reason for a failed start.
  static String unavailableReason(Object e) => switch (e) {
        EngineUnavailableException(:final message) => message,
        EngineException(:final message) => 'the engine failed to start ($message)',
        _ => 'the engine failed to start (${e.runtimeType})',
      };

  static EngineSystemInfo? _systemInfo(String json) {
    try {
      return EngineSystemInfo.parse(json);
    } on Object {
      return null;
    }
  }

  Future<DeviceProfile?> _deviceProfile() async {
    try {
      return await _device?.current();
    } on Object {
      return null;
    }
  }

  void _onPhase(PhaseRecord r) {
    if (r.phase == InferencePhase.idle) {
      _idleSince = _clock.now();
    } else {
      _lastBusy = r;
      _idleSince = null;
    }
    if (config.recordProcessState ?? Platform.isAndroid) _recordPhase(r);
  }

  void _recordPhase(PhaseRecord r) {
    final phase = switch (r.phase) {
      InferencePhase.idle => ProcessPhase.idle,
      InferencePhase.loading => ProcessPhase.load,
      InferencePhase.generating || InferencePhase.benchmarking => ProcessPhase.decode,
      InferencePhase.restoringState => ProcessPhase.prefill,
      InferencePhase.savingState => ProcessPhase.unload,
    };
    final id = r.modelId;
    final summary = id == null
        ? ProcessStateSummary(phase: phase, contextTokens: r.nCtx, foreground: !_backgrounded)
        : ProcessStateSummary.forModel(phase: phase, modelId: id, contextTokens: r.nCtx, foreground: !_backgrounded);
    unawaited(ProcessStateRecorder.record(summary).then((_) {}, onError: (Object _) {}));
  }

  // ---------------------------------------------------------------------------
  // Live crashes

  static String _capKey(String modelId) => 'sherpa.app.context_cap.$modelId';

  Future<void> _loadCaps(List<LibraryModel> models) async {
    for (final m in models) {
      try {
        final cap = (await _store.read(_capKey(m.id)))?.optInt('maxContext');
        if (cap != null) _caps[m.id] = cap;
      } on Object {
        // No cap.
      }
    }
  }

  /// The context cap recorded for [modelId] after a live engine crash.
  int? contextCapFor(String modelId) => _caps[modelId];

  void _watchCrashes(EngineHost host) {
    if (host is ProcessEngineHost) {
      // The structured report: the service's own phase (context, model
      // tag), memory kill vs native crash, crash-loop give-up.
      _crashSub = host.crashes.listen((c) => unawaited(_onLiveCrash(
            servicePhase: c.phase,
            engineMessage: c.engineMessage,
            reason: c.reason,
            gaveUp: c.gaveUp,
          )));
    } else {
      // In-process hosts can't outlive a native crash (start() reports it
      // on the next launch); this covers hosts that restart a worker.
      _hostSub = host.events.listen((e) {
        if (e is EngineHostCrashed && e.nativeStateLost) {
          unawaited(_onLiveCrash(reason: e.reason, gaveUp: false));
        }
      });
    }
  }

  /// The engine died under a running app (Android's `:inference` process).
  /// The lifecycle only downgrades a crashed model's context in `start()`,
  /// so the app does it here: a crash or memory kill while loading or
  /// generating halves that model's context for future loads (persisted;
  /// applied by re-registering the model), and the report is shown like a
  /// start-up crash report. A crash loop makes the engine unavailable until
  /// [retryEngine].
  Future<void> _onLiveCrash({
    PhaseRecord? servicePhase,
    String? engineMessage,
    required String reason,
    required bool gaveUp,
  }) async {
    if (_disposed) return;
    final lifecycle = _lifecycle;
    // The service names the model by a tag (`sha256:<8 hex>`); the app's
    // own last busy phase names it by id. Use the app's when it is recent.
    final idle = _idleSince;
    final recent = idle == null || _clock.now().difference(idle) < const Duration(seconds: 15);
    final local = recent ? _lastBusy : null;
    final phase = servicePhase ?? local;
    final spec = lifecycle == null ? null : _specForCrash(lifecycle, servicePhase, local);
    final nCtx = phase?.nCtx ?? local?.nCtx;
    final busy = phase != null && (phase.phase == InferencePhase.loading || phase.phase == InferencePhase.generating);
    if (spec != null && nCtx != null && busy) {
      final cap = math.max(spec.minContext, (nCtx ~/ 2) ~/ 256 * 256);
      if (cap < spec.preferredContext) {
        _caps[spec.id] = cap;
        try {
          await _store.write(_capKey(spec.id), {'maxContext': cap, 'reason': reason, 'at': _clock.now().toUtc().toIso8601String()});
        } on Object {
          // Still applied for this run.
        }
        final m = library.byId(spec.id);
        if (m != null && lifecycle != null && isRunnableLocally(m)) lifecycle.register(_spec(m));
      }
    }
    final report = EngineCrashReport(
      phase: PhaseRecord(
        phase: phase?.phase ?? InferencePhase.idle,
        at: _clock.now(),
        modelId: spec?.id ?? phase?.modelId,
        modelName: spec?.displayName,
        nCtx: nCtx,
        kvLayout: phase?.kvLayout,
      ),
      engineMessage: engineMessage,
    );
    if (_disposed) return;
    _setStatus(gaveUp
        ? _status.copyWith(state: LocalEngineState.unavailable, reason: reason, crashReport: report, canRetry: true)
        : _status.copyWith(crashReport: report));
  }

  LocalModelSpec? _specForCrash(ModelLifecycleManager lifecycle, PhaseRecord? service, PhaseRecord? local) {
    final tag = service?.modelId;
    if (tag != null && tag.startsWith('sha256:')) {
      for (final s in lifecycle.models) {
        if (s.identity != null && s.identity!.startsWith(tag)) return s;
      }
    }
    final id = local?.modelId;
    return id == null ? null : lifecycle.spec(id);
  }

  /// Leaves the crash-loop state of the `:inference` process host.
  Future<LocalEngineStatus> retryEngine() async {
    final host = _host;
    if (host is! ProcessEngineHost || !_status.canRetry) return _status;
    try {
      await host.retry();
      _setStatus(_status.copyWith(state: LocalEngineState.ready, canRetry: false));
    } on Object catch (e) {
      _setStatus(_status.copyWith(reason: unavailableReason(e)));
    }
    return _status;
  }

  // ---------------------------------------------------------------------------
  // Library sync

  void _syncSpecs(ModelLifecycleManager lifecycle, List<LibraryModel> models, {bool notify = true}) {
    final wanted = {for (final m in models) if (isRunnableLocally(m)) m.id: m};
    for (final s in lifecycle.models) {
      if (wanted.containsKey(s.id)) continue;
      lifecycle.unregister(s.id);
      if (lifecycle.loaded?.spec.id == s.id) {
        unawaited(lifecycle.unload(reason: 'removed from the library').catchError((Object _) {}));
      }
    }
    for (final m in wanted.values) {
      lifecycle.register(_spec(m));
    }
    if (notify && !_modelChanges.isClosed) _modelChanges.add(null);
  }

  int _maxContextFor(String id) {
    final cap = _caps[id];
    return cap == null ? config.maxContext : math.min(cap, config.maxContext);
  }

  LocalModelSpec _spec(LibraryModel m) =>
      localModelSpec(m, layout, sessionDefaults: config.sessionDefaults, maxContext: _maxContextFor(m.id));

  /// Library models the engine can run, with what is known about them.
  Future<List<ModelDescriptor>> listModels() async {
    await library.load();
    final loaded = _lifecycle?.loaded;
    return [
      for (final m in library.models)
        if (isRunnableLocally(m)) localModelDescriptor(m, loaded: loaded, maxContext: _maxContextFor(m.id)),
    ];
  }

  // ---------------------------------------------------------------------------
  // Crash report

  /// The user saw the crash report; stop showing it.
  void acknowledgeCrashReport() {
    if (_status.crashReport == null) return;
    _setStatus(_status.withoutCrashReport());
  }

  /// The crash report's sentence for the next local reply, once.
  String? takeCrashNotice() {
    final c = _crashForChat;
    _crashForChat = null;
    return c?.description;
  }

  // ---------------------------------------------------------------------------
  // App lifecycle

  /// Forwards app pause/resume (idempotent).
  void attachAppLifecycle() {
    if (_appLifecycle != null || _disposed) return;
    try {
      _appLifecycle = AppLifecycleListener(
        onPause: () => unawaited(onAppBackground()),
        onResume: onAppForeground,
      );
    } on Object {
      // No widgets binding (plain Dart tests).
    }
  }

  /// The app went to the background: stop background tuning, then apply
  /// the [BackgroundPolicy].
  Future<void> onAppBackground() async {
    _backgrounded = true;
    _autotune?.cancel('app in background');
    try {
      await _lifecycle?.onAppBackground();
    } on Object catch (e) {
      debugPrint('Local inference: background handling failed (${e.runtimeType})');
    }
  }

  void onAppForeground() {
    _backgrounded = false;
    _lifecycle?.onAppForeground();
  }

  // ---------------------------------------------------------------------------
  // Data

  /// A chat was deleted: drop its saved KV prefix (it holds the
  /// conversation's tokens).
  Future<void> forgetConversation(String sessionId) async {
    try {
      await _prefix.invalidateSession(sessionId);
    } on Object {
      // Best effort; the LRU budget evicts it eventually.
    }
  }

  /// "Delete all data": unload, then delete every saved KV prefix and the
  /// engine's notes (autotune profiles, crash downgrades).
  Future<void> eraseAll() async {
    _autotune?.cancel('data erased');
    try {
      await _lifecycle?.unload(reason: 'data erased');
    } on Object {
      // The files go regardless.
    }
    await _prefix.clear();
    final store = _store;
    if (store is RecordKeyValueStore) await store.clear();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _startTimer?.cancel();
    _appLifecycle?.dispose();
    _appLifecycle = null;
    await _librarySub?.cancel();
    await _hostSub?.cancel();
    await _crashSub?.cancel();
    await _autotune?.dispose();
    try {
      await _lifecycle?.dispose();
      await _engine?.scheduler.dispose();
      await _host?.dispose();
    } on Object {
      // Shutting down.
    }
    await _statusChanges.close();
    await _modelChanges.close();
  }
}
