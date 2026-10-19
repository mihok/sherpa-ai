// STAND-IN for mlx-swift-lm 3.32.3 `MLXLMCommon`, for type-checking on
// Linux only. Every declaration below mirrors the public API at tag 3.32.3
// (commit 3b339ad): ChatSession.swift, Chat.swift, Evaluate.swift,
// ModelContainer.swift, ModelFactory.swift, ModelConfiguration.swift,
// ReasoningConfig.swift, Tokenizer.swift, TokenizerLoader.swift,
// KVCache.swift, UserInput.swift, LanguageModel.swift, Tool/*.swift.
// Only what the plugin touches is declared; initializers keep the real
// parameter order and defaults. Bodies are placeholders.
import Foundation
import MLX

// MARK: Tool/Tool.swift, Tool/ToolCall.swift, Tool/Value.swift

public typealias ToolSpec = [String: any Sendable]

public enum JSONValue: Hashable, Codable, Sendable {
  case null
  case bool(Bool)
  case int(Int)
  case double(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])
}

public struct ToolCall: Hashable, Codable, Sendable {
  public struct Function: Hashable, Codable, Sendable {
    public let name: String
    public let arguments: [String: JSONValue]
    public init(name: String, arguments: [String: JSONValue]) {
      self.name = name
      self.arguments = arguments
    }
  }

  public let function: Function
  public let id: String?

  public init(function: Function, id: String? = nil) {
    self.function = function
    self.id = id
  }
}

public enum ToolCallFormat: String, Hashable, Sendable, Codable, CaseIterable {
  case json, lfm2
  case xmlFunction = "xml_function"
  case qwen35 = "qwen3_5"
  case glm4, gemma, gemma4
  case kimiK2 = "kimi_k2"
  case minimaxM2 = "minimax_m2"
  case atem, mistral, llama3
  case gptOSS = "gpt_oss"
}

public struct RejectedToolCall: Hashable, Codable, Sendable {
  public enum Reason: String, Hashable, Codable, Sendable, CaseIterable {
    case malformedSyntax = "malformed_syntax"
    case incompleteOutput = "incomplete_output"
    case missingToolName = "missing_tool_name"
    case undeclaredTool = "undeclared_tool"
    case invalidArguments = "invalid_arguments"
    case resourceLimitExceeded = "resource_limit_exceeded"
  }

  public let reason: Reason
  public let format: ToolCallFormat
  public let toolName: String?
  public let callID: String?
  public let rawTextPreview: String
  public let rawTextByteCount: Int
  public let isPreviewTruncated: Bool
  public let detail: String?
}

public struct RejectedToolCallError: Error, Hashable, Sendable, LocalizedError {
  public let rejection: RejectedToolCall
}

public enum ToolCallRecoveryPolicy: String, Hashable, Sendable, CaseIterable { case disabled, conservative, permissive }
public enum ToolCallValidationPolicy: String, Hashable, Sendable, CaseIterable { case strict, permissive }

public struct ToolCallPolicy: Hashable, Sendable {
  public var recovery: ToolCallRecoveryPolicy
  public var validation: ToolCallValidationPolicy
  public init(recovery: ToolCallRecoveryPolicy = .conservative, validation: ToolCallValidationPolicy = .permissive) {
    self.recovery = recovery
    self.validation = validation
  }
}

// MARK: Chat.swift

public enum Chat {
  public struct Message {
    public enum Role: String, Sendable { case user, assistant, system, tool }

    public struct Tool: Sendable {}

    public var role: Role
    public var content: String
    public var tool: Tool?

    public init(role: Role, content: String, tool: Tool? = nil) {
      self.role = role
      self.content = content
      self.tool = tool
    }

    public static func system(_ content: String) -> Self { Self(role: .system, content: content) }
    public static func assistant(_ content: String, toolCalls: [ToolCall]? = nil) -> Self {
      Self(role: .assistant, content: content)
    }
    public static func user(_ content: String) -> Self { Self(role: .user, content: content) }
    public static func tool(_ content: String, id: String? = nil, name: String? = nil) -> Self {
      Self(role: .tool, content: content)
    }
  }
}

