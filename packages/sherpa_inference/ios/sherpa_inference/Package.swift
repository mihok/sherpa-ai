// swift-tools-version: 5.9
//
// SwiftPM wiring for the sherpa_inference FFI plugin (Flutter links the
// library product "sherpa-inference" into the Runner).
//
// The engine is SherpaEngine.xcframework, produced on macOS by
// native/llama/build_ios.sh (one dynamic SherpaEngine.framework per slice,
// exporting only se_*). tool/link_ios_engine.sh copies it to
// ./Frameworks/ (gitignored), where the binary target below picks it up;
// SwiftPM/Xcode then link AND embed the dynamic framework, and the Dart side
// opens it with DynamicLibrary.open('SherpaEngine.framework/SherpaEngine').
//
// Without the xcframework the package still resolves and the app still
// builds (the manifest checks for it), and the provider reports "engine
// unavailable" at runtime — the same behaviour as an Android build without
// native/llama/out/android/jniLibs.

import Foundation
import PackageDescription

let enginePath = "Frameworks/SherpaEngine.xcframework"
let hasEngine = FileManager.default.fileExists(
    atPath: Context.packageDirectory + "/" + enginePath)

var targets: [Target] = [
    .target(
        name: "sherpa_inference",
        dependencies: hasEngine ? ["SherpaEngine"] : [],
        path: "Sources/sherpa_inference",
        // The engine is located through the dynamic loader, not via Swift
        // imports, so a mismatched engine never breaks the app's build.
        cSettings: [.define("SHERPA_INFERENCE_HAS_ENGINE", to: hasEngine ? "1" : "0")]
    )
]
if hasEngine {
    targets.append(.binaryTarget(name: "SherpaEngine", path: enginePath))
}

let package = Package(
    name: "sherpa_inference",
    platforms: [
        // PLAN §4: iOS 17.0 (build_ios.sh builds the engine for 17.0).
        .iOS("17.0")
    ],
    products: [
        .library(name: "sherpa-inference", targets: ["sherpa_inference"])
    ],
    targets: targets
)
