#
# CocoaPods wiring for the sherpa_inference FFI plugin (used when the app is
# not on SwiftPM). Same contract as ios/sherpa_inference/Package.swift:
# SherpaEngine.xcframework from native/llama/build_ios.sh, copied by
# tool/link_ios_engine.sh into sherpa_inference/Frameworks/, is vendored as a
# dynamic framework (linked and embedded); without it the pod still builds and
# the provider reports "engine unavailable" at runtime.
#
engine = 'sherpa_inference/Frameworks/SherpaEngine.xcframework'
has_engine = File.exist?(File.join(__dir__, engine))

Pod::Spec.new do |s|
  s.name             = 'sherpa_inference'
  s.version          = '0.1.0'
  s.summary          = 'On-device inference for Sherpa: the sherpa_engine C ABI (llama.cpp) for Dart FFI.'
  s.description      = <<-DESC
Packages SherpaEngine.xcframework (llama.cpp + Sherpa's C ABI, Metal) for the
Dart FFI bindings in package:sherpa_inference.
                       DESC
  s.homepage         = 'https://github.com/mihok/sherpa'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Sherpa' => 'sherpa@users.noreply.github.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'sherpa_inference/Sources/sherpa_inference/**/*.{c,h}'
  s.public_header_files = 'sherpa_inference/Sources/sherpa_inference/include/*.h'
  s.dependency 'Flutter'
  # PLAN §4: iOS 17.0, the engine's deployment target.
  s.platform = :ios, '17.0'
  s.vendored_frameworks = engine if has_engine
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'GCC_PREPROCESSOR_DEFINITIONS' => "$(inherited) SHERPA_INFERENCE_HAS_ENGINE=#{has_engine ? 1 : 0}",
  }
end
