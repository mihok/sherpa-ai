// STAND-IN for Apple's FoundationModels framework, for type-checking on
// Linux only. Bodies are placeholders.
//
// What it models: the iOS 26.5 SDK (iphoneos26.5) of Xcode 26.6, the default
// Xcode of CI's `macos-latest` image (macOS 26 arm64, image 20261013.0424.1,
// https://raw.githubusercontent.com/actions/runner-images/main/images/macos/macos-26-arm64-Readme.md).
// Linux ignores `@available(iOS …)`, so a symbol declared here is always
// usable; symbols that DocC lists as iOS 27.0 (or `@backDeployed(before:
// iOS 27.0)`) are therefore LEFT OUT, so that using one fails here as it does
// in Xcode 26.6 ("cannot find type … in scope"), even behind `#available`.
//
// Every declaration cites its DocC JSON page, re-fetched 2026-10-19:
// https://developer.apple.com/tutorials/data/documentation/foundationmodels/<path>.json
// (`DocC <path>` below). DocC renders the CURRENT (iOS 27) SDK; a declaration
// is copied only when its page says "introducedAt 26.x".
//
// Deliberately absent (iOS 27.0 SDK only):
// * LanguageModelSession.usage / LanguageModelSession.Usage
//   (DocC languagemodelsession/usage-swift.property, …/usage-swift.struct)
// * LanguageModelError (DocC languagemodelerror)
// * LanguageModelSession.Error (DocC languagemodelsession/error)
// * SystemLanguageModel.Error (DocC systemlanguagemodel/error)
// * GeneratedContent.ParsingError (DocC generatedcontent/parsingerror)
// * GenerationOptions.init(samplingMode:temperature:maximumResponseTokens:),
//   `@backDeployed(before: iOS 27.0)` (DocC
//   generationoptions/init(samplingmode:temperature:maximumresponsetokens:));
//   CI's Xcode 26.6 rejected it: "expected 'sampling:temperature:…'".
import Foundation

// MARK: Representable protocols, Generable

// DocC promptrepresentable: `protocol PromptRepresentable` (iOS 26.0)
@available(iOS 26.0, macOS 26.0, *)
public protocol PromptRepresentable {}
// DocC instructionsrepresentable: `protocol InstructionsRepresentable` (iOS 26.0)
@available(iOS 26.0, macOS 26.0, *)
public protocol InstructionsRepresentable {}
// DocC convertibletogeneratedcontent:
// `protocol ConvertibleToGeneratedContent : InstructionsRepresentable, PromptRepresentable` (iOS 26.0)
@available(iOS 26.0, macOS 26.0, *)
public protocol ConvertibleToGeneratedContent: PromptRepresentable, InstructionsRepresentable {}
// DocC convertiblefromgeneratedcontent:
// `protocol ConvertibleFromGeneratedContent : SendableMetatype` (iOS 26.0)
@available(iOS 26.0, macOS 26.0, *)
public protocol ConvertibleFromGeneratedContent: SendableMetatype {}

// DocC generable: `protocol Generable : ConvertibleFromGeneratedContent, ConvertibleToGeneratedContent` (iOS 26.0)
// DocC generable/partiallygenerated:
// `associatedtype PartiallyGenerated : ConvertibleFromGeneratedContent = Self` (iOS 26.0)
@available(iOS 26.0, macOS 26.0, *)
public protocol Generable: ConvertibleFromGeneratedContent, ConvertibleToGeneratedContent {
  associatedtype PartiallyGenerated: ConvertibleFromGeneratedContent = Self
}

// String/Int/Double/Bool: Generable (FoundationModels extensions on the
// standard types, iOS 26.0; used by DynamicGenerationSchema(type:guides:)).
@available(iOS 26.0, macOS 26.0, *)
extension String: Generable { public typealias PartiallyGenerated = String }
@available(iOS 26.0, macOS 26.0, *)
extension Int: Generable { public typealias PartiallyGenerated = Int }
@available(iOS 26.0, macOS 26.0, *)
extension Double: Generable { public typealias PartiallyGenerated = Double }
@available(iOS 26.0, macOS 26.0, *)
extension Bool: Generable { public typealias PartiallyGenerated = Bool }