// MARK: Tokenizer.swift, TokenizerLoader.swift

public protocol Tokenizer: Sendable {
  func encode(text: String, addSpecialTokens: Bool) -> [Int]
  func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String
  func convertTokenToId(_ token: String) -> Int?
  func convertIdToToken(_ id: Int) -> String?
  var bosToken: String? { get }
  var eosToken: String? { get }
  var unknownToken: String? { get }
  func applyChatTemplate(
    messages: [[String: any Sendable]], tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?
  ) throws -> [Int]
}

extension Tokenizer {
  public func encode(text: String) -> [Int] { encode(text: text, addSpecialTokens: true) }
}

public enum TokenizerError: LocalizedError {
  case missingChatTemplate
}

public protocol TokenizerLoader: Sendable {
  func load(from directory: URL) async throws -> any Tokenizer
}

// MARK: ReasoningConfig.swift, ModelConfiguration.swift

public enum ReasoningPromptStrategy: Sendable, Equatable {
  case templateFlag(key: String, defaultOn: Bool)
  case alwaysOn
  case none
}

public struct ReasoningConfig: Sendable, Equatable {
  public var startDelimiter: String
  public var endDelimiter: String
  public var promptStrategy: ReasoningPromptStrategy
  public var implicitEndDelimiters: [String]
  public var isSpecialToken: Bool
}

public struct ModelConfiguration: Sendable {
  public var toolCallFormat: ToolCallFormat?
  public var reasoningConfig: ReasoningConfig? = nil
  public var extraEOSTokens: Set<String> = []
  public init(directory: URL) {}
}

public enum ModelFactoryError: LocalizedError {
  case unsupportedModelType(String)
  case unsupportedProcessorType(String)
  case configurationFileError(String, String, Error)
  case configurationDecodingError(String, String, DecodingError)
  case invalidConfiguration(String)
  case noModelFactoryAvailable
}

// MARK: LanguageModel.swift, UserInput.swift

public struct LMOutput {
  public struct State: Sendable {}
}

public protocol LanguageModel {}

public struct LMInput {
  public struct Text {
    public let tokens: MLXArray
    public let mask: MLXArray?
    public init(tokens: MLXArray, mask: MLXArray? = nil) {
      self.tokens = tokens
      self.mask = mask
    }
  }

  public let text: Text
  public init(tokens: MLXArray, mask: MLXArray? = nil) { text = Text(tokens: tokens, mask: mask) }
}

public struct UserInput {
  public struct Processing: Sendable {
    public init(resize: CGSize? = nil) {}
  }

  public init(
    chat: [Chat.Message], processing: Processing = .init(), tools: [ToolSpec]? = nil,
    additionalContext: [String: any Sendable]? = nil
  ) {}
}

public protocol UserInputProcessor: Sendable {
  func prepare(input: UserInput) async throws -> LMInput
}

// MARK: KVCache.swift

public protocol KVCache {}

public struct PromptCacheSnapshot {
  public let cache: [KVCache]
  public let metadata: [String: String]
  public let state: LMOutput.State?
}

public func loadPromptCacheSnapshot(url: URL) throws -> PromptCacheSnapshot { fatalError("stand-in") }

public func savePromptCache(
  url: URL, cache: [KVCache], metadata: [String: String] = [:], state: LMOutput.State? = nil
) throws {}

// MARK: Evaluate.swift

public struct PrefillParameters: Sendable {
  public var stepSize: Int?
  public init(stepSize: Int? = nil) { self.stepSize = stepSize }
}

public struct GenerateParameters: Sendable {
  public var prefill: PrefillParameters
  public var maxTokens: Int?
  public var maxKVSize: Int?
  public var kvBits: Int?
  public var kvGroupSize: Int
  public var quantizedKVStart: Int
  public var kvScheme: String?
  public var temperature: Float
  public var topP: Float
  public var topK: Int
  public var minP: Float
  public var seed: UInt64?
  public var repetitionPenalty: Float?
  public var repetitionContextSize: Int
  public var presencePenalty: Float?
  public var presenceContextSize: Int
  public var frequencyPenalty: Float?
  public var frequencyContextSize: Int
  public var toolCallPolicy: ToolCallPolicy

