package io.github.mihok.sherpa_inference

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Build
import android.os.DeadObjectException
import android.os.IBinder
import android.os.RemoteException
import android.os.TransactionTooLargeException
import android.util.Log
import androidx.annotation.RequiresApi
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

/**
 * Main-process side of the `:inference` service: binding, the oneway pipe, death detection and exit records.
 * Mechanism only — when to reconnect, how to back off and what a crash means is decided by the Dart
 * ProcessEngineHost from the [HostStatus] messages posted here.
 *
 * Threads: binding, ServiceConnection callbacks (via the Executor overload of bindService), death handling
 * and exit-record polling run on one IPC thread; [send] runs on Pigeon's background TaskQueue; the platform
 * main thread only posts. Nothing here blocks for longer than a oneway transaction.
 *
 * ## Bind flags ([BindPolicy], API 29–37)
 * * Base binding `BIND_AUTO_CREATE | BIND_NOT_PERCEPTIBLE` (adaptive): the service exists while bound; with
 *   the UI in front an idle engine sits just below perceptible (PERCEPTIBLE_LOW), so under pressure the
 *   system may reclaim it before perceptible work — the lifecycle reloads it on next use and the prefix
 *   cache restores the conversation.
 * * While work is in flight (Dart `setBusy(true)`): a second binding `BIND_AUTO_CREATE | BIND_IMPORTANT`
 *   raises the process to its client's level — foreground with top-app CPU scheduling (prime/big cores)
 *   while the UI is visible, and the importance of sherpa_platform's BackgroundRunGuard foreground service
 *   while it runs in the background, so a generation keeps running exactly as long as the app is allowed to.
 * * Not used: BIND_ABOVE_CLIENT (would rank the engine above the UI), BIND_INCLUDE_CAPABILITIES (the engine
 *   needs no while-in-use location/camera/mic or network capability), BIND_WAIVE_PRIORITY /
 *   BIND_ALLOW_OOM_MANAGEMENT (would let a running generation be killed), starting the service (a started
 *   service outlives the app's need for it). Without any binding the service is destroyed, frees its models
 *   and the empty process is reclaimed: nothing keeps it alive while idle.
 */
