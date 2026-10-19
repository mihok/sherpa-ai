package io.github.mihok.sherpa_inference

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import java.util.ArrayDeque

/**
 * Main-process entry point of the Android process host (pigeons/inference_api.dart). Forwards Dart's
 * EngineCalls to InferenceService in `:inference` and pushes every reply, generation batch and connection
 * change back on one ordered event channel. All policy (pending calls, epochs, credits, crash backoff)
 * lives in Dart's ProcessEngineHost; the FFI path of this package does not use this class at all.
 */
class SherpaInferencePlugin : FlutterPlugin, InferenceHostApi {
  private var client: InferenceClient? = null
  private var stream: MessageStream? = null

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    val s = MessageStream()
    stream = s
    InferenceMessagesStreamHandler.register(binding.binaryMessenger, s)
    client = InferenceClient(binding.applicationContext, s::post)
    InferenceHostApi.setUp(binding.binaryMessenger, this)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    InferenceHostApi.setUp(binding.binaryMessenger, null)
    client?.close()
    client = null
    stream?.detach()
    stream = null
  }

  private fun requireClient(): InferenceClient =
    client ?: throw SherpaInferenceError("detached", "the plugin is not attached to an engine", null)

  override fun connect(policy: BindPolicy): Long = requireClient().connect(policy)

  override fun send(connection: Long, requestId: Long, call: EngineCall) = requireClient().send(connection, requestId, call)

  override fun setBusy(connection: Long, busy: Boolean) = requireClient().setBusy(connection, busy)

  override fun disconnect(connection: Long) = requireClient().disconnect(connection)
}

/**
 * The event channel's sink, fed from any thread. Event sinks must be called on the platform main thread,
 * so messages are posted there in arrival order; before Dart listens (or between a hot restart's
 * cancel/listen) they are buffered, bounded.
 */
private class MessageStream : InferenceMessagesStreamHandler() {
  private val main = Handler(Looper.getMainLooper())
  private var sink: PigeonEventSink<InferenceMessage>? = null
  private val backlog = ArrayDeque<InferenceMessage>()
  private var detached = false

  override fun onListen(p0: Any?, sink: PigeonEventSink<InferenceMessage>) {
    this.sink = sink
    while (backlog.isNotEmpty()) sink.success(backlog.removeFirst())
  }

  override fun onCancel(p0: Any?) {
    sink = null
  }

  fun post(message: InferenceMessage) {
    main.post {
      if (detached) return@post
      val s = sink
      if (s != null) {
        s.success(message)
      } else {
        backlog.addLast(message)
        while (backlog.size > MAX_BACKLOG) backlog.removeFirst()
      }
    }
  }

  fun detach() {
    main.post {
      detached = true
      sink = null
      backlog.clear()
    }
  }

  companion object {
    const val MAX_BACKLOG = 1024
  }
}