// DocC generatedcontent: `struct GeneratedContent` (iOS 26.0), conforms to
// Generable, Sendable, Equatable, CustomDebugStringConvertible.
@available(iOS 26.0, macOS 26.0, *)
public struct GeneratedContent: Generable, Sendable {
  public typealias PartiallyGenerated = GeneratedContent
  // DocC generatedcontent/init(json:): `init(json: String) throws` (iOS 26.0)
  public init(json: String) throws {}
  // DocC generatedcontent/jsonstring: `var jsonString: String { get }` (iOS 26.0)
  public var jsonString: String { "" }
}

// MARK: Prompt, Instructions (result builders)

// DocC prompt: `struct Prompt` (iOS 26.0)
@available(iOS 26.0, macOS 26.0, *)
public struct Prompt: PromptRepresentable, Sendable {
  // DocC prompt/init(_:): `init(@PromptBuilder _ content: () throws -> Prompt) rethrows` (iOS 26.0)
  public init(@PromptBuilder _ content: () throws -> Prompt) rethrows {}
  fileprivate init() {}
}

// DocC promptbuilder: `@resultBuilder struct PromptBuilder` (iOS 26.0).
// The builder methods are a simplification (not transcribed).
@available(iOS 26.0, macOS 26.0, *)
@resultBuilder
public struct PromptBuilder {
  public static func buildExpression<P: PromptRepresentable>(_ expression: P) -> P { expression }
  public static func buildBlock<each P: PromptRepresentable>(_ components: repeat each P) -> Prompt { Prompt() }
}

// DocC instructions: `struct Instructions` (iOS 26.0)
@available(iOS 26.0, macOS 26.0, *)
public struct Instructions: InstructionsRepresentable, Sendable {
  // DocC instructions/init(_:):
  // `init(@InstructionsBuilder _ content: () throws -> Instructions) rethrows` (iOS 26.0)
  public init(@InstructionsBuilder _ content: () throws -> Instructions) rethrows {}
  fileprivate init() {}
}

// DocC instructionsbuilder: `@resultBuilder struct InstructionsBuilder` (iOS 26.0).
// The builder methods are a simplification (not transcribed).
@available(iOS 26.0, macOS 26.0, *)
@resultBuilder
public struct InstructionsBuilder {
  public static func buildExpression<I: InstructionsRepresentable>(_ expression: I) -> I { expression }
  public static func buildBlock<each I: InstructionsRepresentable>(_ components: repeat each I) -> Instructions {
    Instructions()
  }
}

// MARK: Schemas

// DocC generationguide: `struct GenerationGuide<Value>` (iOS 26.0)
@available(iOS 26.0, macOS 26.0, *)
public struct GenerationGuide<Value>: Sendable {}

@available(iOS 26.0, macOS 26.0, *)
extension GenerationGuide where Value == String {
  // DocC generationguide/anyof(_:): `static func anyOf(_ values: [String]) -> GenerationGuide<String>` (iOS 26.0)
  public static func anyOf(_ values: [String]) -> GenerationGuide<String> { .init() }
  // DocC generationguide/constant(_:): `static func constant(_ value: String) -> GenerationGuide<String>` (iOS 26.0)
  public static func constant(_ value: String) -> GenerationGuide<String> { .init() }
  // DocC generationguide/pattern(_:):
  // `static func pattern<Output>(_ regex: Regex<Output>) -> GenerationGuide<String>` (iOS 26.0)
  public static func pattern<Output>(_ regex: Regex<Output>) -> GenerationGuide<String> { .init() }
}

// Int overloads: DocC generationguide/minimum(_:), maximum(_:), range(_:)
// overload groups, entries minimum(_:)-8k9gn, maximum(_:)-39jvl,
// range(_:)-1es6b ("Available when Value is Int", iOS 26.0).
@available(iOS 26.0, macOS 26.0, *)
extension GenerationGuide where Value == Int {
  public static func minimum(_ value: Int) -> GenerationGuide<Int> { .init() }
  public static func maximum(_ value: Int) -> GenerationGuide<Int> { .init() }
  public static func range(_ range: ClosedRange<Int>) -> GenerationGuide<Int> { .init() }
}

// Double overloads: same pages, entries minimum(_:)-91a2b, maximum(_:)-381t8,
// range(_:)-6i6y6 ("Available when Value is Double", iOS 26.0).
@available(iOS 26.0, macOS 26.0, *)
extension GenerationGuide where Value == Double {
  public static func minimum(_ value: Double) -> GenerationGuide<Double> { .init() }
  public static func maximum(_ value: Double) -> GenerationGuide<Double> { .init() }
  public static func range(_ range: ClosedRange<Double>) -> GenerationGuide<Double> { .init() }
}