class InferenceClient(private val context: Context, private val post: (InferenceMessage) -> Unit) {
  private val ipc: ScheduledExecutorService =
    Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "sherpa-inference-ipc").apply { isDaemon = true } }
  private val nextId = AtomicLong()

  @Volatile private var live: Connection? = null

  private val intent: Intent get() = Intent(context, InferenceService::class.java)

  inner class Connection(val id: Long, val policy: BindPolicy) : ServiceConnection {
    // Read from Binder threads (receive, send) and written on the IPC thread.
    @Volatile var session: IInferenceSession? = null
    @Volatile var pid = 0
    var bound = false
    @Volatile var dead = false
    @Volatile var closed = false
    var busy: ServiceConnection? = null

    val client = object : IInferenceClient.Stub() {
      override fun receive(message: Blob) {
        if (closed || dead) {
          message.close()
          return
        }
        val m = try {
          Wire.decodeMessage(message.bytes())
        } catch (t: Throwable) {
          Log.e(TAG, "undecodable message from :inference", t)
          return
        }
        post(m)
      }
    }

    val death = IBinder.DeathRecipient { ipc.execute { died(this, "the inference process died") } }

    override fun onServiceConnected(name: ComponentName, binder: IBinder) {
      if (closed || dead || session != null) return
      try {
        val s = IInferenceService.Stub.asInterface(binder).attach(client, Wire.PROTOCOL_VERSION)
        s.asBinder().linkToDeath(death, 0)
        pid = s.pid()
        session = s
        post(HostStatus(HostStatusKind.CONNECTED, id, pid.toLong()))
      } catch (e: RemoteException) {
        died(this, "the inference process died while attaching ($e)")
      } catch (e: RuntimeException) {
        bindFailed(this, "attach failed: $e")
      }
    }

    override fun onServiceDisconnected(name: ComponentName) = died(this, "the inference service disconnected")

    override fun onBindingDied(name: ComponentName) = died(this, "the inference binding died")

    override fun onNullBinding(name: ComponentName) = bindFailed(this, "the inference service returned no binder")
  }

  /** A fresh connection (any previous one is torn down first, e.g. after a Dart hot restart). */
  fun connect(policy: BindPolicy): Long {
    val c = Connection(nextId.incrementAndGet(), policy)
    val old = live
    live = c
    ipc.execute {
      old?.let(::teardown)
      bind(c)
    }
    return c.id
  }

  private fun bind(c: Connection) {
    if (c.closed) return
    val ok = try {
      context.bindService(intent, baseFlags(c.policy), ipc, c)
    } catch (e: SecurityException) {
      bindFailed(c, "bindService refused: $e")
      return
    }
    c.bound = true
    if (!ok) {
      bindFailed(c, "bindService returned false (is InferenceService in the merged manifest?)")
      return
    }
    ipc.schedule({ if (c.session == null && !c.dead && !c.closed) bindFailed(c, "the inference service did not connect within ${BIND_TIMEOUT_S}s") }, BIND_TIMEOUT_S, TimeUnit.SECONDS)
  }

  /** One oneway transaction; throws [SherpaInferenceError] when [connection] is not live. */
  fun send(connection: Long, requestId: Long, call: EngineCall) {
    val c = live
    val s = c?.session
    if (c == null || c.id != connection || c.dead || c.closed || s == null) {
      throw SherpaInferenceError("not_connected", "the inference service is not connected", null)
    }
    val blob = Blob.of(Wire.encodeCall(requestId, call))
    try {
      s.send(blob)
    } catch (e: DeadObjectException) {
      throw SherpaInferenceError("not_connected", "the inference process died", null)
    } catch (e: TransactionTooLargeException) {
      throw SherpaInferenceError("transport", "Binder buffer full: $e", null)
    } catch (e: RemoteException) {
      throw SherpaInferenceError("transport", e.toString(), null)
    } finally {
      blob.close()
    }
  }

  fun setBusy(connection: Long, busy: Boolean) {
    ipc.execute {
      val c = live
      if (c == null || c.id != connection || c.dead || c.closed) return@execute
      if (busy && c.busy == null) {
        val b = object : ServiceConnection {
          override fun onServiceConnected(name: ComponentName, service: IBinder) {}

          override fun onServiceDisconnected(name: ComponentName) {}
        }
        try {
          if (context.bindService(intent, busyFlags(c.policy), ipc, b)) c.busy = b else unbindQuietly(b)
        } catch (e: SecurityException) {
          Log.w(TAG, "busy binding refused", e)
        }
      } else if (!busy) {
        c.busy?.let(::unbindQuietly)
        c.busy = null
      }
    }
  }

  fun disconnect(connection: Long) {
    ipc.execute {
      val c = live
      if (c == null || c.id != connection) return@execute
      live = null
      teardown(c)
    }
  }

  /** Plugin detached: drop everything. */
  fun close() {
    val c = live
    live = null
    ipc.execute {
      c?.let(::teardown)
      ipc.shutdown()
    }
  }

  private fun teardown(c: Connection) {
    if (c.closed) return
    c.closed = true
    try {
      c.session?.asBinder()?.unlinkToDeath(c.death, 0)
      c.session?.close()
    } catch (_: Exception) {
      // already dead
    }
    unbindAll(c)
  }

  private fun unbindAll(c: Connection) {
    c.busy?.let(::unbindQuietly)
    c.busy = null
    if (c.bound) unbindQuietly(c)
    c.bound = false
  }

  private fun unbindQuietly(conn: ServiceConnection) {
    try {
      context.unbindService(conn)
    } catch (_: IllegalArgumentException) {
      // not bound
    }
  }

  private fun bindFailed(c: Connection, why: String) {
    if (c.closed || c.dead) return
    c.closed = true
    unbindAll(c)
    if (live === c) live = null
    post(HostStatus(HostStatusKind.BIND_FAILED, c.id, detail = why))
  }

  /**
   * Death: report at once (Dart fails everything in flight), unbind so the system does not restart the
   * service on its own schedule (Dart's backoff decides), then look for the exit record.
   */
  private fun died(c: Connection, why: String) {
    if (c.dead || c.closed) return
    c.dead = true
    unbindAll(c)
    if (live === c) live = null
    post(HostStatus(HostStatusKind.DISCONNECTED, c.id, c.pid.toLong(), why))
    lookupExit(c, 0)
  }

  /**
   * system_server records the ApplicationExitInfo while it processes the death, which can land shortly after
   * our binder death notice: poll for up to [EXIT_LOOKUP_MS].
   */
  private fun lookupExit(c: Connection, attempt: Int) {
    val found = if (c.pid > 0) ExitInfoReader.find(context, c.pid) else null
    if (found != null || (attempt + 1) * EXIT_POLL_MS >= EXIT_LOOKUP_MS) {
      post(HostStatus(HostStatusKind.EXIT_INFO, c.id, c.pid.toLong(), exit = found))
    } else {
      ipc.schedule({ lookupExit(c, attempt + 1) }, EXIT_POLL_MS, TimeUnit.MILLISECONDS)
    }
  }

  companion object {
    private const val TAG = "SherpaInference"
    private const val BIND_TIMEOUT_S = 15L
    private const val EXIT_POLL_MS = 100L
    private const val EXIT_LOOKUP_MS = 2000L

    fun baseFlags(policy: BindPolicy): Int = when (policy) {
      BindPolicy.ADAPTIVE -> Context.BIND_AUTO_CREATE or Context.BIND_NOT_PERCEPTIBLE
      BindPolicy.INHERIT -> Context.BIND_AUTO_CREATE
      BindPolicy.IMPORTANT -> Context.BIND_AUTO_CREATE or Context.BIND_IMPORTANT
    }

    fun busyFlags(@Suppress("UNUSED_PARAMETER") policy: BindPolicy): Int = Context.BIND_AUTO_CREATE or Context.BIND_IMPORTANT
  }
}

