// STAND-IN for mlx-swift-lm 3.32.3 `MLXLLM` (LLMModelFactory.swift and the
// GenericModelFactory extension in MLXLMCommon/ModelFactory.swift), for
// type-checking on Linux only.
import Foundation
import MLXLMCommon

public final class LLMModelFactory: Sendable {
  public static let shared = LLMModelFactory()

  /// "Load a model from a local directory, producing a ModelContainer. No
  /// downloader is needed."
  public func loadContainer(from directory: URL, using tokenizerLoader: any TokenizerLoader) async throws
    -> ModelContainer
  { fatalError("stand-in") }
}
