#
# CocoaPods fallback for the SwiftPM package in sherpa_apple_ml/.
#
# CocoaPods CANNOT carry MLX: neither ml-explore/mlx-swift nor mlx-swift-lm
# ships a podspec, and the trunk has no MLX, MLXLLM, MLXLMCommon,
# swift-transformers or Tokenizers pod (checked 2026-10-19 against
# trunk.cocoapods.org). The CocoaPods trunk also becomes read-only on
# Dec 2, 2026 (R06 §11.1). This podspec therefore builds the plugin WITHOUT
# MLX: the MLX sources are compiled out by `#if canImport(MLXLLM)`, the
# plugin reports `mlxCompiled = false`, and MlxProvider.availability answers
# "unsupported / notCompiled". Apple Foundation Models works in both builds.
# Use the SwiftPM build (Flutter's default since 3.44) to get MLX.
#
Pod::Spec.new do |s|
  s.name             = 'sherpa_apple_ml'
  s.version          = '0.1.0'
  s.summary          = 'Sherpa on-device models: MLX Swift (SwiftPM only) and Apple Foundation Models.'
  s.description      = <<-DESC
MLX (mlx-swift-lm) and Apple Foundation Models providers for the Sherpa agent
harness. The CocoaPods build contains Foundation Models only; MLX needs SwiftPM.
                       DESC
  s.homepage         = 'https://github.com/mihok/sherpa-ai'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Sherpa' => 'noreply@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'sherpa_apple_ml/Sources/sherpa_apple_ml/**/*.swift'
  s.dependency 'Flutter'
  s.platform         = :ios, '17.0'
  s.frameworks       = 'UIKit', 'Metal'
  # iOS 26+ only, used behind @available: weak so the app launches on 17–25.
  s.weak_frameworks  = 'FoundationModels'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
  s.resource_bundles = { 'sherpa_apple_ml_privacy' => ['sherpa_apple_ml/Sources/sherpa_apple_ml/PrivacyInfo.xcprivacy'] }
end