// DocC dynamicgenerationschema: `struct DynamicGenerationSchema` (iOS 26.0)
@available(iOS 26.0, macOS 26.0, *)
public struct DynamicGenerationSchema: Sendable {
  // DocC dynamicgenerationschema/property: `struct Property` (iOS 26.0)
  public struct Property: Sendable {
    // DocC dynamicgenerationschema/property/init(name:description:schema:isoptional:):
    // `init(name: String, description: String? = nil, schema: DynamicGenerationSchema, isOptional: Bool = false)`
    public init(name: String, description: String? = nil, schema: DynamicGenerationSchema, isOptional: Bool = false) {}
  }

  // DocC dynamicgenerationschema/init(arrayof:minimumelements:maximumelements:):
  // `init(arrayOf itemSchema: DynamicGenerationSchema, minimumElements: Int? = nil, maximumElements: Int? = nil)`
  public init(arrayOf itemSchema: DynamicGenerationSchema, minimumElements: Int? = nil, maximumElements: Int? = nil) {}
  // DocC dynamicgenerationschema/init(name:description:anyof:):
  // `init(name: String, description: String? = nil, anyOf choices: [DynamicGenerationSchema])`
  public init(name: String, description: String? = nil, anyOf choices: [DynamicGenerationSchema]) {}
  // DocC dynamicgenerationschema/init(name:description:properties:):
  // `init(name: String, description: String? = nil, properties: [DynamicGenerationSchema.Property])`
  public init(name: String, description: String? = nil, properties: [DynamicGenerationSchema.Property]) {}
  // DocC dynamicgenerationschema/init(referenceto:): `init(referenceTo name: String)`
  public init(referenceTo name: String) {}
  // DocC dynamicgenerationschema/init(type:guides:):
  // `init<Value>(type: Value.Type, guides: [GenerationGuide<Value>] = []) where Value : Generable`
  public init<Value>(type: Value.Type, guides: [GenerationGuide<Value>] = []) where Value: Generable {}
}

// DocC generationschema: `struct GenerationSchema` (iOS 26.0)
@available(iOS 26.0, macOS 26.0, *)
public struct GenerationSchema: Sendable {
  // DocC generationschema/schemaerror: `@nonexhaustive enum SchemaError` (iOS 26.0),
  // conforms to Error, LocalizedError, Sendable. Cases are not transcribed
  // (the plugin only tests `is GenerationSchema.SchemaError`).
  public enum SchemaError: Error, LocalizedError {
    public struct Context: Sendable {}
    case duplicateProperty(schema: String, property: String, context: Context)
    case duplicateType(schema: String?, type: String, context: Context)
    case emptyTypeChoices(schema: String, context: Context)
    case undefinedReferences(schema: String?, references: [String], context: Context)
  }

  // DocC generationschema/init(root:dependencies:):
  // `init(root: DynamicGenerationSchema, dependencies: [DynamicGenerationSchema]) throws` (iOS 26.0)
  public init(root: DynamicGenerationSchema, dependencies: [DynamicGenerationSchema]) throws {}
}

// DocC generationoptions: `struct GenerationOptions` (iOS 26.0), conforms to Equatable, Sendable.
@available(iOS 26.0, macOS 26.0, *)
public struct GenerationOptions: Sendable {
  // DocC generationoptions/samplingmode-swift.struct: `struct SamplingMode` (iOS 26.0)
  public struct SamplingMode: Sendable {
    // DocC generationoptions/samplingmode-swift.struct/greedy:
    // `static var greedy: GenerationOptions.SamplingMode { get }` (iOS 26.0)
    public static var greedy: SamplingMode { SamplingMode() }
    // DocC generationoptions/samplingmode-swift.struct/random(probabilitythreshold:seed:):
    // `static func random(probabilityThreshold: Double, seed: UInt64? = nil) -> GenerationOptions.SamplingMode`
    public static func random(probabilityThreshold: Double, seed: UInt64? = nil) -> SamplingMode { SamplingMode() }
    // DocC generationoptions/samplingmode-swift.struct/random(top:seed:):
    // `static func random(top k: Int, seed: UInt64? = nil) -> GenerationOptions.SamplingMode`
    public static func random(top k: Int, seed: UInt64? = nil) -> SamplingMode { SamplingMode() }
  }