/** The exit record of a dead `:inference` process (API 30+). */
object ExitInfoReader {
  fun find(context: Context, pid: Int): ProcessExitMsg? {
    if (Build.VERSION.SDK_INT < 30) return null
    val am = context.getSystemService(ActivityManager::class.java) ?: return null
    val list = try {
      am.getHistoricalProcessExitReasons(context.packageName, pid, 4)
    } catch (e: RuntimeException) {
      return null
    }
    val suffix = InferenceService.PROCESS_SUFFIX
    val info = list.firstOrNull { it.pid == pid && it.processName.endsWith(suffix) } ?: return null
    return toMessage(info, ActivityManager.isLowMemoryKillReportSupported())
  }

  @RequiresApi(30)
  private fun toMessage(info: ApplicationExitInfo, lmk: Boolean): ProcessExitMsg {
    val tombstone = if (info.reason == ApplicationExitInfo.REASON_CRASH_NATIVE && Build.VERSION.SDK_INT >= 31) {
      try {
        info.traceInputStream?.use { s ->
          val bytes = s.readNBytesCompat(TombstoneExcerpt.MAX_INPUT)
          TombstoneExcerpt.from(bytes)
        }
      } catch (_: Exception) {
        null
      }
    } else {
      null
    }
    return ProcessExitMsg(
      pid = info.pid.toLong(),
      reason = info.reason.toLong(),
      reasonName = ExitDecoder.reasonName(info.reason),
      classification = ExitDecoder.classify(info.reason, info.status, info.description, lmk),
      status = info.status.toLong(),
      details = info.description,
      importance = info.importance.toLong(),
      pssBytes = info.pss * 1024,
      rssBytes = info.rss * 1024,
      timestampMs = info.timestamp,
      processStateSummary = info.processStateSummary,
      tombstone = tombstone,
    )
  }

  private fun java.io.InputStream.readNBytesCompat(max: Int): ByteArray {
    val out = java.io.ByteArrayOutputStream()
    val buf = ByteArray(64 * 1024)
    while (out.size() < max) {
      val n = read(buf, 0, minOf(buf.size, max - out.size()))
      if (n < 0) break
      out.write(buf, 0, n)
    }
    return out.toByteArray()
  }
}
