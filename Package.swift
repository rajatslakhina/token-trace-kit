// swift-tools-version:6.0
import PackageDescription

// Library only. The runnable demo lives in a separate repository
// (token-trace-demo-app) that consumes this package as a remote,
// version-pinned dependency. There is deliberately no executable target here.
let package = Package(
    name: "TokenTrace",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "TokenTrace", targets: ["TokenTrace"]),
        .library(name: "TokenTraceUI", targets: ["TokenTraceUI"])
    ],
    targets: [
        .target(name: "TokenTrace"),
        .target(name: "TokenTraceUI", dependencies: ["TokenTrace"]),
        .testTarget(name: "TokenTraceTests", dependencies: ["TokenTrace"])
    ]
)
