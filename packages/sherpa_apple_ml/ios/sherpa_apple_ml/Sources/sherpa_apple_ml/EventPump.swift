import Foundation

/// Owns the Flutter event sink and one [GenerationPump] per generation.
///
/// Threading: the sink is only touched on the main thread (Flutter requires
/// it); pumps are filled from engine tasks under a lock and flushed with
/// `DispatchQueue.main.async`, so the main thread never waits for an engine
/// and an engine never waits for the main thread.
final class EventHub: EventsStreamHandler, @unchecked Sendable {
  private var sink: PigeonEventSink<AmEventBatch>?  // main thread only
  private let lock = NSLock()
  private var pumps: [String: GenerationPump] = [:]  // guarded by lock

  override func onListen(withArguments arguments: Any?, sink: PigeonEventSink<AmEventBatch>) {
    self.sink = sink
    for pump in lock.withLock({ Array(pumps.values) }) {
      pump.scheduleFlush(immediately: true)
    }
  }

  override func onCancel(withArguments arguments: Any?) {
    sink = nil
  }

  var hasListener: Bool {
    dispatchPrecondition(condition: .onQueue(.main))
    return sink != nil
  }

  /// The pump for a new generation (replaces a stale one with the same id).
  func pump(for generationId: String) -> GenerationPump {
    let pump = GenerationPump(generationId: generationId, hub: self)
    lock.withLock { pumps[generationId] = pump }
    return pump
  }

  func ack(generationId: String, seq: Int64) {
    lock.withLock { pumps[generationId] }?.ack(seq)
  }

  fileprivate func remove(_ generationId: String, pump: GenerationPump) {
    lock.withLock {
      if pumps[generationId] === pump { pumps.removeValue(forKey: generationId) }
    }
  }

  /// Events not tied to a generation; they bypass credits.
  func emitGlobal(_ event: AmEvent) {
    DispatchQueue.main.async { [weak self] in
      self?.sink?.success(AmEventBatch(generationId: "", seq: 0, events: [event]))
    }
  }

  fileprivate func send(_ batch: AmEventBatch) {
    dispatchPrecondition(condition: .onQueue(.main))
    sink?.success(batch)
  }
}

/// A bounded, coalescing buffer between one engine generation and the event
/// channel.
///
/// * Text events coalesce into the previous pending text event, so pending
///   memory is one string plus a bounded number of structural events.
/// * Batches are flushed at most every [flushInterval] (structural and
///   terminal events flush at once) and at most [maxOutstanding] batches
///   are in flight; Dart returns one credit (`ack`) per delivered batch and
///   none while its consumer is paused.
/// * After the terminal event has been acked the pump unregisters itself.
final class GenerationPump: @unchecked Sendable {
  static let maxOutstanding = 4
  static let flushInterval: DispatchTimeInterval = .milliseconds(16)

  let generationId: String
  private weak var hub: EventHub?
  private let lock = NSLock()
  private var pending: [AmEvent] = []
  private var outstanding: Set<Int64> = []
  private var nextSeq: Int64 = 0
  private var flushScheduled = false
  private var terminalQueued = false
  private var terminalSent = false

  init(generationId: String, hub: EventHub) {
    self.generationId = generationId
    self.hub = hub
  }

  static func isTerminal(_ kind: AmEventKind) -> Bool {
    kind == .finished || kind == .paused || kind == .error
  }

  /// Queues [event]; events after the terminal one are dropped.
  func push(_ event: AmEvent) {
    let urgent = event.kind != .text
    let accepted: Bool = lock.withLock {
      if terminalQueued { return false }
      if event.kind == .text, let last = pending.last, last.kind == .text {
        pending[pending.count - 1].text = (last.text ?? "") + (event.text ?? "")
      } else {
        pending.append(event)
      }
      if Self.isTerminal(event.kind) { terminalQueued = true }
      return true
    }
    if accepted { scheduleFlush(immediately: urgent) }
  }

  func push(_ kind: AmEventKind, code: String? = nil, message: String? = nil) {
    var e = AmEvent(kind: kind)
    e.code = code
    e.message = message
    push(e)
  }

  var hasTerminal: Bool { lock.withLock { terminalQueued } }

  func ack(_ seq: Int64) {
    let done: Bool = lock.withLock {
      outstanding.remove(seq)
      return terminalSent && outstanding.isEmpty && pending.isEmpty
    }
    if done {
      hub?.remove(generationId, pump: self)
    } else {
      scheduleFlush(immediately: true)
    }
  }

  func scheduleFlush(immediately: Bool) {
    let schedule: Bool = lock.withLock {
      if flushScheduled { return false }
      flushScheduled = true
      return true
    }
    guard schedule else { return }
    if immediately {
      DispatchQueue.main.async { [weak self] in self?.flush() }
    } else {
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.flushInterval) { [weak self] in self?.flush() }
    }
  }

  private func flush() {
    guard let hub = hub else { return }
    let canSend = hub.hasListener
    let batch: AmEventBatch? = lock.withLock {
      flushScheduled = false
      guard canSend, !pending.isEmpty, outstanding.count < Self.maxOutstanding else { return nil }
      let seq = nextSeq
      nextSeq += 1
      outstanding.insert(seq)
      let events = pending
      pending.removeAll(keepingCapacity: true)
      if events.contains(where: { Self.isTerminal($0.kind) }) { terminalSent = true }
      return AmEventBatch(generationId: generationId, seq: seq, events: events)
    }
    if let batch = batch { hub.send(batch) }
  }
}
