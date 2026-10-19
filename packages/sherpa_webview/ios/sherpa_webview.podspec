#
# CocoaPods fallback for the SwiftPM package in sherpa_webview/. Flutter uses
# SwiftPM by default since 3.44, but plugins should keep a podspec until
# CocoaPods support is dropped (R09 §0.2).
#
Pod::Spec.new do |s|
  s.name             = 'sherpa_webview'
  s.version          = '0.1.0'
  s.summary          = 'Sandboxed WKWebView host for MCP Apps.'
  s.description      = <<-DESC
Non-persistent, content-rule-restricted WKWebView with a private-content-world
bridge, hosting MCP App views for the Sherpa agent harness.
                       DESC
  s.homepage         = 'https://github.com/mihok/sherpa-ai'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Sherpa' => 'noreply@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'sherpa_webview/Sources/sherpa_webview/**/*.swift'
  s.dependency 'Flutter'
  s.platform         = :ios, '17.0'
  s.frameworks       = 'WebKit', 'UIKit'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
  s.resource_bundles = { 'sherpa_webview_privacy' => ['sherpa_webview/Sources/sherpa_webview/PrivacyInfo.xcprivacy'] }
end
