#if canImport(MLXLLM)
  import Foundation
  import MLX
  import MLXLLM
  import MLXLMCommon
  import Tokenizers

  // MARK: - Error handling (R06 §2.10)

  /// MLX reports C++ errors through a handler; the default one "will simply
  /// print out the error, then exit". Two layers replace it:
  /// 1. every MLX entry point runs inside `withError { }` (a task-local
  ///    handler that turns the error into a Swift `throw`);
  /// 2. a process-wide handler (installed once, here) catches errors raised
  ///    outside any `withError` scope, e.g. on a Metal completion thread. It
  ///    records the message instead of exiting; the engine checks it after
  ///    every token and fails the generation, then reloads the model.
  /// `setErrorHandler` is deprecated in favour of `withErrorHandler` /
  /// `withError`, but those are task-local and cannot cover other threads.
  enum MlxErrorRelay {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending: String?
    nonisolated(unsafe) private static var installed = false

    static func install() {
      let first: Bool = lock.withLock {
        defer { installed = true }
        return !installed
      }
      guard first else { return }
      setErrorHandler(mlxProcessErrorHandler, data: nil, dtor: nil)
    }

    static func record(_ message: String) {
      NSLog("[sherpa_apple_ml] MLX error caught by the process handler: %@", message)
      lock.withLock { pending = message }
    }

    /// The last process-level MLX error, consumed.
    static func take() -> String? {
      lock.withLock {
        defer { pending = nil }
        return pending
      }
    }
  }

  private func mlxProcessErrorHandler(_ message: UnsafePointer<CChar>?, _ data: UnsafeMutableRawPointer?) {
    MlxErrorRelay.record(message.map { String(cString: $0) } ?? "unknown MLX error")
  }

  enum MlxErrors {
    /// Maps a Swift error from MLX / mlx-swift-lm / swift-transformers onto a
    /// Dart error code.
    static func classify(_ error: Error) -> (ErrorCode, String) {
      let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
      if let e = error as? ModelFactoryError {
        switch e {
        case .unsupportedModelType, .unsupportedProcessorType, .noModelFactoryAvailable:
          return (.unsupported, text)
        case .configurationFileError, .configurationDecodingError, .invalidConfiguration:
          return (.modelNotFound, text)
        @unknown default:
          return (.unknown, text)
        }
      }
      if let e = error as? MLXError, case .caught(let message) = e {
        let lower = message.lowercased()
        if lower.contains("insufficient memory") || lower.contains("out of memory") || lower.contains("outofmemory") {
          return (.outOfMemory, message)
        }
        return (.engineError, message)
      }
      if error is MLXLMCommon.TokenizerError { return (.invalidRequest, text) }
      if error is Tokenizers.TokenizerError { return (.modelNotFound, "Tokenizer files: \(text)") }
      if error is ChatSessionError { return (.invalidRequest, text) }
      if error is RejectedToolCallError { return (.invalidRequest, text) }
      if (error as NSError).domain == NSCocoaErrorDomain { return (.modelNotFound, text) }
      return (.unknown, text)
    }

    static func event(for error: Error) -> AmEvent {
      let (code, message) = classify(error)
      return AmEvent.make(.error, code: code.rawValue, message: message)
    }
  }

  // MARK: - Tokenizer (hand-written, no MLXHuggingFace macros, R06 §2.2)

  /// Loads tokenizer.json / tokenizer_config.json from the model directory
  /// with swift-transformers. `AutoTokenizer.from(modelFolder:)` reads local
  /// files only (Hub.swift `loadConfig(modelFolder:)`): MLX never touches the
  /// network; the app downloaded the files. Same bridge as mlx-swift-lm's
  /// `#huggingFaceTokenizerLoader()` macro expansion (3.32.3).
  struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
      let upstream = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
      return TransformersTokenizerBridge(upstream)
    }
  }

  struct TransformersTokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
      self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
      upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
      upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
      messages: [[String: any Sendable]], tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
      do {
        return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
      } catch Tokenizers.TokenizerError.missingChatTemplate {
        throw MLXLMCommon.TokenizerError.missingChatTemplate
      }
    }
  }

  // MARK: - Mapping Dart wire types onto mlx-swift-lm

  enum MlxWire {
    static func chatMessage(_ m: AmWireMessage) -> Chat.Message {
      switch m.role {
      case "system":
        return .system(m.content)
      case "assistant":
        let calls = m.toolCalls.map { $0.map(toolCall) }
        return .assistant(m.content, toolCalls: (calls?.isEmpty ?? true) ? nil : calls)
      case "tool":
        return .tool(m.content, id: m.toolCallId, name: m.toolName)
      default:
        return .user(m.content)
      }
    }

    static func toolCall(_ w: AmToolCallWire) -> ToolCall {
      ToolCall(function: ToolCall.Function(name: w.name, arguments: arguments(w.argumentsJson)), id: w.id)
    }

    static func arguments(_ json: String) -> [String: JSONValue] {
      guard let data = json.data(using: .utf8),
        let value = try? JSONDecoder().decode(JSONValue.self, from: data),
        case .object(let object) = value
      else { return [:] }
      return object
    }

    static func encode(_ arguments: [String: JSONValue]) -> String {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      guard let data = try? encoder.encode(arguments), let s = String(data: data, encoding: .utf8) else { return "{}" }
      return s
    }

    /// OpenAI-style tool specs from Dart, as the `[String: any Sendable]`
    /// dictionaries the chat template and the tool-call parser expect.
    static func toolSpecs(_ json: String?) throws -> [ToolSpec]? {
      guard let json = json, !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
      let value = try JSONDecoder().decode(JSONValue.self, from: data)
      guard case .array(let items) = value else {
        throw PluginError.make(.invalidRequest, "tools must be a JSON array")
      }
      return items.compactMap { sendable($0) as? [String: any Sendable] }
    }

    /// JSON → Sendable Swift values (nulls are dropped: schemas never need
    /// them and templates treat a missing key like null).
    static func sendable(_ v: JSONValue) -> (any Sendable)? {
      switch v {
      case .null: return nil
      case .bool(let b): return b
      case .int(let i): return i
      case .double(let d): return d
      case .string(let s): return s
      case .array(let a): return a.compactMap(sendable) as [any Sendable]
      case .object(let o):
        var out: [String: any Sendable] = [:]
        for (k, x) in o {
          if let s = sendable(x) { out[k] = s }
        }
        return out
      }
    }

    /// `GenerateParameters` from Dart's sampling and KV settings (unset
    /// fields keep mlx-swift-lm's defaults, R06 §2.4).
    static func parameters(_ s: AmSampling, _ kv: AmKvConfig) -> GenerateParameters {
      var p = GenerateParameters()
      if let v = s.temperature { p.temperature = Float(v) }
      if let v = s.topP { p.topP = Float(v) }
      if let v = s.topK { p.topK = Int(v) }
      if let v = s.minP { p.minP = Float(v) }
      if let v = s.repetitionPenalty { p.repetitionPenalty = Float(v) }
      if let v = s.repetitionContextSize { p.repetitionContextSize = Int(v) }
      if let v = s.presencePenalty { p.presencePenalty = Float(v) }
      if let v = s.frequencyPenalty { p.frequencyPenalty = Float(v) }
      if let v = s.maxTokens { p.maxTokens = Int(v) }
      if let v = s.seed { p.seed = UInt64(bitPattern: v) }
      if let v = kv.maxKVSize { p.maxKVSize = Int(v) }
      // Either a named scheme or the legacy bits fields, never both, and
      // never the typed `kvCache:` with them.
      if let scheme = kv.kvScheme {
        p.kvScheme = scheme
      } else if let bits = kv.kvBits {
        p.kvBits = Int(bits)
        if let g = kv.kvGroupSize { p.kvGroupSize = Int(g) }
        if let start = kv.quantizedKVStart { p.quantizedKVStart = Int(start) }
      }
      if let step = kv.prefillStepSize { p.prefill.stepSize = Int(step) }
      return p
    }

    static func additionalContext(key: String?, enabled: Bool?) -> [String: any Sendable]? {
      guard let key = key, let enabled = enabled else { return nil }
      return [key: enabled]
    }

    static func toolCallEvent(_ call: ToolCall) -> AmEvent {
      var e = AmEvent(kind: .toolCall)
      e.toolName = call.function.name
      e.argumentsJson = encode(call.function.arguments)
      e.callId = call.id
      return e
    }

    static func rejectedEvent(_ r: RejectedToolCall) -> AmEvent {
      var e = AmEvent(kind: .rejectedToolCall)
      e.code = r.reason.rawValue
      e.toolName = r.toolName
      e.callId = r.callID
      e.text = r.rawTextPreview
      e.message = r.detail
      return e
    }

    static func infoEvent(_ i: GenerateCompletionInfo) -> AmEvent {
      var e = AmEvent(kind: .info)
      e.promptTokens = Int64(i.promptTokenCount)
      e.cachedPromptTokens = Int64(i.cachedPromptTokenCount)
      e.generationTokens = Int64(i.generationTokenCount)
      e.promptTimeSec = i.promptTime
      e.generateTimeSec = i.generateTime
      e.rejectedToolCalls = Int64(i.rejectedToolCallCount)
      e.recoveredToolCalls = Int64(i.recoveredToolCallCount)
      e.proposedDraftTokens = i.proposedDraftTokens.map { Int64($0) }
      e.acceptedDraftTokens = i.acceptedDraftTokens.map { Int64($0) }
      return e
    }

    static func stopCode(_ reason: GenerateStopReason?) -> String {
      switch reason {
      case .length: return "length"
      case .cancelled: return "cancelled"
      default: return "stop"
      }
    }
  }
#endif
