package io.github.mihok.sherpa_platform

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin

/**
 * Entry point. Reads run on Pigeon's background TaskQueue (see
 * pigeons/platform_api.dart); lease calls run on the main thread because
 * services and notifications are main-thread APIs.
 */
class SherpaPlatformPlugin : FlutterPlugin, SherpaPlatformHostApi {
  private lateinit var context: Context
  private lateinit var memory: MemoryReader
  private lateinit var device: DeviceReader
  private var hub: SignalHub? = null

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    memory = MemoryReader(context)
    device = DeviceReader(context, memory)
    SherpaPlatformHostApi.setUp(binding.binaryMessenger, this)
    hub = SignalHub(context, memory).also { SignalsStreamHandler.register(binding.binaryMessenger, it) }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    SherpaPlatformHostApi.setUp(binding.binaryMessenger, null)
    hub?.onCancel(null)
    hub = null
  }

  override fun sampleMemory(): MemorySample = memory.sample()

  override fun deviceInfo(): DeviceInfo = device.read()

  /**
   * Read back after a kill via `ApplicationExitInfo.getProcessStateSummary`
   * (R07 §2.4). "Maximum length is 128 bytes"; longer input throws, so we
   * cut at a UTF-8 boundary. Calls may be throttled by the system.
   */
  override fun setProcessStateSummary(summary: ByteArray): Boolean {
    if (Build.VERSION.SDK_INT < 30) return false
    return try {
      val am = context.getSystemService(ActivityManager::class.java) ?: return false
      am.setProcessStateSummary(Utf8.truncate(summary, MAX_SUMMARY_BYTES))
      true
    } catch (_: RuntimeException) {
      false
    }
  }

  /**
   * No-op: on Android the app's `dataExtractionRules` (API 31+) and
   * `fullBackupContent` (≤ 30) XML exclude the database, which also covers
   * device-to-device transfer, which a per-file flag could not.
   */
  override fun excludeFromBackup(path: String, includeSqliteSidecars: Boolean): List<String> = emptyList()

  override fun notificationsPermitted(): Boolean = RunService.notificationsPermitted(context)

  override fun beginLease(request: LeaseRequest, callback: (Result<LeaseResult>) -> Unit) =
    RunService.begin(context, request, callback)

  override fun updateLease(id: String, progress: Double?, text: String?) = RunService.update(id, progress, text)

  override fun endLease(id: String) = RunService.end(id)

  private companion object {
    const val MAX_SUMMARY_BYTES = 128
  }
}
