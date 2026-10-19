// STAND-IN for Apple's FoundationModels framework, for type-checking on
// Linux only. Declarations transcribed from the DocC JSON at
// developer.apple.com/tutorials/data/documentation/foundationmodels/…
// (fetched 2026-10-19): SystemLanguageModel, LanguageModelSession,
// GenerationOptions, GenerationSchema, DynamicGenerationSchema(+Property),
// GenerationGuide, GeneratedContent, Tool, Transcript (+Entry, Instructions,
// Prompt, Response, ToolCalls, ToolCall, ToolOutput, TextSegment, Segment,
// ToolDefinition), LanguageModelSession.GenerationError / ToolCallError /
// Usage, LanguageModelError. Availability annotations are copied, but Linux
// ignores them, so this check cannot prove `#available` gating. Bodies are
// placeholders.
import Foundation

// MARK: Representable protocols, Generable

@available(iOS 26.0, macOS 26.0, *)
public protocol PromptRepresentable {}
@available(iOS 26.0, macOS 26.0, *)
public protocol InstructionsRepresentable {}
@available(iOS 26.0, macOS 26.0, *)
public protocol ConvertibleToGeneratedContent: PromptRepresentable, InstructionsRepresentable {}
@available(iOS 26.0, macOS 26.0, *)
public protocol ConvertibleFromGeneratedContent {}

@available(iOS 26.0, macOS 26.0, *)
public protocol Generable: ConvertibleFromGeneratedContent, ConvertibleToGeneratedContent {
  associatedtype PartiallyGenerated = Self
}

@available(iOS 26.0, macOS 26.0, *)
extension String: Generable { public typealias PartiallyGenerated = String }
@available(iOS 26.0, macOS 26.0, *)
extension Int: Generable { public typealias PartiallyGenerated = Int }
@available(iOS 26.0, macOS 26.0, *)
extension Double: Generable { public typealias PartiallyGenerated = Double }
@available(iOS 26.0, macOS 26.0, *)
extension Bool: Generable { public typealias PartiallyGenerated = Bool }

@available(iOS 26.0, macOS 26.0, *)
public struct GeneratedContent: Generable, Sendable {
  public typealias PartiallyGenerated = GeneratedContent
  public init(json: String) throws {}
  public var jsonString: String { "" }
}

// MARK: Prompt, Instructions (result builders)

@available(iOS 26.0, macOS 26.0, *)
public struct Prompt: PromptRepresentable, Sendable {
  public init(@PromptBuilder _ content: () throws -> Prompt) rethrows {}
  fileprivate init() {}
}

@available(iOS 26.0, macOS 26.0, *)
@resultBuilder
public struct PromptBuilder {
  public static func buildExpression<P: PromptRepresentable>(_ expression: P) -> P { expression }
  public static func buildBlock<each P: PromptRepresentable>(_ components: repeat each P) -> Prompt { Prompt() }
}

@available(iOS 26.0, macOS 26.0, *)
public struct Instructions: InstructionsRepresentable, Sendable {
  public init(@InstructionsBuilder _ content: () throws -> Instructions) rethrows {}
  fileprivate init() {}
}

@available(iOS 26.0, macOS 26.0, *)
@resultBuilder
public struct InstructionsBuilder {
  public static func buildExpression<I: InstructionsRepresentable>(_ expression: I) -> I { expression }
  public static func buildBlock<each I: InstructionsRepresentable>(_ components: repeat each I) -> Instructions {
    Instructions()
  }
}

// MARK: Schemas

@available(iOS 26.0, macOS 26.0, *)
public struct GenerationGuide<Value>: Sendable {}

@available(iOS 26.0, macOS 26.0, *)
extension GenerationGuide where Value == String {
  public static func anyOf(_ values: [String]) -> GenerationGuide<String> { .init() }
  public static func constant(_ value: String) -> GenerationGuide<String> { .init() }
  public static func pattern<Output>(_ regex: Regex<Output>) -> GenerationGuide<String> { .init() }
}

@available(iOS 26.0, macOS 26.0, *)
extension GenerationGuide where Value == Int {
  public static func minimum(_ value: Int) -> GenerationGuide<Int> { .init() }
  public static func maximum(_ value: Int) -> GenerationGuide<Int> { .init() }
  public static func range(_ range: ClosedRange<Int>) -> GenerationGuide<Int> { .init() }
}