  public init(
    maxTokens: Int? = nil, maxKVSize: Int? = nil, kvBits: Int? = nil, kvGroupSize: Int = 64,
    quantizedKVStart: Int = 0, kvScheme: String? = nil, temperature: Float = 0.6, topP: Float = 1.0, topK: Int = 0,
    minP: Float = 0.0, repetitionPenalty: Float? = nil, repetitionContextSize: Int = 20,
    presencePenalty: Float? = nil, presenceContextSize: Int = 20, frequencyPenalty: Float? = nil,
    frequencyContextSize: Int = 20, prefill: PrefillParameters = .init(), seed: UInt64? = nil,
    toolCallPolicy: ToolCallPolicy = .init()
  ) {
    self.maxTokens = maxTokens
    self.maxKVSize = maxKVSize
    self.kvBits = kvBits
    self.kvGroupSize = kvGroupSize
    self.quantizedKVStart = quantizedKVStart
    self.kvScheme = kvScheme
    self.temperature = temperature
    self.topP = topP
    self.topK = topK
    self.minP = minP
    self.repetitionPenalty = repetitionPenalty
    self.repetitionContextSize = repetitionContextSize
    self.presencePenalty = presencePenalty
    self.presenceContextSize = presenceContextSize
    self.frequencyPenalty = frequencyPenalty
    self.frequencyContextSize = frequencyContextSize
    self.prefill = prefill
    self.seed = seed
    self.toolCallPolicy = toolCallPolicy
  }
}

public enum GenerateStopReason: Sendable {
  case stop, length, cancelled
}

public struct GenerateCompletionInfo: Sendable {
  public let promptTokenCount: Int
  public internal(set) var cachedPromptTokenCount: Int
  public let generationTokenCount: Int
  public let promptTime: TimeInterval
  public let generateTime: TimeInterval
  public let stopReason: GenerateStopReason
  public let proposedDraftTokens: Int?
  public let acceptedDraftTokens: Int?
  public let rejectedToolCallCount: Int
  public let recoveredToolCallCount: Int
}

public enum Generation: Sendable {
  case chunk(String)
  case info(GenerateCompletionInfo)
  case toolCall(ToolCall)
  case rejectedToolCall(RejectedToolCall)
}

public struct SpeculativeDecodingTelemetry: Sendable {}

public protocol TokenIteratorProtocol: Sequence, IteratorProtocol where Element == Int {}

public struct TokenIterator: TokenIteratorProtocol {
  public init(
    input: LMInput, model: any LanguageModel, cache: [KVCache]? = nil, state: LMOutput.State? = nil,
    parameters: GenerateParameters, components: GenerationComponents = .init()
  ) throws {}
  public mutating func next() -> Int? { nil }
}

public struct GenerationComponents: Sendable {
  public init() {}
}

public struct SpeculativeDecodingConfig: Sendable {}

public func generateTask<TOKEN: TokenIteratorProtocol>(
  promptTokenCount: Int, modelConfiguration: ModelConfiguration, tokenizer: Tokenizer, iterator: consuming TOKEN,
  wiredMemoryTicket: WiredMemoryTicket? = nil, tools: [[String: any Sendable]]? = nil,
  toolCallPolicy: ToolCallPolicy = .init()
) -> (AsyncStream<Generation>, Task<Void, Never>) {
  fatalError("stand-in")
}

public struct WiredMemoryTicket: Sendable {}

// MARK: ModelFactory.swift, ModelContainer.swift

public struct ModelContext {
  public var configuration: ModelConfiguration
  public var model: any LanguageModel
  public var processor: any UserInputProcessor
  public var tokenizer: Tokenizer
}

