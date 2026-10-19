// swift-tools-version: 5.9
// Swift 5 language mode, like sherpa_platform: the plugin is compiled for the
// first time in macOS CI (no Xcode in the dev container).
//
// mlx-swift-lm's own manifest is swift-tools 6.2, so building this package
// needs Xcode 26 or later (and the Metal Toolchain component, because MLX
// compiles .metal sources: `xcodebuild -downloadComponent MetalToolchain`).
//
// Versions verified on 2026-10-19 with `git ls-remote --tags`:
// mlx-swift-lm 3.32.3 (3b339ad, 2026-09-30) and mlx-swift 0.32.3 (1960120,
// 2026-09-30) are the latest tags; swift-transformers 1.3.5 is the latest.
// mlx-swift-lm 3.x is pinned to the minor (it moves fast, 3.x broke 2.x).
// MLX is imported directly (Memory limits, withError, Stream.gpu), so
// mlx-swift is declared too, at the same minor mlx-swift-lm requires.
//
// Only MLXLLM / MLXLMCommon are used: no MLXHuggingFace macros (no
// swift-syntax build, no macro-trust prompts) and no Downloader — the app
// downloads models; MLX loads them from a local directory.
//
// FoundationModels needs no dependency: it is an SDK framework, imported
// under `#if canImport(FoundationModels)` and used only behind
// `@available(iOS 26.0, *)`, so it is weak-linked and the app runs on iOS 17.
import PackageDescription

let package = Package(
  name: "sherpa_apple_ml",
  platforms: [
    // PLAN §4: iOS 17 floor (mlx-swift-lm declares .iOS(.v17)).
    .iOS("17.0")
  ],
  products: [
    .library(name: "sherpa-apple-ml", targets: ["sherpa_apple_ml"])
  ],
  dependencies: [
    .package(name: "FlutterFramework", path: "../FlutterFramework"),
    .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMinor(from: "3.32.3")),
    .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.32.3")),
    .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
  ],
  targets: [
    .target(
      name: "sherpa_apple_ml",
      dependencies: [
        .product(name: "FlutterFramework", package: "FlutterFramework"),
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "MLXLLM", package: "mlx-swift-lm"),
        .product(name: "Tokenizers", package: "swift-transformers"),
      ],
      resources: [
        .process("PrivacyInfo.xcprivacy")
      ]
    )
  ]
)