  // DocC generationoptions/init(sampling:temperature:maximumresponsetokens:) (iOS 26.0):
  // `init(sampling: GenerationOptions.SamplingMode?, temperature: Double? = nil, maximumResponseTokens: Int? = nil)`.
  // The page (iOS 27 SDK) shows no default for `sampling`; there the
  // all-defaults `GenerationOptions()` is the iOS 27 `init(samplingMode:…)`.
  // The iOS 26.0 declarations below use `= GenerationOptions()` as a default
  // argument, and this is the only iOS 26 initializer, so in the 26 SDK it
  // must default `sampling` too (INFERRED; the plugin always passes it).
  public init(sampling: SamplingMode? = nil, temperature: Double? = nil, maximumResponseTokens: Int? = nil) {}
}

// MARK: Tool

// DocC tool: `protocol Tool<Arguments, Output> : Sendable` (iOS 26.0)
@available(iOS 26.0, macOS 26.0, *)
public protocol Tool<Arguments, Output>: Sendable {
  associatedtype Arguments: ConvertibleFromGeneratedContent
  associatedtype Output: PromptRepresentable
  // DocC tool/name: `var name: String { get }` (iOS 26.0)
  var name: String { get }
  // DocC tool/description: `var description: String { get }` (iOS 26.0)
  var description: String { get }
  // DocC tool/parameters: `var parameters: GenerationSchema { get }` (iOS 26.0)
  var parameters: GenerationSchema { get }
  // DocC tool/includesschemaininstructions: `var includesSchemaInInstructions: Bool { get }` (iOS 26.0)
  var includesSchemaInInstructions: Bool { get }
  // DocC tool/call(arguments:):
  // `@concurrent func call(arguments: Self.Arguments) async throws -> Self.Output` (iOS 26.0)
  @concurrent func call(arguments: Arguments) async throws -> Output
}

@available(iOS 26.0, macOS 26.0, *)
extension Tool {
  public var includesSchemaInInstructions: Bool { true }
}

// MARK: Transcript

// DocC transcript: `struct Transcript` (iOS 26.0), conforms to Sendable,
// RandomAccessCollection, Codable, Equatable (collection API not transcribed).
@available(iOS 26.0, macOS 26.0, *)
public struct Transcript: Sendable {
  // DocC transcript/entry: `@nonexhaustive enum Entry` (iOS 26.0)
  public enum Entry: Sendable {
    case instructions(Transcript.Instructions)
    case prompt(Transcript.Prompt)
    case response(Transcript.Response)
    case toolCalls(Transcript.ToolCalls)
    case toolOutput(Transcript.ToolOutput)
  }

  // DocC transcript/segment: `@nonexhaustive enum Segment` (iOS 26.0)
  public enum Segment: Sendable {
    case text(Transcript.TextSegment)
  }

  // DocC transcript/textsegment: `struct TextSegment` (iOS 26.0)
  public struct TextSegment: Sendable {
    // DocC transcript/textsegment/init(id:content:): `init(id: String = UUID().uuidString, content: String)`
    public init(id: String = UUID().uuidString, content: String) {}
  }

  // DocC transcript/tooldefinition: `struct ToolDefinition` (iOS 26.0)
  public struct ToolDefinition: Sendable {
    // DocC transcript/tooldefinition/init(name:description:parameters:):
    // `init(name: String, description: String, parameters: GenerationSchema)`
    public init(name: String, description: String, parameters: GenerationSchema) {}
    // DocC transcript/tooldefinition/init(tool:): `init(tool: some Tool)`
    public init(tool: some Tool) {}
  }

  // DocC transcript/instructions: `struct Instructions` (iOS 26.0)
  public struct Instructions: Sendable {
    // DocC transcript/instructions/init(id:segments:tooldefinitions:):
    // `init(id: String = UUID().uuidString, segments: [Transcript.Segment], toolDefinitions: [Transcript.ToolDefinition])`
    public init(id: String = UUID().uuidString, segments: [Transcript.Segment], toolDefinitions: [Transcript.ToolDefinition]) {}
  }

  // DocC transcript/responseformat: `struct ResponseFormat` (iOS 26.0)
  public struct ResponseFormat: Sendable {
    // DocC transcript/responseformat/init(schema:): `init(schema: GenerationSchema)`
    public init(schema: GenerationSchema) {}
  }

