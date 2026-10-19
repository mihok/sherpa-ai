// STAND-IN for swift-transformers 1.3.5 `Tokenizers`
// (Sources/Tokenizers/Tokenizer.swift at tag 1.3.5), for type-checking on
// Linux only.
import Foundation

public typealias ToolSpec = [String: any Sendable]
public typealias Message = [String: any Sendable]

public enum TokenizerError: LocalizedError {
  case missingConfig
  case missingTokenizerClassInConfig
  case unsupportedTokenizer(String)
  case missingVocab
  case malformedVocab
  case chatTemplate(String)
  case missingChatTemplate
  case tooLong(String)
  case mismatchedConfig(String)
}

public protocol Tokenizer: Sendable {
  func encode(text: String, addSpecialTokens: Bool) -> [Int]
  func decode(tokens: [Int], skipSpecialTokens: Bool) -> String
  func convertTokenToId(_ token: String) -> Int?
  func convertIdToToken(_ id: Int) -> String?
  var bosToken: String? { get }
  var eosToken: String? { get }
  var unknownToken: String? { get }
  func applyChatTemplate(messages: [Message], tools: [ToolSpec]?, additionalContext: [String: any Sendable]?) throws
    -> [Int]
}

/// Hub.HubApi in the real package (default argument only).
public final class HubApi: Sendable {
  public static let shared = HubApi()
}

public struct AutoTokenizer {
  public static func from(modelFolder: URL, hubApi: HubApi = .shared, strict: Bool = true) async throws -> Tokenizer {
    fatalError("stand-in")
  }
}
