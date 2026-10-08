// swift-tools-version: 5.10
import PackageDescription

var products: [Product] = [
    .library(name: "VoicePanelCore", targets: ["VoicePanelCore"]),
    .executable(name: "VoicePanelCoreChecks", targets: ["VoicePanelCoreChecks"]),
]

var packageDependencies: [Package.Dependency] = []
var coreDependencies: [Target.Dependency] = []

#if !os(macOS)
    coreDependencies.append("VoicePanelCryptoCompat")
#endif

var targets: [Target] = [
    .target(
        name: "VoicePanelCore",
        dependencies: coreDependencies,
        path: "Sources/VoicePanelCore"
    ),
    .executableTarget(
        name: "VoicePanelCoreChecks",
        dependencies: ["VoicePanelCore"],
        path: "Tests/VoicePanelCoreChecks"
    ),
]

#if !os(macOS)
    targets.append(
        .target(
            name: "VoicePanelCryptoCompat",
            path: "Sources/VoicePanelCryptoCompat",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("crypto")]
        )
    )
#endif

#if os(macOS)
    // These checksums match the exact archives currently served by the pinned
    // 1.13.2 release URLs. Do not copy checksums from a differently tagged
    // checksum-fix release unless the binary URLs are changed to matching assets.
    products.append(.executable(name: "VoicePanel", targets: ["VoicePanelApp"]))
    targets.append(
        .binaryTarget(
            name: "sherpa-onnx",
            url: "https://github.com/willwade/sherpa-onnx-spm/releases/download/1.13.2/sherpa-onnx.xcframework.zip",
            checksum: "62de3c1423a4f20516e8623858ee8c8d306af7ebb2a3737dc0600b1d4ee6aa4b"
        )
    )
    targets.append(
        .binaryTarget(
            name: "onnxruntime",
            url: "https://github.com/willwade/sherpa-onnx-spm/releases/download/1.13.2/onnxruntime.xcframework.zip",
            checksum: "38bc65b3e6af3e6d99bc18a40f80bfb3e56ee1eedfa0d0a60feb1c97a2d06dee"
        )
    )
    targets.append(
        .target(
            name: "VoicePanelORTBridge",
            dependencies: ["onnxruntime"],
            path: "Sources/VoicePanelORTBridge",
            publicHeadersPath: "include"
        )
    )
    targets.append(
        .binaryTarget(
            name: "WhisperFramework",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.7.5/whisper-v1.7.5-xcframework.zip",
            checksum: "c7faeb328620d6012e130f3d705c51a6ea6c995605f2df50f6e1ad68c59c6c4a"
        )
    )
    targets.insert(
        .executableTarget(
            name: "VoicePanelApp",
            dependencies: [
                "VoicePanelCore",
                "WhisperFramework",
                "sherpa-onnx",
                "onnxruntime",
                "VoicePanelORTBridge",
            ],
            path: "Sources/VoicePanelApp"
        ),
        at: 1
    )
#endif

let package = Package(
    name: "VoicePanel",
    platforms: [
        .macOS(.v14)
    ],
    products: products,
    dependencies: packageDependencies,
    targets: targets,
    swiftLanguageVersions: [.v5]
)
