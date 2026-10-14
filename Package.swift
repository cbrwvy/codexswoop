// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexSwoop",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CodexSwoopCore", targets: ["CodexSwoopCore"]),
        .executable(name: "CodexSwoop", targets: ["CodexSwoop"]),
        .executable(name: "codexswoop-recovery", targets: ["CodexSwoopRecovery"]),
        .executable(name: "codexswoop-checks", targets: ["CoreChecks"])
    ],
    targets: [
        .target(name: "CodexSwoopCore"),
        .executableTarget(name: "CodexSwoop", dependencies: ["CodexSwoopCore"]),
        .executableTarget(name: "CodexSwoopRecovery", dependencies: ["CodexSwoopCore"]),
        .executableTarget(name: "CoreChecks", dependencies: ["CodexSwoopCore"], path: "Tests/CoreChecks"),
        .testTarget(name: "CodexSwoopCoreTests", dependencies: ["CodexSwoopCore"])
    ]
)
