// STAND-IN for mlx-swift 0.32.3 `MLX`, for type-checking on Linux only.
// Mirrors the public declarations the plugin uses, copied from
// Source/MLX/{Memory,GPU+Metal,ErrorHandler,Stream,MLXArray}.swift at tag
// 0.32.3 (commit 19601207). Bodies are placeholders.
import Foundation

public enum Memory {
  public struct Snapshot: CustomStringConvertible, Codable, Sendable {
    public var activeMemory: Int
    public var cacheMemory: Int
    public var peakMemory: Int
    public var description: String { "" }
  }

  public static var activeMemory: Int { 0 }
  public static var cacheMemory: Int { 0 }
  public static var peakMemory: Int { 0 }
  public static func snapshot() -> Snapshot { Snapshot(activeMemory: 0, cacheMemory: 0, peakMemory: 0) }

  /// "takes effect on the next deallocation"; see clearCache().
  public static var cacheLimit: Int {
    get { 0 }
    set {}
  }

  /// "Calls to malloc will wait on scheduled tasks if the limit is exceeded."
  public static var memoryLimit: Int {
    get { 0 }
    set {}
  }

  public static func clearCache() {}
}

public enum GPU {
  public static func maxRecommendedWorkingSetBytes() -> Int? { nil }

  @available(*, deprecated, message: "use Memory.cacheLimit property")
  public static func set(cacheLimit: Int) {}
}

public final class Stream: @unchecked Sendable, Equatable {
  public static func == (lhs: Stream, rhs: Stream) -> Bool { lhs === rhs }
  public static var gpu: Stream { Stream() }
  public static var defaultStream: Stream { Stream() }
  public func synchronize() {}
}

// ErrorHandler.swift
@available(*, deprecated, message: "please use withErrorHandler() or withError()")
public func setErrorHandler(
  _ handler: (@convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void)?,
  data: UnsafeMutableRawPointer? = nil,
  dtor: (@convention(c) (UnsafeMutableRawPointer?) -> Void)? = nil
) {}

public func withErrorHandler<R>(_ handler: @escaping @Sendable (String) -> Void, _ body: () throws -> R) rethrows -> R {
  try body()
}

public func withErrorHandler<R>(_ handler: @escaping @Sendable (String) -> Void, _ body: () async throws -> R)
  async rethrows -> R
{
  try await body()
}

public func withError<R>(_ body: (ErrorBox) throws -> R) throws -> R { try body(ErrorBox()) }
public func withError<R>(_ body: () throws -> R) throws -> R { try body() }
public func withError<R>(_ body: (ErrorBox) async throws -> R) async throws -> R { try await body(ErrorBox()) }
public func withError<R>(_ body: () async throws -> R) async throws -> R { try await body() }

public enum MLXError: LocalizedError, Sendable, Equatable {
  case caught(String)
  public var errorDescription: String? {
    switch self {
    case .caught(let message): "MLX Error: \(message)"
    }
  }
}

public final class ErrorBox: @unchecked Sendable {
  public var firstError: Error?
  public func check() throws {
    if let firstError { throw firstError }
  }
}

public protocol HasDType {}
extension Int: HasDType {}
extension Int32: HasDType {}
extension Float: HasDType {}

public final class MLXArray {
  public init() {}
  public convenience init(_ value: [Int], _ shape: [Int]? = nil) { self.init() }
  public var size: Int { 0 }
  public func asArray<T: HasDType>(_ type: T.Type) -> [T] { [] }
}