  // DocC transcript/prompt: `struct Prompt` (iOS 26.0)
  public struct Prompt: Sendable {
    // DocC transcript/prompt/init(id:segments:options:responseformat:):
    // `init(id: String = UUID().uuidString, segments: [Transcript.Segment],
    //  options: GenerationOptions = GenerationOptions(), responseFormat: Transcript.ResponseFormat? = nil)`
    public init(
      id: String = UUID().uuidString, segments: [Transcript.Segment], options: GenerationOptions = GenerationOptions(),
      responseFormat: Transcript.ResponseFormat? = nil
    ) {}
  }

  // DocC transcript/response: `struct Response` (iOS 26.0)
  public struct Response: Sendable {
    // DocC transcript/response/init(id:assetids:segments:):
    // `init(id: String = UUID().uuidString, assetIDs: [String], segments: [Transcript.Segment])`
    public init(id: String = UUID().uuidString, assetIDs: [String], segments: [Transcript.Segment]) {}
  }

  // DocC transcript/toolcall: `struct ToolCall` (iOS 26.0)
  public struct ToolCall: Sendable {
    // DocC transcript/toolcall/init(id:toolname:arguments:):
    // `init(id: String, toolName: String, arguments: GeneratedContent)`
    public init(id: String, toolName: String, arguments: GeneratedContent) {}
  }

  // DocC transcript/toolcalls: `struct ToolCalls` (iOS 26.0)
  public struct ToolCalls: Sendable {
    // DocC transcript/toolcalls/init(id:_:):
    // `init<S>(id: String = UUID().uuidString, _ calls: S) where S : Sequence, S.Element == Transcript.ToolCall`
    public init<S>(id: String = UUID().uuidString, _ calls: S) where S: Sequence, S.Element == Transcript.ToolCall {}
  }

  // DocC transcript/tooloutput: `struct ToolOutput` (iOS 26.0)
  public struct ToolOutput: Sendable {
    // DocC transcript/tooloutput/init(id:toolname:segments:):
    // `init(id: String, toolName: String, segments: [Transcript.Segment])`
    public init(id: String, toolName: String, segments: [Transcript.Segment]) {}
  }

  // DocC transcript/init(entries:): `init(entries: some Sequence<Transcript.Entry> = [])` (iOS 26.0)
  public init(entries: some Sequence<Transcript.Entry> = []) {}
}

// MARK: SystemLanguageModel

// DocC systemlanguagemodel: `final class SystemLanguageModel` (iOS 26.0), conforms to Sendable, Observable.
@available(iOS 26.0, macOS 26.0, *)
public final class SystemLanguageModel: Sendable {
  // DocC systemlanguagemodel/availability-swift.enum: `@frozen enum Availability` (iOS 26.0)
  @frozen public enum Availability: Sendable {
    // DocC systemlanguagemodel/availability-swift.enum/unavailablereason: `enum UnavailableReason` (iOS 26.0)
    public enum UnavailableReason: Sendable {
      case appleIntelligenceNotEnabled
      case deviceNotEligible
      case modelNotReady
    }

    case available
    case unavailable(UnavailableReason)
  }

  // DocC systemlanguagemodel/default: `static var `default`: SystemLanguageModel { get }` (iOS 26.0)
  public static var `default`: SystemLanguageModel { fatalError("stand-in") }
  // DocC systemlanguagemodel/availability-swift.property:
  // `final var availability: SystemLanguageModel.Availability { get }` (iOS 26.0)
  public var availability: Availability { .available }
  // DocC systemlanguagemodel/isavailable: `final var isAvailable: Bool { get }` (iOS 26.0)
  public var isAvailable: Bool { true }
  // DocC systemlanguagemodel/contextsize:
  // `@backDeployed(before: iOS 26.4, macOS 26.4, visionOS 26.4) final var contextSize: Int { get }`
  // (iOS 26.0; in the iOS 26.5 SDK).
  public var contextSize: Int { 4096 }
  // DocC systemlanguagemodel/supportslocale(_:):
  // `final func supportsLocale(_ locale: Locale = Locale.current) -> Bool` (iOS 26.0)
  public func supportsLocale(_ locale: Locale = Locale.current) -> Bool { true }
}

// MARK: LanguageModelSession

