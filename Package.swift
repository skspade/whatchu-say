// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "whatchu-say",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "WhatchuSayKit",
            targets: [
                "Core",
                "Audio",
                "STTCore",
                "STTElevenLabs",
                "STTMockProvider",
                "Hotkey",
                "Injector",
                "Usage",
                "Orchestrator",
            ]
        ),
        .library(
            name: "WhatchuSayPlatformApple",
            targets: ["PlatformApple"]
        ),
    ],
    targets: [
        .target(
            name: "Core",
            path: "Sources/Core"
        ),
        .target(
            name: "Audio",
            dependencies: ["Core"],
            path: "Sources/Audio"
        ),
        .target(
            name: "STTCore",
            dependencies: ["Core"],
            path: "Sources/STTCore"
        ),
        .target(
            name: "STTElevenLabs",
            dependencies: ["Core", "STTCore"],
            path: "Sources/STTElevenLabs"
        ),
        .target(
            name: "STTMockProvider",
            dependencies: ["Core", "STTCore"],
            path: "Sources/STTMockProvider"
        ),
        .target(
            name: "Hotkey",
            dependencies: ["Core"],
            path: "Sources/Hotkey"
        ),
        .target(
            name: "Injector",
            dependencies: ["Core"],
            path: "Sources/Injector"
        ),
        .target(
            name: "Usage",
            dependencies: ["Core"],
            path: "Sources/Usage"
        ),
        .target(
            name: "Orchestrator",
            dependencies: [
                "Core",
                "Audio",
                "STTCore",
                "Hotkey",
                "Injector",
                "Usage",
            ],
            path: "Sources/Orchestrator"
        ),
        .target(
            name: "Meeting",
            dependencies: ["Core", "STTCore"],
            path: "Sources/Meeting"
        ),
        .target(
            name: "PlatformApple",
            dependencies: [
                "Core",
                "Audio",
                "Hotkey",
                "Injector",
            ],
            path: "Sources/PlatformApple"
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core"],
            path: "Tests/CoreTests"
        ),
        .testTarget(
            name: "InjectorTests",
            dependencies: ["Injector", "Core"],
            path: "Tests/InjectorTests"
        ),
        .testTarget(
            name: "HotkeyTests",
            dependencies: ["Hotkey"],
            path: "Tests/HotkeyTests"
        ),
        .testTarget(
            name: "AudioTests",
            dependencies: ["Audio"],
            path: "Tests/AudioTests"
        ),
        .testTarget(
            name: "STTCoreTests",
            dependencies: ["STTCore", "STTMockProvider"],
            path: "Tests/STTCoreTests"
        ),
        .testTarget(
            name: "STTElevenLabsTests",
            dependencies: ["STTElevenLabs"],
            path: "Tests/STTElevenLabsTests"
        ),
        .testTarget(
            name: "OrchestratorTests",
            dependencies: [
                "Orchestrator",
                "STTMockProvider",
                "Hotkey",
                "Audio",
                "Injector",
                "Core",
            ],
            path: "Tests/OrchestratorTests"
        ),
        .testTarget(
            name: "UsageTests",
            dependencies: ["Usage"],
            path: "Tests/UsageTests"
        ),
        .testTarget(
            name: "MeetingTests",
            dependencies: ["Meeting", "STTCore", "STTMockProvider"],
            path: "Tests/MeetingTests"
        ),
        .testTarget(
            name: "PlatformAppleTests",
            dependencies: ["PlatformApple", "Hotkey", "Injector"],
            path: "Tests/PlatformAppleTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
