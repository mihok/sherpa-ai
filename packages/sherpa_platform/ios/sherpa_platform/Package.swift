// swift-tools-version: 5.9
// Swift 5 language mode on purpose: the plugin is small, main-thread/queue
// disciplined by hand, and compiled first in CI (no Xcode in the dev
// container), so Swift 6 strict-concurrency errors would only surface there.

import PackageDescription

let package = Package(
    name: "sherpa_platform",
    platforms: [
        // PLAN §4: iOS 17 floor (MLX Swift). iOS 26 APIs are #available-gated.
        .iOS("17.0")
    ],
    products: [
        .library(name: "sherpa-platform", targets: ["sherpa_platform"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "sherpa_platform",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: [
                // Declares the disk-space required-reason API (E174.1).
                .process("PrivacyInfo.xcprivacy")
            ]
        )
    ]
)
