#if canImport(MLXLLM)
  import Foundation
  import MLX
  import MLXLLM
  import MLXLMCommon
  import os

  /// MLX inference: one loaded `ModelContainer`, one `ChatSession` per Sherpa
  /// session, one generation at a time per session (Dart queues them).
  ///
  /// * History policy is decided in Dart (`AmHistoryMode`): `append` keeps
  ///   the session (its instructions/tools/parameters are updated in place;
  ///   ChatSession re-renders the template and reuses the longest common
  ///   token prefix of its KV cache); `rebuild` replaces it with
  ///   `ChatSession(history:)`; `continueAssistant` renders the history plus
  ///   the partial reply with the low-level `generateTask` and leaves no
  ///   session; `restoreCache` starts from `loadPromptCacheSnapshot`.
  /// * Tool calls use manual dispatch (`toolDispatch == nil`): the reply ends
  ///   with `.toolCall` events and Dart sends the results as `.tool`
  ///   messages in the next `append`.
  /// * Every generation waits for the [GpuGate], runs under `withError`, and
  ///   checks the process-level error relay after each token.
  ///
  /// UNVERIFIED against the real mlx-swift-lm 3.32.3 build (type-checked
  /// against stand-ins mirroring its public declarations only).
  actor MlxEngine: MlxEngineAPI {
    private struct Loaded {
      let modelId: String
      let container: ModelContainer
      let info: AmMlxModelInfo
    }

    private struct Active {
      let task: Task<Void, Never>
      let sessionKey: String
      var pauseReason: String?
    }

    private let gate: GpuGate
    private let hub: EventHub
    private var loaded: Loaded?
    private var sessions: [String: ChatSession] = [:]
    private var active: [String: Active] = [:]

    init(gate: GpuGate, hub: EventHub) {
      self.gate = gate
      self.hub = hub
      MlxErrorRelay.install()
    }

    nonisolated var recommendedWorkingSetBytes: Int? { GPU.maxRecommendedWorkingSetBytes() }

    // MARK: Model lifecycle

    func load(_ request: AmMlxLoadRequest) async throws -> AmMlxModelInfo {
      if let l = loaded, l.modelId == request.modelId { return l.info }
      if loaded != nil { await unloadAll() }
      // Loading evaluates weights on the GPU: never while backgrounded.
      try await gate.waitUntilOpen()

      // R06 §2.9: Memory.cacheLimit / Memory.memoryLimit (GPU.set(...) is
      // deprecated). The limit is a fraction of what the process may still
      // allocate (os_proc_available_memory, limit minus footprint) plus what
      // MLX already holds.
      let activeBefore = Memory.activeMemory
      let available = os_proc_available_memory()
      Memory.cacheLimit = Int(request.cacheLimitBytes)
      let limit = Int(Double(available + activeBefore) * request.memoryLimitFraction)
      if limit > 0 { Memory.memoryLimit = limit }

      let started = Date()
      let directory = URL(fileURLWithPath: request.directory, isDirectory: true)
      let container: ModelContainer
      do {
        container = try await withError {
          try await LLMModelFactory.shared.loadContainer(from: directory, using: TransformersTokenizerLoader())
        }
        if let message = MlxErrorRelay.take() { throw MLXError.caught(message) }
      } catch {
        Memory.clearCache()
        let (code, message) = MlxErrors.classify(error)
        throw PluginError.make(code, message)
      }
      let configuration = await container.configuration
      let primed = await Self.reasoningPrimed(container, configuration.reasoningConfig)
      var info = AmMlxModelInfo(
        modelId: request.modelId,
        reasoningImplicitEnds: configuration.reasoningConfig?.implicitEndDelimiters ?? [],
        reasoningAlwaysOn: configuration.reasoningConfig?.promptStrategy == .alwaysOn,
        reasoningPrimed: primed,
        weightsBytes: Int64(max(0, Memory.activeMemory - activeBefore)),
        loadMs: Int64(Date().timeIntervalSince(started) * 1000),
        memoryLimitBytes: Int64(Memory.memoryLimit),
        cacheLimitBytes: Int64(Memory.cacheLimit),
        procAvailableBytes: Int64(os_proc_available_memory())
      )
      info.modelType = Self.modelType(in: directory)
      info.toolCallFormat = configuration.toolCallFormat?.rawValue
      if let reasoning = configuration.reasoningConfig {
        info.reasoningStart = reasoning.startDelimiter
        info.reasoningEnd = reasoning.endDelimiter
        if case .templateFlag(let key, let defaultOn) = reasoning.promptStrategy {
          info.reasoningToggleKey = key
          info.reasoningToggleDefaultOn = defaultOn
        }
      }
      loaded = Loaded(modelId: request.modelId, container: container, info: info)
      return info
    }

    /// Renders a one-message probe with thinking on and checks whether the
    /// prompt ends inside a reasoning span (the template pre-filled the
    /// opening delimiter). Tokenizer only: no GPU work.
    private static func reasoningPrimed(_ container: ModelContainer, _ config: ReasoningConfig?) async -> Bool {
      guard let config = config else { return false }
      let context: [String: any Sendable]?
      if case .templateFlag(let key, _) = config.promptStrategy { context = [key: true] } else { context = nil }
      let tokenizer = await container.tokenizer
      let probe: [[String: any Sendable]] = [["role": "user", "content": "Hi"]]
      guard let tokens = try? tokenizer.applyChatTemplate(messages: probe, tools: nil, additionalContext: context)
      else { return false }
      let tail = tokenizer.decode(tokenIds: Array(tokens.suffix(24)), skipSpecialTokens: false)
      return tail.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(config.startDelimiter)
    }

    private static func modelType(in directory: URL) -> String? {
      guard let data = try? Data(contentsOf: directory.appendingPathComponent("config.json")),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return nil }
      return object["model_type"] as? String
    }

    func unload(modelId: String) async {
      guard loaded?.modelId == modelId else { return }
      await unloadAll()
    }

    private func unloadAll() async {
      let running = active.values.map(\.task)
      for (id, _) in active { active[id]?.pauseReason = nil }
      for t in running { t.cancel() }
      for t in running { await t.value }
      sessions.removeAll()
      loaded = nil
      Memory.clearCache()
    }

    func dropSession(_ sessionKey: String) async {
      sessions.removeValue(forKey: sessionKey)
    }

    func countTokens(modelId: String, text: String) async throws -> Int {
      guard let l = loaded, l.modelId == modelId else {
        throw PluginError.make(.modelUnloaded, "The model is not loaded.")
      }
      return await l.container.encode(text).count
    }

    func savePromptCache(sessionKey: String, path: String) async throws -> Bool {
      guard let session = sessions[sessionKey], active.values.allSatisfy({ $0.sessionKey != sessionKey }) else {
        return false
      }
      do {
        try await withError { try await session.saveCache(to: URL(fileURLWithPath: path)) }
        return true
      } catch ChatSessionError.noCacheAvailable {
        return false
      } catch {
        let (code, message) = MlxErrors.classify(error)
        throw PluginError.make(code, message)
      }
    }

    // MARK: Generation

    func generate(_ request: AmMlxGenerateRequest) async throws {
      guard let model = loaded, model.modelId == request.modelId else {
        throw PluginError.make(.modelUnloaded, "\(request.modelId) is not loaded.")
      }
      if request.mode == .append, sessions[request.sessionKey] == nil {
        throw PluginError.make(.sessionLost, "The on-device session was dropped; rebuild it.")
      }
      let tools = try MlxWire.toolSpecs(request.toolsJson)
      let pump = hub.pump(for: request.generationId)
      let id = request.generationId
      let task = Task { await self.run(request, model: model, tools: tools, pump: pump) }
      active[id] = Active(task: task, sessionKey: request.sessionKey, pauseReason: nil)
    }

    func cancel(generationId: String) async {
      active[generationId]?.task.cancel()
    }

    func pauseAll(reason: String) async {
      let ids = Array(active.keys)
      var tasks: [Task<Void, Never>] = []
      for id in ids {
        active[id]?.pauseReason = reason
        if let t = active[id]?.task {
          t.cancel()
          tasks.append(t)
        }
      }
      for t in tasks { await t.value }
      // Nothing is generating now; make sure the GPU queue has drained before
      // the app is backgrounded (Metal: "stop committing on deactivation").
      if !tasks.isEmpty {
        try? withError { MLX.Stream.gpu.synchronize() }
      }
    }

    func handleMemoryWarning() async {
      let before = Memory.snapshot()
      let busy = Set(active.values.map(\.sessionKey))
      let dropped = sessions.keys.filter { !busy.contains($0) }
      for key in dropped { sessions.removeValue(forKey: key) }
      Memory.clearCache()
      let after = Memory.snapshot()
      var e = AmEvent.make(
        .memoryWarning, code: "mlx",
        message: "Cleared the MLX buffer cache and dropped \(dropped.count) idle session(s).")
      e.bytes = Int64(max(0, (before.activeMemory + before.cacheMemory) - (after.activeMemory + after.cacheMemory)))
      // Dart invalidates these sessions' ledgers (newline-separated keys).
      e.text = dropped.joined(separator: "\n")
      hub.emitGlobal(e)
    }

    private func pauseReason(_ id: String) -> String? { active[id]?.pauseReason }

    private func finish(_ request: AmMlxGenerateRequest) {
      active.removeValue(forKey: request.generationId)
      if request.ephemeral { sessions.removeValue(forKey: request.sessionKey) }
    }

    /// The generation itself. Runs on the actor between tokens; MLX work
    /// happens in ChatSession's / generateTask's own tasks.
    private func run(
      _ request: AmMlxGenerateRequest, model: Loaded, tools: [ToolSpec]?, pump: GenerationPump
    ) async {
      defer { finish(request) }
      let id = request.generationId
      do {
        if !gate.isOpen { pump.push(.waiting, code: gate.reason) }
        try await gate.waitUntilOpen()
        try Task.checkCancellation()

        let parameters = MlxWire.parameters(request.sampling, request.kv)
        let context = MlxWire.additionalContext(key: request.thinkingKey, enabled: request.thinkingEnabled)
        var stopReason: GenerateStopReason?
        var session: ChatSession?

        try await withError { (errors: ErrorBox) in
          let stream: AsyncThrowingStream<Generation, Error>
          var lowLevelTask: Task<Void, Never>?
          switch request.mode {
          case .append:
            guard let s = sessions[request.sessionKey] else {
              throw PluginError.make(.sessionLost, "The on-device session was dropped; rebuild it.")
            }
            s.instructions = request.instructions
            s.tools = tools
            s.additionalContext = context
            s.generateParameters = parameters
            session = s
            stream = s.streamDetails(to: request.pending.map(MlxWire.chatMessage))
          case .rebuild:
            let s = ChatSession(
              model.container, instructions: request.instructions,
              history: request.history.map(MlxWire.chatMessage),
              generateParameters: parameters, additionalContext: context, tools: tools)
            sessions[request.sessionKey] = s
            session = s
            stream = s.streamDetails(to: request.pending.map(MlxWire.chatMessage))
          case .restoreCache:
            guard let path = request.cachePath else {
              throw PluginError.make(.invalidRequest, "restoreCache needs a cache path")
            }
            let snapshot = try loadPromptCacheSnapshot(url: URL(fileURLWithPath: path))
            let s = ChatSession(
              model.container, promptCache: snapshot,
              generateParameters: parameters, additionalContext: context, tools: tools)
            sessions[request.sessionKey] = s
            session = s
            stream = s.streamDetails(to: request.pending.map(MlxWire.chatMessage))
          case .continueAssistant:
            sessions.removeValue(forKey: request.sessionKey)
            let (generations, task) = try await Self.continuation(
              model.container, request: request, parameters: parameters, context: context, tools: tools)
            lowLevelTask = task
            stream = AsyncThrowingStream { continuation in
              let forward = Task {
                for await g in generations { continuation.yield(g) }
                continuation.finish()
              }
              continuation.onTermination = { _ in
                forward.cancel()
                task.cancel()
              }
            }
          }

          for try await item in stream {
            try errors.check()
            if let message = MlxErrorRelay.take() { throw MLXError.caught(message) }
            if Task.isCancelled { break }
            switch item {
            case .chunk(let text):
              var e = AmEvent(kind: .text)
              e.text = text
              pump.push(e)
            case .toolCall(let call):
              pump.push(MlxWire.toolCallEvent(call))
            case .rejectedToolCall(let rejection):
              pump.push(MlxWire.rejectedEvent(rejection))
            case .info(let info):
              stopReason = info.stopReason
              pump.push(MlxWire.infoEvent(info))
            }
          }
          // Wait until the generation behind the stream has really stopped
          // (it finishes the current token after a cancel) so no GPU work is
          // in flight when we report.
          if let s = session { await s.synchronize() }
          if let t = lowLevelTask { await t.value }
        }

        if let reason = pauseReason(id) {
          pump.push(.paused, code: reason)
        } else if Task.isCancelled {
          pump.push(.finished, code: "cancelled")
        } else {
          pump.push(.finished, code: MlxWire.stopCode(stopReason))
        }
      } catch {
        if request.mode != .append { sessions.removeValue(forKey: request.sessionKey) }
        if let reason = pauseReason(id) {
          // Also when the GPU refused work while pausing: the reply is paused.
          pump.push(.paused, code: reason)
        } else if error is CancellationError || Task.isCancelled {
          pump.push(.finished, code: "cancelled")
        } else if let e = error as? SherpaAppleMlError {
          pump.push(.error, code: e.code, message: e.message)
        } else {
          pump.push(MlxErrors.event(for: error))
        }
        if error is MLXError {
          // The model may be in an undefined state after an MLX/GPU error:
          // drop it; Dart reloads on the next request.
          await reloadAfterEngineError(model.modelId)
        }
      }
    }

    /// Low-level continuation of a reply paused at a token boundary: render
    /// the history with a generation prompt, append the partial reply's
    /// tokens, generate. No ChatSession records it (Dart rebuilds next turn).
    private static func continuation(
      _ container: ModelContainer, request: AmMlxGenerateRequest, parameters: GenerateParameters,
      context: [String: any Sendable]?, tools: [ToolSpec]?
    ) async throws -> (AsyncStream<Generation>, Task<Void, Never>) {
      var messages = request.history.map(MlxWire.chatMessage)
      if let instructions = request.instructions { messages.insert(.system(instructions), at: 0) }
      let input = UserInput(chat: messages, tools: tools, additionalContext: context)
      let partial = request.partialAssistant ?? ""
      return try await container.perform(nonSendable: input) { (ctx: ModelContext, input: UserInput) in
        let prepared = try await ctx.processor.prepare(input: input)
        let tokens = prepared.text.tokens.asArray(Int.self) + ctx.tokenizer.encode(text: partial, addSpecialTokens: false)
        let iterator = try TokenIterator(input: LMInput(tokens: MLXArray(tokens)), model: ctx.model, parameters: parameters)
        return generateTask(
          promptTokenCount: tokens.count, modelConfiguration: ctx.configuration, tokenizer: ctx.tokenizer,
          iterator: iterator, tools: tools, toolCallPolicy: parameters.toolCallPolicy)
      }
    }

    private func reloadAfterEngineError(_ modelId: String) async {
      guard loaded?.modelId == modelId else { return }
      sessions.removeAll()
      loaded = nil
      Memory.clearCache()
      hub.emitGlobal(AmEvent.make(.notice, code: "modelUnloaded", message: "MLX error: the model will be reloaded.", text: modelId))
    }
  }
#endif
