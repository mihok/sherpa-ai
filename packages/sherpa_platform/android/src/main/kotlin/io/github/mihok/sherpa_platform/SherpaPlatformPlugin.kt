package io.github.mihok.sherpa_platform

import android.Manifest
import android.app.ActivityManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.PluginRegistry

/**
 * Entry point. Reads run on Pigeon's background TaskQueue (see
 * pigeons/platform_api.dart); lease calls run on the main thread because
 * services and notifications are main-thread APIs.
 *
 * Activity-aware only for the POST_NOTIFICATIONS request (API 33+), which
 * needs an activity for the system dialog and its result callback.
 */
class SherpaPlatformPlugin :
  FlutterPlugin, ActivityAware, PluginRegistry.RequestPermissionsResultListener, SherpaPlatformHostApi {
  private lateinit var context: Context
  private lateinit var memory: MemoryReader
  private lateinit var device: DeviceReader
  private var hub: SignalHub? = null
  private var activity: ActivityPluginBinding? = null

  /** Callers waiting for the one permission dialog in flight. */
  private val permissionWaiters = mutableListOf<(Result<Boolean>) -> Unit>()

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

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    activity = binding
    binding.addRequestPermissionsResultListener(this)
  }

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

  override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

  override fun onDetachedFromActivity() {
    activity?.removeRequestPermissionsResultListener(this)
    activity = null
    // A dialog whose activity went away never reports back: answer now.
    resolvePermission()
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

  /**
   * The system dialog for POST_NOTIFICATIONS (API 33+). After two denials
   * Android stops showing it and reports a denial at once; the app then
   * points people to system settings instead.
   */
  override fun requestNotificationsPermission(callback: (Result<Boolean>) -> Unit) {
    val granted = Build.VERSION.SDK_INT < 33 ||
      context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
    val host = activity?.activity
    if (granted || host == null) {
      callback(Result.success(RunService.notificationsPermitted(context)))
      return
    }
    permissionWaiters.add(callback)
    if (permissionWaiters.size > 1) return // the dialog is already up
    try {
      host.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), PERMISSION_REQUEST_CODE)
    } catch (e: RuntimeException) {
      resolvePermission()
    }
  }

  override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
    if (requestCode != PERMISSION_REQUEST_CODE) return false
    resolvePermission()
    return true
  }

  private fun resolvePermission() {
    if (permissionWaiters.isEmpty()) return
    val permitted = RunService.notificationsPermitted(context)
    val waiting = permissionWaiters.toList()
    permissionWaiters.clear()
    for (cb in waiting) cb(Result.success(permitted))
  }

  override fun notifyRunFinished(notice: FinishedNotice): Boolean = RunService.notifyFinished(context, notice)

  override fun clearFinishedNotices() = RunService.clearFinished(context)

  override fun beginLease(request: LeaseRequest, callback: (Result<LeaseResult>) -> Unit) =
    RunService.begin(context, request, callback)

  override fun updateLease(id: String, progress: Double?, text: String?) = RunService.update(id, progress, text)

  override fun endLease(id: String) = RunService.end(id)

  private companion object {
    const val MAX_SUMMARY_BYTES = 128

    /** Any 16-bit value; only this plugin's request reads it. */
    const val PERMISSION_REQUEST_CODE = 0x5e7a
  }
}
