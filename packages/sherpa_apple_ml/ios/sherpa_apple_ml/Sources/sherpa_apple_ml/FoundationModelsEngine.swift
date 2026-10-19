#if canImport(FoundationModels)
  import Foundation
  import FoundationModels

  /// Apple Foundation Models (`SystemLanguageModel.default`, iOS 26+).
  ///
  /// Compiled only with an SDK that has the framework (`canImport`), created
  /// only on iOS 26+ (`@available`); every symbol it uses is newer than the
  /// iOS 17 deployment target, so the framework is weak-linked and the app
  /// still launches on iOS 17–25 (podspec: explicit `weak_frameworks`).
  ///
  /// UNVERIFIED against the real SDK: type-checked against a stand-in module
  /// that mirrors the DocC declarations fetched on 2026-10-19.
  @available(iOS 26.0, macOS 26.0, *)
  actor FoundationModelsEngine: FmEngineAPI {
    private let hub: EventHub
    private let broker = ToolBroker()
    private var sessions: [String: LanguageModelSession] = [:]
    private var active: [String: (task: Task<Void, Never>, sessionKey: String)] = [:]

    init(hub: EventHub) {
      self.hub = hub
    }

    func availability() async -> AmFmAvailability {
      let model = SystemLanguageModel.default
      switch model.availability {
      case .available:
        var a = AmFmAvailability(available: true, reason: .none, localeSupported: model.supportsLocale(Locale.current))
        a.contextSize = Int64(model.contextSize)
        return a
      case .unavailable(let reason):
        let mapped: AmFmUnavailableReason
        switch reason {
        case .deviceNotEligible: mapped = .deviceNotEligible
        case .appleIntelligenceNotEnabled: mapped = .appleIntelligenceNotEnabled
        case .modelNotReady: mapped = .modelNotReady
        @unknown default: mapped = .unknown
        }
        return AmFmAvailability(available: false, reason: mapped, localeSupported: false)
      }
    }

    func prewarm(instructions: String?) async {
      let session = makeFreshSession(instructions: instructions, tools: [])
      session.prewarm(promptPrefix: nil)
    }

    func dropSession(_ sessionKey: String) async {
      sessions.removeValue(forKey: sessionKey)
    }

    func cancel(generationId: String) async {
      active[generationId]?.task.cancel()
      await broker.cancelAll(generationId: generationId)
    }

    func submitToolResults(generationId: String, results: [AmToolResult]) async {
      await broker.resolve(generationId: generationId, results: results)
    }

    func generate(_ request: AmFmGenerateRequest) async throws {
      // Tools are bound to the session key: in append mode the session's
      // tools (fixed at init) route each call to the current generation.
      let tools: [any Tool] = try request.tools.map { t in
        DartTool(
          name: t.name, description: t.summary, parameters: try FmSchemaBuilder.schema(from: t.schemaJson),
          sessionKey: request.sessionKey, broker: broker)
      }
      let responseSchema = try request.responseSchemaJson.map(FmSchemaBuilder.schema(from:))
      let session: LanguageModelSession
      switch request.mode {
      case .append:
        guard let s = sessions[request.sessionKey] else {
          throw PluginError.make(.sessionLost, "The system-model session was dropped; rebuild it.")
        }
        session = s
      default:
        session =
          request.history.isEmpty
          ? makeFreshSession(instructions: request.instructions, tools: tools)
          : LanguageModelSession(
            model: SystemLanguageModel.default, tools: tools,
            transcript: try FmTranscript.build(instructions: request.instructions, tools: tools, history: request.history))
        sessions[request.sessionKey] = session
      }
      let pump = hub.pump(for: request.generationId)
      await broker.bind(sessionKey: request.sessionKey, generationId: request.generationId, pump: pump)
      let task = Task {
        await self.run(request, session: session, schema: responseSchema, pump: pump)
      }
      active[request.generationId] = (task, request.sessionKey)
    }

    /// A new session: the documented instructions-builder initializer when
    /// there are instructions; otherwise a transcript whose instructions
    /// entry carries only the tool definitions (what the framework records
    /// itself; UNVERIFIED whether it would also add them on its own).
    private func makeFreshSession(instructions: String?, tools: [any Tool]) -> LanguageModelSession {
      guard let instructions = instructions, !instructions.isEmpty else {
        let transcript = (try? FmTranscript.build(instructions: nil, tools: tools, history: [])) ?? Transcript()
        return LanguageModelSession(model: SystemLanguageModel.default, tools: tools, transcript: transcript)
      }
      return LanguageModelSession(model: SystemLanguageModel.default, tools: tools) { instructions }
    }

    private func run(
      _ request: AmFmGenerateRequest, session: LanguageModelSession, schema: GenerationSchema?, pump: GenerationPump
    ) async {
      let usageBefore = Self.usage(of: session)
      do {
        let options = Self.options(request)
        let prompt = Prompt { request.prompt }
        if let schema = schema {
          // Guided generation: partial JSON snapshots are not prefix-stable,
          // so the final content is sent once.
          var last: GeneratedContent?
          for try await snapshot in session.streamResponse(
            to: prompt, schema: schema, includeSchemaInPrompt: true, options: options)
          {
            last = snapshot.rawContent
          }
          if let last = last { pump.push(AmEvent.make(.text, text: last.jsonString)) }
        } else {
          var differ = SnapshotDiffer()
          for try await snapshot in session.streamResponse(to: prompt, options: options) {
            let afterTool = await broker.takeToolBoundary(sessionKey: request.sessionKey)
            if let (delta, rewound) = differ.delta(snapshot.content, newSegment: afterTool) {
              if rewound > 0 {
                pump.push(
                  AmEvent.make(
                    .notice, code: "fm_snapshot_rewrite",
                    message: "The system model revised \(rewound) characters already shown."))
              }
              if !delta.isEmpty { pump.push(AmEvent.make(.text, text: delta)) }
            }
          }
        }
        if let info = Self.usageEvent(before: usageBefore, after: Self.usage(of: session)) { pump.push(info) }
        pump.push(.finished, code: Task.isCancelled ? "cancelled" : "stop")
      } catch {
        pump.push(Self.event(for: error))
        // The transcript may hold a partial turn: start over next time.
        sessions.removeValue(forKey: request.sessionKey)
      }
      await broker.unbind(sessionKey: request.sessionKey, generationId: request.generationId)
      active.removeValue(forKey: request.generationId)
      if request.ephemeral { sessions.removeValue(forKey: request.sessionKey) }
    }

    private static func options(_ r: AmFmGenerateRequest) -> GenerationOptions {
      let s = r.sampling
      let seed = s.seed.map { UInt64(bitPattern: $0) }
      let mode: GenerationOptions.SamplingMode?
      if r.greedy {
        mode = .greedy
      } else if let k = s.topK {
        mode = .random(top: Int(k), seed: seed)
      } else if let p = s.topP {
        mode = .random(probabilityThreshold: p, seed: seed)
      } else {
        mode = nil
      }
      return GenerationOptions(
        sampling: mode, temperature: r.greedy ? nil : s.temperature,
        maximumResponseTokens: s.maxTokens.map { Int($0) })
    }

    // MARK: Usage
    //
    // `LanguageModelSession.usage` is iOS 27 SDK API. The app builds with the
    // iOS 26 SDK (Xcode 26, CI's macos-26 image), where the symbol does not
    // exist even behind #available, so usage is not reported yet.

    private struct UsageCounts {
      var input = 0, cached = 0, output = 0, reasoning = 0
    }

    private static func usage(of session: LanguageModelSession) -> UsageCounts? {
      _ = session
      return nil
    }

    private static func usageEvent(before: UsageCounts?, after: UsageCounts?) -> AmEvent? {
      guard let b = before, let a = after else { return nil }
      var e = AmEvent(kind: .info)
      e.promptTokens = Int64(a.input - b.input)
      e.cachedPromptTokens = Int64(a.cached - b.cached)
      e.generationTokens = Int64(a.output - b.output)
      e.reasoningTokens = Int64(a.reasoning - b.reasoning)
      return e
    }

    // MARK: Errors (iOS 26 SDK: LanguageModelSession.GenerationError; the iOS 27
    // LanguageModelError type is not in the SDK the app builds with)

    private static func event(for error: Error) -> AmEvent {
      if error is CancellationError { return AmEvent.make(.finished, code: "cancelled") }
      if let e = error as? LanguageModelSession.ToolCallError {
        if e.underlyingError is CancellationError { return AmEvent.make(.finished, code: "cancelled") }
        return AmEvent.make(.error, code: ErrorCode.server.rawValue, message: e.localizedDescription)
      }
      if let e = error as? LanguageModelSession.GenerationError {
        let message = e.localizedDescription
        switch e {
        case .exceededContextWindowSize: return AmEvent.make(.error, code: ErrorCode.contextOverflow.rawValue, message: message)
        case .guardrailViolation: return AmEvent.make(.finished, code: "guardrail", message: message)
        case .refusal: return AmEvent.make(.finished, code: "refusal", message: message)
        case .rateLimited: return AmEvent.make(.error, code: ErrorCode.rateLimited.rawValue, message: message)
        case .assetsUnavailable: return AmEvent.make(.error, code: ErrorCode.assetsUnavailable.rawValue, message: message)
        case .concurrentRequests: return AmEvent.make(.error, code: ErrorCode.busy.rawValue, message: message)
        case .unsupportedGuide: return AmEvent.make(.error, code: ErrorCode.invalidRequest.rawValue, message: message)
        case .unsupportedLanguageOrLocale:
          return AmEvent.make(.error, code: ErrorCode.unsupportedLanguage.rawValue, message: message)
        case .decodingFailure: return AmEvent.make(.error, code: ErrorCode.server.rawValue, message: message)
        @unknown default: return AmEvent.make(.error, code: ErrorCode.unknown.rawValue, message: message)
        }
      }
      if error is GenerationSchema.SchemaError {
        return AmEvent.make(.error, code: ErrorCode.invalidRequest.rawValue, message: "\(error)")
      }
      if let e = error as? SherpaAppleMlError { return AmEvent.make(.error, code: e.code, message: e.message) }
      return AmEvent.make(.error, code: ErrorCode.unknown.rawValue, message: "\(error)")
    }
  }

  /// Bridges one Sherpa tool: `call` SUSPENDS until Dart answers. The agent
  /// loop owns execution and approvals; Swift only forwards.
  @available(iOS 26.0, macOS 26.0, *)
  struct DartTool: Tool {
    let name: String
    let description: String
    let parameters: GenerationSchema
    let sessionKey: String
    let broker: ToolBroker

    func call(arguments: GeneratedContent) async throws -> String {
      try await broker.call(sessionKey: sessionKey, toolName: name, argumentsJson: arguments.jsonString)
    }
  }

  /// Routes suspended `Tool.call`s to Dart and their results back.
  @available(iOS 26.0, macOS 26.0, *)
  actor ToolBroker {
    private var bindings: [String: (generationId: String, pump: GenerationPump)] = [:]
    private var waiting: [String: (generationId: String, continuation: CheckedContinuation<String, Error>)] = [:]
    private var toolBoundary: Set<String> = []

    func bind(sessionKey: String, generationId: String, pump: GenerationPump) {
      bindings[sessionKey] = (generationId, pump)
    }

    func unbind(sessionKey: String, generationId: String) {
      if bindings[sessionKey]?.generationId == generationId { bindings.removeValue(forKey: sessionKey) }
      cancelAll(generationId: generationId)
    }

    func call(sessionKey: String, toolName: String, argumentsJson: String) async throws -> String {
      guard let binding = bindings[sessionKey] else { throw CancellationError() }
      let callId = "fm_" + UUID().uuidString
      toolBoundary.insert(sessionKey)
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
          if Task.isCancelled {
            c.resume(throwing: CancellationError())
            return
          }
          waiting[callId] = (binding.generationId, c)
          var e = AmEvent(kind: .toolRequest)
          e.callId = callId
          e.toolName = toolName
          e.argumentsJson = argumentsJson
          binding.pump.push(e)
        }
      } onCancel: {
        Task { await self.cancel(callId: callId) }
      }
    }

    /// A tool ran since the last snapshot of this session (the response
    /// text may start a new segment).
    func takeToolBoundary(sessionKey: String) -> Bool {
      toolBoundary.remove(sessionKey) != nil
    }

    func resolve(generationId: String, results: [AmToolResult]) {
      for r in results {
        guard let w = waiting[r.callId], w.generationId == generationId else { continue }
        waiting.removeValue(forKey: r.callId)
        // Errors go back as text so the model can recover (throwing would
        // end the whole response with ToolCallError).
        w.continuation.resume(returning: r.output)
      }
    }

    private func cancel(callId: String) {
      waiting.removeValue(forKey: callId)?.continuation.resume(throwing: CancellationError())
    }

    func cancelAll(generationId: String) {
      for (id, w) in waiting where w.generationId == generationId {
        waiting.removeValue(forKey: id)
        w.continuation.resume(throwing: CancellationError())
      }
    }
  }

  /// `ResponseStream` yields snapshots of the FULL content so far (R06
  /// §3.2); Dart wants deltas.
  struct SnapshotDiffer {
    private var emitted = ""

    /// The new text, and how many already-sent characters the snapshot no
    /// longer contains. After a tool call ([newSegment]) a snapshot that
    /// does not extend the sent text starts a new segment.
    mutating func delta(_ full: String, newSegment: Bool) -> (String, Int)? {
      if full.hasPrefix(emitted) {
        let d = String(full.dropFirst(emitted.count))
        emitted = full
        return d.isEmpty ? nil : (d, 0)
      }
      if newSegment {
        emitted = full
        return full.isEmpty ? nil : (full, 0)
      }
      let common = zip(full, emitted).prefix { $0 == $1 }.count
      let rewound = emitted.count - common
      emitted = full
      return (String(full.dropFirst(common)), rewound)
    }
  }

  /// Builds a `Transcript` from Dart's history (rebuild mode).
  @available(iOS 26.0, macOS 26.0, *)
  enum FmTranscript {
    static func build(instructions: String?, tools: [any Tool], history: [AmWireMessage]) throws -> Transcript {
      var entries: [Transcript.Entry] = []
      if (instructions?.isEmpty == false) || !tools.isEmpty {
        let segments: [Transcript.Segment] = instructions.map { [.text(Transcript.TextSegment(content: $0))] } ?? []
        entries.append(
          .instructions(
            Transcript.Instructions(
              segments: segments, toolDefinitions: tools.map { Transcript.ToolDefinition(tool: $0) })))
      }
      for m in history {
        let text: [Transcript.Segment] = [.text(Transcript.TextSegment(content: m.content))]
        switch m.role {
        case "assistant":
          if !m.content.isEmpty {
            entries.append(.response(Transcript.Response(assetIDs: [], segments: text)))
          }
          if let calls = m.toolCalls, !calls.isEmpty {
            let mapped = try calls.map { c in
              Transcript.ToolCall(id: c.id, toolName: c.name, arguments: try GeneratedContent(json: c.argumentsJson))
            }
            entries.append(.toolCalls(Transcript.ToolCalls(mapped)))
          }
        case "tool":
          entries.append(
            .toolOutput(
              Transcript.ToolOutput(
                id: m.toolCallId ?? UUID().uuidString, toolName: m.toolName ?? "tool", segments: text)))
        default:  // user, system notes (merged into user turns in Dart)
          entries.append(.prompt(Transcript.Prompt(segments: text)))
        }
      }
      return Transcript(entries: entries)
    }
  }
#endif