@available(iOS 26.0, macOS 26.0, *)
extension GenerationGuide where Value == Double {
  public static func minimum(_ value: Double) -> GenerationGuide<Double> { .init() }
  public static func maximum(_ value: Double) -> GenerationGuide<Double> { .init() }
  public static func range(_ range: ClosedRange<Double>) -> GenerationGuide<Double> { .init() }
}

@available(iOS 26.0, macOS 26.0, *)
public struct DynamicGenerationSchema: Sendable {
  public struct Property: Sendable {
    public init(name: String, description: String? = nil, schema: DynamicGenerationSchema, isOptional: Bool = false) {}
  }

  public init(arrayOf itemSchema: DynamicGenerationSchema, minimumElements: Int? = nil, maximumElements: Int? = nil) {}
  public init(name: String, description: String? = nil, anyOf choices: [DynamicGenerationSchema]) {}
  public init(name: String, description: String? = nil, properties: [DynamicGenerationSchema.Property]) {}
  public init(referenceTo name: String) {}
  public init<Value>(type: Value.Type, guides: [GenerationGuide<Value>] = []) where Value: Generable {}
}

@available(iOS 26.0, macOS 26.0, *)
public struct GenerationSchema: Sendable {
  public enum SchemaError: Error, LocalizedError {
    public struct Context: Sendable {}
    case duplicateProperty(schema: String, property: String, context: Context)
    case duplicateType(schema: String?, type: String, context: Context)
    case emptyTypeChoices(schema: String, context: Context)
    case undefinedReferences(schema: String?, references: [String], context: Context)
  }

  public init(root: DynamicGenerationSchema, dependencies: [DynamicGenerationSchema]) throws {}
}

@available(iOS 26.0, macOS 26.0, *)
public struct GenerationOptions: Sendable {
  public struct SamplingMode: Sendable {
    public static var greedy: SamplingMode { SamplingMode() }
    public static func random(probabilityThreshold: Double, seed: UInt64? = nil) -> SamplingMode { SamplingMode() }
    public static func random(top: Int, seed: UInt64? = nil) -> SamplingMode { SamplingMode() }
  }

  public init(samplingMode: SamplingMode? = nil, temperature: Double? = nil, maximumResponseTokens: Int? = nil) {}
}

// MARK: Tool

@available(iOS 26.0, macOS 26.0, *)
public protocol Tool<Arguments, Output>: Sendable {
  associatedtype Arguments: ConvertibleFromGeneratedContent
  associatedtype Output: PromptRepresentable
  var name: String { get }
  var description: String { get }
  var parameters: GenerationSchema { get }
  var includesSchemaInInstructions: Bool { get }
  func call(arguments: Arguments) async throws -> Output
}

@available(iOS 26.0, macOS 26.0, *)
extension Tool {
  public var includesSchemaInInstructions: Bool { true }
}

// MARK: Transcript

@available(iOS 26.0, macOS 26.0, *)
public struct Transcript: Sendable {
  public enum Entry: Sendable {
    case instructions(Transcript.Instructions)
    case prompt(Transcript.Prompt)
    case response(Transcript.Response)
    case toolCalls(Transcript.ToolCalls)
    case toolOutput(Transcript.ToolOutput)
  }

  public enum Segment: Sendable {
    case text(Transcript.TextSegment)
  }

  public struct TextSegment: Sendable {
    public init(id: String = UUID().uuidString, content: String) {}
  }

  public struct ToolDefinition: Sendable {
    public init(name: String, description: String, parameters: GenerationSchema) {}
    public init(tool: some Tool) {}
  }

  public struct Instructions: Sendable {
    public init(id: String = UUID().uuidString, segments: [Transcript.Segment], toolDefinitions: [Transcript.ToolDefinition]) {}
  }

  public struct ResponseFormat: Sendable {
    public init(schema: GenerationSchema) {}
  }

  public struct Prompt: Sendable {
    public init(
      id: String = UUID().uuidString, segments: [Transcript.Segment], options: GenerationOptions = GenerationOptions(),
      responseFormat: Transcript.ResponseFormat? = nil
    ) {}
  }

  public struct Response: Sendable {
    public init(id: String = UUID().uuidString, assetIDs: [String], segments: [Transcript.Segment]) {}
  }

  public struct ToolCall: Sendable {
    public init(id: String, toolName: String, arguments: GeneratedContent) {}
  }

  public struct ToolCalls: Sendable {
    public init<S>(id: String = UUID().uuidString, _ calls: S) where S: Sequence, S.Element == Transcript.ToolCall {}
  }

  public struct ToolOutput: Sendable {
    public init(id: String, toolName: String, segments: [Transcript.Segment]) {}
  }

