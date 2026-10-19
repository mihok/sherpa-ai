package io.github.mihok.sherpa_platform

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import kotlin.math.roundToInt

/** One background lease; main thread only. */
internal class Lease(val id: String, var title: String, var text: String, val long: Boolean) {
  var progress: Double? = null
}

/**
 * Foreground service that keeps the main process (and its Dart isolate)
 * running while an agent reply or run finishes after the user leaves.
 *
 * Why these types (R07 §4.1, PLAN §7.2):
 * - `shortService` (API 34) to finish the current reply: no type permission,
 *   ~3 minutes, then `onTimeout` and we must stop within seconds.
 * - `specialUse` for long, user-started agent runs; the subtype property in
 *   the manifest is what Play reviews. `dataSync`/`mediaProcessing` would
 *   misdescribe inference and have a 6 h / 24 h budget.
 * Once a run needs `specialUse`, the service stays `specialUse` until every
 * lease ends: switching back to `shortService` mid-flight is not needed and
 * its rules are not worth the risk. The service lives in the main process on
 * purpose: it exists to keep the Dart agent loop alive.
 *
 * It must be started while the activity is visible (R07 §4.2); from the
 * background `startForegroundService` throws and the lease is refused.
 * Every state change happens on the main thread.
 */
class RunService : Service() {
  /** Sticky for the service's lifetime once a long lease was seen. */
  private var specialUse = false

  override fun onBind(intent: Intent?): IBinder? = null

