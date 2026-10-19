package io.github.mihok.sherpa_inference.engine

import java.security.SecureRandom
import java.util.ArrayDeque
import java.util.concurrent.Executor
import java.util.concurrent.SynchronousQueue
import java.util.concurrent.ThreadFactory
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * Runs tasks one at a time, in submission order, on a shared pool (one per session: the host contract's
 * "calls on one session are serialized in arrival order").
 */
class SerialExecutor(private val pool: Executor, private val onError: (Throwable) -> Unit = {}) : Executor {
  private val tasks = ArrayDeque<Runnable>()
  private var active = false

  override fun execute(task: Runnable) {
    synchronized(this) {
      tasks.addLast(task)
      if (active) return
      active = true
    }
    pool.execute(::drain)
  }

  private fun drain() {
    while (true) {
      val next = synchronized(this) {
        tasks.pollFirst() ?: run {
          active = false
          null
        }
      } ?: return
      try {
        next.run()
      } catch (t: Throwable) {
        onError(t)
      }
    }
  }
}

/** Unbounded cached pool of daemon threads (blocking engine calls: loads, bench, state I/O). */
fun enginePool(name: String): ThreadPoolExecutor {
  val n = AtomicInteger()
  val factory = ThreadFactory { r -> Thread(r, "$name-${n.incrementAndGet()}").apply { isDaemon = true } }
  return ThreadPoolExecutor(0, Int.MAX_VALUE, 30, TimeUnit.SECONDS, SynchronousQueue(), factory)
}

/**
 * Opaque ids for native pointers. Ids carry a random per-instance salt in their high bits, so an id from a
 * previous service instance (a stale handle that slipped past the Dart epoch check) never aliases a live
 * object here; unknown ids are SE_ERR_INVALID_ARG, never a dereference.
 *
 * Entries are reference counted by the calls using them: [retire] (free) of an entry that another thread is
 * using is deferred until that call returns, so a racing tokenize / free can never use a freed pointer
 * (the header forbids freeing "a handle another thread is using").
 */
class HandleTable<M>(private val kind: String, salt: Long = randomSalt()) {
  inner class Entry internal constructor(val id: Long, val ptr: Long, val meta: M) {
    internal var uses = 0
    internal var retired = false
    internal var free: ((Long) -> Unit)? = null
  }

  private val base = salt shl 32
  private val entries = HashMap<Long, Entry>()
  private var next = 1L

  fun add(ptr: Long, meta: M): Long = synchronized(this) {
    val id = base or (next++ and 0xFFFFFFFFL)
    entries[id] = Entry(id, ptr, meta)
    id
  }

  /** Runs [block] with the entry held; throws [EngineError] (SE_ERR_INVALID_ARG) for unknown ids. */
  fun <T> use(id: Long, block: (Entry) -> T): T {
    val e = synchronized(this) {
      val e = entries[id]
      if (e == null || e.retired) throw EngineError(EngineError.INVALID_ARG, "unknown or freed $kind handle #${id and 0xFFFFFFFFL}")
      e.uses++
      e
    }
    try {
      return block(e)
    } finally {
      release(e)
    }
  }

  private fun release(e: Entry) {
    val free = synchronized(this) {
      e.uses--
      if (e.retired && e.uses == 0) e.free.also { e.free = null } else null
    }
    free?.invoke(e.ptr)
  }

  /** Removes [id]; [free] runs now, or after the last running call using it. False when unknown. */
  fun retire(id: Long, free: (Long) -> Unit): Boolean {
    val freeNow: Long? = synchronized(this) {
      val e = entries.remove(id) ?: return false
      e.retired = true
      if (e.uses == 0) {
        e.ptr
      } else {
        e.free = free
        null
      }
    }
    if (freeNow != null) free(freeNow)
    return true
  }

  fun ids(): List<Long> = synchronized(this) { entries.keys.toList() }

  fun size(): Int = synchronized(this) { entries.size }

  companion object {
    fun randomSalt(): Long = (SecureRandom().nextInt(1 shl 20) + 1).toLong()
  }
}
