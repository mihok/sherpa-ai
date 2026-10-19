#
# CocoaPods fallback for the SwiftPM package in sherpa_platform/. Flutter uses
# SwiftPM by default since 3.44, but plugins should keep a podspec until
# CocoaPods support is dropped (R09 §0.2).
#
Pod::Spec.new do |s|
  s.name             = 'sherpa_platform'
  s.version          = '0.1.0'
  s.summary          = 'Sherpa OS signals: memory, thermal, device facts, background leases.'
  s.description      = <<-DESC
Memory pressure, thermal and power state, device snapshot, backup exclusion and
background-task leases for the Sherpa agent harness.
                       DESC
  s.homepage         = 'https://github.com/mihok/sherpa-ai'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Sherpa' => 'noreply@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'sherpa_platform/Sources/sherpa_platform/**/*.swift'
  s.dependency 'Flutter'
  s.platform         = :ios, '17.0'
  s.frameworks       = 'BackgroundTasks', 'UIKit'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
  s.resource_bundles = { 'sherpa_platform_privacy' => ['sherpa_platform/Sources/sherpa_platform/PrivacyInfo.xcprivacy'] }
end
