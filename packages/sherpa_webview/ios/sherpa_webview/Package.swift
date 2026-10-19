// swift-tools-version: 5.9
// Swift 5 language mode on purpose (same as sherpa_platform): the plugin is
// small and main-thread only, and it is compiled first in CI (no Xcode in
// the dev container), so Swift 6 strict-concurrency errors would only
// surface there.

import PackageDescription

let package = Package(
    name: "sherpa_webview",
    platforms: [
        // PLAN §4: iOS 17 floor. WKContentWorld / callAsyncJavaScript need
        // iOS 14; newer APIs are #available-gated.
        .iOS("17.0")
    ],
    products: [
        .library(name: "sherpa-webview", targets: ["sherpa_webview"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "sherpa_webview",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: [
                // No required-reason APIs and no tracking.
                .process("PrivacyInfo.xcprivacy")
            ]
        )
    ]
)