  override fun onCreate() {
    super.onCreate()
    instance = this
  }

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    // A start can reach an instance we had already asked to stop.
    instance = this
    // startForeground must follow startForegroundService even when the
    // lease was ended in the meantime, or the system raises
    // ForegroundServiceDidNotStartInTimeException.
    val error = promote()
    resolvePending(error)
    if (error != null || leases.isEmpty()) stopNow()
    // Not sticky: after process death the Dart state that owned the run is
    // gone, so a restarted service would have nothing to keep alive.
    return START_NOT_STICKY
  }

  /** shortService ran out (API 34). Must stop within a few seconds. */
  override fun onTimeout(startId: Int) = expireAll("timeout")

  /** API 35 variant carrying the FGS type that timed out. */
  override fun onTimeout(startId: Int, fgsType: Int) = expireAll("timeout(type=$fgsType)")

  override fun onDestroy() {
    // Only an instance that is still current was stopped by the system (or
    // the user via the FGS task manager). One we stopped ourselves must not
    // touch the shared lease maps: they may already belong to a new start.
    if (instance === this) {
      instance = null
      if (leases.isNotEmpty()) expireAll("service destroyed", stop = false)
      resolvePending("service destroyed before it started")
    }
    super.onDestroy()
  }

  /** (Re)applies the foreground state for the current leases; returns an error or null. */
  internal fun promote(): String? {
    val long = specialUse || leases.values.any { it.long }
    return try {
      if (Build.VERSION.SDK_INT >= 34) {
        val type = if (long) ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE else ServiceInfo.FOREGROUND_SERVICE_TYPE_SHORT_SERVICE
        startForeground(NOTIFICATION_ID, buildNotification(this), type)
      } else {
        // shortService/specialUse are API 34 types; 29–33 accept the
        // manifest declaration (unknown bits are ignored) and impose no
        // timeout.
        startForeground(NOTIFICATION_ID, buildNotification(this))
      }
      specialUse = long
      null
    } catch (e: Exception) {
      // ForegroundServiceStartNotAllowedException (31+), SecurityException,
      // InvalidForegroundServiceTypeException (34+).
      "${e.javaClass.simpleName}: ${e.message}"
    }
  }

  internal fun mode(): LeaseMode =
    if (specialUse) LeaseMode.ANDROID_SPECIAL_USE else LeaseMode.ANDROID_SHORT_SERVICE

  internal fun refreshNotification() {
    if (leases.isEmpty()) return
    getSystemService(NotificationManager::class.java)?.notify(NOTIFICATION_ID, buildNotification(this))
  }

  private fun expireAll(detail: String, stop: Boolean = true) {
    val ids = leases.keys.toList()
    leases.clear()
    for (id in ids) SignalHub.broadcast(SignalKind.LEASE_EXPIRED, id, detail)
    if (stop) stopNow()
  }

  internal fun stopNow() {
    if (instance === this) instance = null
    stopForeground(STOP_FOREGROUND_REMOVE)
    stopSelf()
    specialUse = false
  }

  private fun resolvePending(error: String?) {
    val waiting = pending.toList()
    pending.clear()
    for ((id, cb) in waiting) {
      if (error != null) leases.remove(id)
      val granted = error == null && leases.containsKey(id)
      cb(Result.success(LeaseResult(
        id = id,
        mode = if (granted) mode() else LeaseMode.NONE,
        granted = granted,
        error = error ?: if (!granted) "ended before the service started" else null,
        notificationsVisible = notificationsPermitted(this),
      )))
    }
  }

  companion object {
    private const val NOTIFICATION_ID = 0x5e7a
    private const val CHANNEL_ID = "sherpa_background_runs"

    /** Finished-run notices: one per tag (chat), on their own channel. */
    private const val FINISHED_ID = 0x5e7b
    private const val FINISHED_CHANNEL_ID = "sherpa_finished_runs"
    private const val START_TIMEOUT_MS = 8000L

    private val main = Handler(Looper.getMainLooper())
    internal var instance: RunService? = null
    internal val leases = LinkedHashMap<String, Lease>()
    private val pending = LinkedHashMap<String, (Result<LeaseResult>) -> Unit>()
    private var channelName = "Background runs"
    private var smallIcon: String? = null

    /** Main thread. */
    fun begin(context: Context, request: LeaseRequest, callback: (Result<LeaseResult>) -> Unit) {
      request.androidChannelName?.let { channelName = it }
      request.androidSmallIcon?.let { smallIcon = it }
      ensureChannel(context)
      leases[request.id] = Lease(request.id, request.title, request.reason, request.long)
      val running = instance
      if (running != null) {
        val error = running.promote()
        if (error != null) leases.remove(request.id)
        callback(Result.success(result(context, request.id, error, running.mode())))
        return
      }
      pending[request.id] = callback
      try {
        context.startForegroundService(Intent(context, RunService::class.java))
      } catch (e: Exception) {
        // ForegroundServiceStartNotAllowedException (31+) / IllegalStateException:
        // the app is not in a state that may start a foreground service.
        leases.remove(request.id)
        pending.remove(request.id)
        callback(Result.success(result(context, request.id, "${e.javaClass.simpleName}: ${e.message}", LeaseMode.NONE)))
        return
      }
      main.postDelayed({
        pending.remove(request.id)?.let { cb ->
          leases.remove(request.id)
          cb(Result.success(result(context, request.id, "service did not start", LeaseMode.NONE)))
        }
      }, START_TIMEOUT_MS)
    }

    fun update(id: String, progress: Double?, text: String?) {
      val lease = leases[id] ?: return
      lease.progress = progress?.coerceIn(0.0, 1.0)
      text?.let { lease.text = it }
      instance?.refreshNotification()
    }

    fun end(id: String) {
      if (leases.remove(id) == null) return
      val running = instance ?: return
      if (leases.isEmpty()) running.stopNow() else running.refreshNotification()
    }

    /**
     * Posts a dismissible "reply ready" notice that opens the app; false
     * when notifications are not permitted. DEFAULT importance (unlike the
     * silent ongoing channel): the person left and asked to be told.
     */
    fun notifyFinished(context: Context, notice: FinishedNotice): Boolean {
      if (!notificationsPermitted(context)) return false
      val nm = context.getSystemService(NotificationManager::class.java) ?: return false
      nm.createNotificationChannel(NotificationChannel(
        FINISHED_CHANNEL_ID,
        notice.androidChannelName ?: "Finished replies",
        NotificationManager.IMPORTANCE_DEFAULT,
      ))
      val b = Notification.Builder(context, FINISHED_CHANNEL_ID)
        .setSmallIcon(iconId(context))
        .setContentTitle(notice.title)
        .setContentText(notice.text)
        .setAutoCancel(true)
        .setCategory(Notification.CATEGORY_STATUS)
        .setPublicVersion(publicVersion(context, FINISHED_CHANNEL_ID))
      launchIntent(context)?.let { b.setContentIntent(it) }
      return try {
        nm.notify(notice.tag, FINISHED_ID, b.build())
        true
      } catch (e: SecurityException) {
        false
      }
    }

    fun clearFinished(context: Context) {
      val nm = context.getSystemService(NotificationManager::class.java) ?: return
      for (n in nm.activeNotifications) {
        if (n.id == FINISHED_ID) nm.cancel(n.tag, n.id)
      }
    }

    fun notificationsPermitted(context: Context): Boolean {
      val nm = context.getSystemService(NotificationManager::class.java) ?: return false
      if (!nm.areNotificationsEnabled()) return false
      return Build.VERSION.SDK_INT < 33 ||
        context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) ==
        android.content.pm.PackageManager.PERMISSION_GRANTED
    }

    private fun result(context: Context, id: String, error: String?, mode: LeaseMode) = LeaseResult(
      id = id,
      mode = if (error == null) mode else LeaseMode.NONE,
      granted = error == null,
      error = error,
      notificationsVisible = notificationsPermitted(context),
    )

    private fun ensureChannel(context: Context) {
      val nm = context.getSystemService(NotificationManager::class.java) ?: return
      // LOW: no sound or heads-up for a status the user started; still above
      // MIN, which Live Updates require (R07 §8.1).
      nm.createNotificationChannel(NotificationChannel(CHANNEL_ID, channelName, NotificationManager.IMPORTANCE_LOW))
    }

    private fun buildNotification(context: Context): Notification {
      // Show the newest lease; long runs win over reply-finishing.
      val lease = leases.values.lastOrNull { it.long } ?: leases.values.lastOrNull()
      val b = Notification.Builder(context, CHANNEL_ID)
        .setSmallIcon(iconId(context))
        .setContentTitle(lease?.title ?: "Finishing up")
        .setContentText(lease?.text ?: "")
        .setOngoing(true)
        .setOnlyAlertOnce(true)
        .setCategory(Notification.CATEGORY_PROGRESS)
      if (Build.VERSION.SDK_INT >= 31) {
        // Android 12+ may defer an FGS notification by up to 10 s. The app
        // begins a lease with every reply (it must, while visible), so most
        // leases end within seconds with the user still in the app: the
        // deferral keeps those from flashing a notification, and one that
        // outlives it appears soon after the user leaves.
        b.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_DEFERRED)
      }
      launchIntent(context)?.let { b.setContentIntent(it) }
      // The title names the chat, which people may not want on the lock
      // screen: when they hide sensitive content, it shows only the app.
      b.setPublicVersion(publicVersion(context, CHANNEL_ID))
      val p = lease?.progress
      if (lease != null && (p != null || lease.long)) {
        val pct = ((p ?: 0.0) * 100).roundToInt().coerceIn(0, 100)
        if (Build.VERSION.SDK_INT >= 36) {
          // ProgressStyle (API 36) is the Live Updates style (R07 §8.1); we do
          // not request promotion (POST_PROMOTED_NOTIFICATIONS, 36.1).
          val style = Notification.ProgressStyle()
            .setProgressSegments(listOf(Notification.ProgressStyle.Segment(100)))
          if (p == null) style.setProgressIndeterminate(true) else style.setProgress(pct)
          b.setStyle(style)
        } else {
          b.setProgress(100, pct, p == null)
        }
      }
      return b.build()
    }

    private fun launchIntent(context: Context): PendingIntent? =
      context.packageManager.getLaunchIntentForPackage(context.packageName)?.let {
        PendingIntent.getActivity(context, 0, it, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
      }

    /** What a locked screen that hides sensitive content shows: the app's name. */
    private fun publicVersion(context: Context, channel: String): Notification =
      Notification.Builder(context, channel)
        .setSmallIcon(iconId(context))
        .setContentTitle(context.applicationInfo.loadLabel(context.packageManager))
        .build()

    private fun iconId(context: Context): Int {
      smallIcon?.let { name ->
        // getIdentifier: the icon name comes from Dart at runtime.
        @Suppress("DiscouragedApi")
        val id = context.resources.getIdentifier(name, "drawable", context.packageName)
        if (id != 0) return id
      }
      val app = context.applicationInfo.icon
      return if (app != 0) app else android.R.drawable.ic_popup_sync
    }
  }
}
