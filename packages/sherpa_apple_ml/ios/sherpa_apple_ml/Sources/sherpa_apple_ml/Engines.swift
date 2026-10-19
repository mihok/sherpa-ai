import Foundation
import Metal
import UIKit
import os

/// The MLX engine as the plugin sees it. The implementation (MlxEngine.swift)
/// exists only when the package is built with mlx-swift-lm (SwiftPM); the
/// CocoaPods build has none and reports `mlxCompiled = false`.
protocol MlxEngineAPI: AnyObject, Sendable {
  func load(_ request: AmMlxLoadRequest) async throws -> AmMlxModelInfo
  func unload(modelId: String) async
  func generate(_ request: AmMlxGenerateRequest) async throws
  func countTokens(modelId: String, text: String) async throws -> Int
  func savePromptCache(sessionKey: String, path: String) async throws -> Bool
  func cancel(generationId: String) async
  /// Stops every generation at a token boundary, waits until no GPU work is
  /// in flight, and reports `paused(reason)` for each.
  func pauseAll(reason: String) async
  func dropSession(_ sessionKey: String) async
  func handleMemoryWarning() async
  /// `GPU.maxRecommendedWorkingSetBytes()` (cheap, any thread).
  var recommendedWorkingSetBytes: Int? { get }
}

/// The Foundation Models engine (FoundationModelsEngine.swift): compiled
/// only when the SDK has FoundationModels, created only on iOS 26+.
protocol FmEngineAPI: AnyObject, Sendable {
  func availability() async -> AmFmAvailability
  func generate(_ request: AmFmGenerateRequest) async throws
  func submitToolResults(generationId: String, results: [AmToolResult]) async
  func cancel(generationId: String) async
  func dropSession(_ sessionKey: String) async
  func prewarm(instructions: String?) async
}

/// Error codes shared with Dart (lib/src/common/errors.dart).
enum ErrorCode: String {
  case outOfMemory, contextOverflow, modelNotFound, unsupported, invalidRequest, rateLimited, timeout, busy,
    server, engineError, modelUnloaded, assetsUnavailable, unsupportedLanguage, unknown
  /// `mlxGenerate(.append)` for a session the engine no longer has (dropped
  /// on a memory warning): Dart rebuilds and retries.
  case sessionLost
}

enum PluginError {
  static func make(_ code: ErrorCode, _ message: String) -> SherpaAppleMlError {
    SherpaAppleMlError(code: code.rawValue, message: message, details: nil)
  }
}

extension AmEvent {
  static func make(_ kind: AmEventKind, code: String? = nil, message: String? = nil, text: String? = nil) -> AmEvent {
    var e = AmEvent(kind: kind)
    e.code = code
    e.message = message
    e.text = text
    return e
  }
}

/// Raw device facts for Dart's availability policy.
enum DeviceFacts {
  @MainActor
  static func platformInfo(mlxCompiled: Bool, fmCompiled: Bool, recommendedWorkingSet: Int?) -> AmPlatformInfo {
    #if targetEnvironment(simulator)
      let simulator = true
    #else
      let simulator = false
    #endif
    let process = ProcessInfo.processInfo
    var info = AmPlatformInfo(
      osVersion: UIDevice.current.systemVersion,
      isSimulator: simulator,
      hasMetalDevice: MTLCreateSystemDefaultDevice() != nil,
      mlxCompiled: mlxCompiled,
      fmCompiled: fmCompiled,
      appActive: UIApplication.shared.applicationState == .active,
      procAvailableBytes: Int64(os_proc_available_memory()),
      physicalMemoryBytes: Int64(process.physicalMemory),
      thermalState: Int64(process.thermalState.rawValue),
      lowPowerMode: process.isLowPowerModeEnabled
    )
    info.recommendedWorkingSetBytes = recommendedWorkingSet.map { Int64($0) }
    return info
  }
}