  public init(entries: some Sequence<Transcript.Entry> = []) {}
}

// MARK: SystemLanguageModel

@available(iOS 26.0, macOS 26.0, *)
public final class SystemLanguageModel: Sendable {
  @frozen public enum Availability: Sendable {
    public enum UnavailableReason: Sendable {
      case appleIntelligenceNotEnabled
      case deviceNotEligible
      case modelNotReady
    }

    case available
    case unavailable(UnavailableReason)
  }

  public static var `default`: SystemLanguageModel { fatalError("stand-in") }
  public var availability: Availability { .available }
  public var isAvailable: Bool { true }
  public var contextSize: Int { 4096 }
  public func supportsLocale(_ locale: Locale = Locale.current) -> Bool { true }
}

// MARK: LanguageModelSession

@available(iOS 26.0, macOS 26.0, *)
public final class LanguageModelSession {
  public enum GenerationError: Error, LocalizedError {
    public struct Context: Sendable {
      public let debugDescription: String
    }

    public struct Refusal: Sendable {}

    case assetsUnavailable(Context)
    case decodingFailure(Context)
    case exceededContextWindowSize(Context)
    case guardrailViolation(Context)
    case rateLimited(Context)
    case refusal(Refusal, Context)
    case concurrentRequests(Context)
    case unsupportedGuide(Context)
    case unsupportedLanguageOrLocale(Context)
  }

  public struct ToolCallError: Error, LocalizedError {
    public var tool: any Tool
    public var underlyingError: any Error
  }

  @available(iOS 27.0, macOS 27.0, *)
  public struct Usage: Sendable {
    public struct Input: Sendable {
      public var totalTokenCount: Int
      public var cachedTokenCount: Int
    }

    public struct Output: Sendable {
      public var totalTokenCount: Int
      public var reasoningTokenCount: Int
    }

    public var input: Input
    public var output: Output
  }

  public struct ResponseStream<Content: Generable>: AsyncSequence {
    public struct Snapshot {
      public var content: Content.PartiallyGenerated
      public var rawContent: GeneratedContent
    }

    public typealias Element = Snapshot

    public struct AsyncIterator: AsyncIteratorProtocol {
      public mutating func next() async throws -> Snapshot? { nil }
    }

    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator() }
  }

  public convenience init(
    model: SystemLanguageModel = .default, tools: [any Tool] = [],
    @InstructionsBuilder instructions: () throws -> Instructions
  ) rethrows {
    self.init(model: model, tools: tools, transcript: Transcript())
  }

  public init(model: SystemLanguageModel = .default, tools: [any Tool] = [], transcript: Transcript) {}

  public var transcript: Transcript { Transcript() }
  public var isResponding: Bool { false }

  @available(iOS 27.0, macOS 27.0, *)
  public var usage: Usage { fatalError("stand-in") }

  public func prewarm(promptPrefix: Prompt? = nil) {}

  public func streamResponse(to prompt: Prompt, options: GenerationOptions = GenerationOptions())
    -> sending ResponseStream<String>
  { ResponseStream() }

  public func streamResponse(
    to prompt: Prompt, schema: GenerationSchema, includeSchemaInPrompt: Bool = true,
    options: GenerationOptions = GenerationOptions()
  ) -> sending ResponseStream<GeneratedContent> { ResponseStream() }
}

// MARK: LanguageModelError (iOS 27)

@available(iOS 27.0, macOS 27.0, *)
public enum LanguageModelError: Error {
  public struct ContextSizeExceeded: Sendable {}
  public struct RateLimited: Sendable {}
  public struct Refusal: Sendable {}
  public struct Timeout: Sendable {}
  public struct GuardrailViolation: Sendable {}
  public struct UnsupportedCapability: Sendable {}
  public struct UnsupportedTranscriptContent: Sendable {}
  public struct UnsupportedGenerationGuide: Sendable {}
  public struct UnsupportedLanguageOrLocale: Sendable {}

  case contextSizeExceeded(ContextSizeExceeded)
  case rateLimited(RateLimited)
  case refusal(Refusal)
  case timeout(Timeout)
  case guardrailViolation(GuardrailViolation)
  case unsupportedCapability(UnsupportedCapability)
  case unsupportedTranscriptContent(UnsupportedTranscriptContent)
  case unsupportedGenerationGuide(UnsupportedGenerationGuide)
  case unsupportedLanguageOrLocale(UnsupportedLanguageOrLocale)
}