public final class ModelContainer: Sendable {
  public var configuration: ModelConfiguration { get async { fatalError("stand-in") } }
  public var processor: UserInputProcessor { get async { fatalError("stand-in") } }
  public var tokenizer: Tokenizer { get async { fatalError("stand-in") } }

  public func perform<R: Sendable>(_ action: @Sendable (ModelContext) async throws -> sending R) async rethrows
    -> sending R
  { fatalError("stand-in") }

  public func perform<V, R: Sendable>(
    nonSendable values: consuming V, _ action: @Sendable (ModelContext, V) async throws -> R
  ) async rethrows -> sending R { fatalError("stand-in") }

  public func prepare(input: consuming sending UserInput) async throws -> sending LMInput { fatalError("stand-in") }

  public func generate(
    input: consuming sending LMInput, parameters: GenerateParameters, wiredMemoryTicket: WiredMemoryTicket? = nil,
    tools: [[String: any Sendable]]? = nil
  ) async throws -> AsyncStream<Generation> { fatalError("stand-in") }

  public func encode(_ text: String) async -> [Int] { [] }
  public func decode(tokenIds: [Int]) async -> String { "" }
}

// MARK: ChatSession.swift

public final class ChatSession {
  public var instructions: String?
  public var generateParameters: GenerateParameters
  public var additionalContext: [String: any Sendable]?
  public var tools: [ToolSpec]?
  public var toolDispatch: (@Sendable (ToolCall) async throws -> String)?

  public init(
    _ model: ModelContainer, instructions: String? = nil, speculativeDecoding: SpeculativeDecodingConfig? = nil,
    generateParameters: GenerateParameters = .init(), components: GenerationComponents = .init(),
    processing: UserInput.Processing = .init(resize: CGSize(width: 512, height: 512)),
    additionalContext: [String: any Sendable]? = nil, tools: [ToolSpec]? = nil,
    toolDispatch: (@Sendable (ToolCall) async throws -> String)? = nil
  ) {
    self.instructions = instructions
    self.generateParameters = generateParameters
    self.additionalContext = additionalContext
    self.tools = tools
    self.toolDispatch = toolDispatch
  }

  public init(
    _ model: ModelContainer, instructions: String? = nil, history: consuming [Chat.Message],
    speculativeDecoding: SpeculativeDecodingConfig? = nil, generateParameters: GenerateParameters = .init(),
    components: GenerationComponents = .init(),
    processing: UserInput.Processing = .init(resize: CGSize(width: 512, height: 512)),
    additionalContext: [String: any Sendable]? = nil, tools: [ToolSpec]? = nil,
    toolDispatch: (@Sendable (ToolCall) async throws -> String)? = nil
  ) {
    self.instructions = instructions
    self.generateParameters = generateParameters
    self.additionalContext = additionalContext
    self.tools = tools
    self.toolDispatch = toolDispatch
  }

  public convenience init(
    _ model: ModelContainer, instructions: String? = nil, promptCache: consuming PromptCacheSnapshot,
    speculativeDecoding: SpeculativeDecodingConfig? = nil, generateParameters: GenerateParameters = .init(),
    components: GenerationComponents = .init(),
    processing: UserInput.Processing = .init(resize: CGSize(width: 512, height: 512)),
    additionalContext: [String: any Sendable]? = nil, tools: [ToolSpec]? = nil,
    toolDispatch: (@Sendable (ToolCall) async throws -> String)? = nil
  ) {
    self.init(
      model, instructions: instructions, speculativeDecoding: speculativeDecoding,
      generateParameters: generateParameters, components: components, processing: processing,
      additionalContext: additionalContext, tools: tools, toolDispatch: toolDispatch)
  }

  public func streamDetails(to messages: consuming [Chat.Message]) -> AsyncThrowingStream<Generation, Error> {
    fatalError("stand-in")
  }

  public func clear() async {}
  public func synchronize() async {}
  public func saveCache(to url: URL) async throws {}
}

public enum ChatSessionError: LocalizedError {
  case noCacheAvailable
  case emptyPreparedInput
}