// DocC languagemodelsession: `final class LanguageModelSession` (iOS 26.0), conforms to Sendable, Observable.
@available(iOS 26.0, macOS 26.0, *)
public final class LanguageModelSession: Sendable {
  // DocC languagemodelsession/generationerror: `enum GenerationError` (iOS 26.0,
  // deprecated 27.0: not deprecated in the 26.5 SDK), conforms to Error,
  // LocalizedError, Sendable. Topics list the nine cases below
  // (assetsUnavailable(_:) … refusal(_:_:) … unsupportedLanguageOrLocale(_:)).
  public enum GenerationError: Error, LocalizedError {
    // DocC languagemodelsession/generationerror/context: `struct Context` (iOS 26.0)
    public struct Context: Sendable {
      // DocC languagemodelsession/generationerror/context/debugdescription: `let debugDescription: String`
      public let debugDescription: String
    }

    // DocC languagemodelsession/generationerror/refusal: `struct Refusal` (iOS 26.0)
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

  // DocC languagemodelsession/toolcallerror: `struct ToolCallError` (iOS 26.0),
  // conforms to Error, LocalizedError, Sendable.
  public struct ToolCallError: Error, LocalizedError {
    // DocC languagemodelsession/toolcallerror/tool: `var tool: any Tool` (iOS 26.0)
    public var tool: any Tool
    // DocC languagemodelsession/toolcallerror/underlyingerror: `var underlyingError: any Error` (iOS 26.0)
    public var underlyingError: any Error
  }

  // DocC languagemodelsession/responsestream:
  // `struct ResponseStream<Content> where Content : Generable` (iOS 26.0), an AsyncSequence.
  public struct ResponseStream<Content: Generable>: AsyncSequence {
    // DocC languagemodelsession/responsestream/snapshot: `struct Snapshot` (iOS 26.0)
    public struct Snapshot {
      // DocC languagemodelsession/responsestream/snapshot/content: `var content: Content.PartiallyGenerated`
      public var content: Content.PartiallyGenerated
      // DocC languagemodelsession/responsestream/snapshot/rawcontent: `var rawContent: GeneratedContent`
      public var rawContent: GeneratedContent
    }

    public typealias Element = Snapshot

    public struct AsyncIterator: AsyncIteratorProtocol {
      public mutating func next() async throws -> Snapshot? { nil }
    }

    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator() }
  }

  // DocC languagemodelsession/init(model:tools:instructions:):
  // `convenience init(model: SystemLanguageModel = .default, tools: [any Tool] = [],
  //  @InstructionsBuilder instructions: () throws -> Instructions) rethrows` (iOS 26.0)
  public convenience init(
    model: SystemLanguageModel = .default, tools: [any Tool] = [],
    @InstructionsBuilder instructions: () throws -> Instructions
  ) rethrows {
    self.init(model: model, tools: tools, transcript: Transcript())
  }

  // DocC languagemodelsession/init(model:tools:transcript:):
  // `convenience init(model: SystemLanguageModel = .default, tools: [any Tool] = [], transcript: Transcript)`
  // (iOS 26.0; designated here because the stand-in has no other init).
  public init(model: SystemLanguageModel = .default, tools: [any Tool] = [], transcript: Transcript) {}

  // DocC languagemodelsession/transcript: `final var transcript: Transcript` (iOS 26.0;
  // the page also shows a setter, not transcribed: unused, SDK version unknown).
  public var transcript: Transcript { Transcript() }
  // DocC languagemodelsession/isresponding: `final var isResponding: Bool { get }` (iOS 26.0)
  public var isResponding: Bool { false }

  // DocC languagemodelsession/prewarm(promptprefix:): `final func prewarm(promptPrefix: Prompt? = nil)` (iOS 26.0)
  public func prewarm(promptPrefix: Prompt? = nil) {}

  // DocC languagemodelsession/streamresponse(to:options:):
  // `final func streamResponse(to prompt: Prompt, options: GenerationOptions = GenerationOptions())
  //  -> sending LanguageModelSession.ResponseStream<String>` (iOS 26.0)
  public func streamResponse(to prompt: Prompt, options: GenerationOptions = GenerationOptions())
    -> sending ResponseStream<String>
  { ResponseStream() }

  // DocC languagemodelsession/streamresponse(to:schema:includeschemainprompt:options:):
  // `final func streamResponse(to prompt: Prompt, schema: GenerationSchema, includeSchemaInPrompt: Bool = true,
  //  options: GenerationOptions = GenerationOptions()) -> sending LanguageModelSession.ResponseStream<GeneratedContent>`
  public func streamResponse(
    to prompt: Prompt, schema: GenerationSchema, includeSchemaInPrompt: Bool = true,
    options: GenerationOptions = GenerationOptions()
  ) -> sending ResponseStream<GeneratedContent> { ResponseStream() }
}
