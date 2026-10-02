// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BeakrNet",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .watchOS(.v11)
    ],
    products: [
        .library(name: "BeakrNetCore", targets: ["BeakrNetCore"]),
        .library(name: "BeakrNetSecurity", targets: ["BeakrNetSecurity"]),
        .library(name: "BeakrNetTestSupport", targets: ["BeakrNetTestSupport"]),
        .executable(name: "BeakrNetHandoffLab", targets: ["BeakrNetHandoffLab"]),
        .executable(name: "BeakrNetRelayServer", targets: ["BeakrNetRelayServer"]),
        .executable(name: "BeakrNetNodeCLI", targets: ["BeakrNetNodeCLI"])
    ],
    targets: [
        .target(name: "BeakrNetCore"),
        .target(
            name: "BeakrNetSecurity",
            dependencies: ["BeakrNetCore"]
        ),
        .target(
            name: "BeakrNetTestSupport",
            dependencies: ["BeakrNetCore"]
        ),
        .executableTarget(
            name: "BeakrNetHandoffLab",
            dependencies: ["BeakrNetCore", "BeakrNetTestSupport"]
        ),
        .executableTarget(
            name: "BeakrNetRelayServer",
            dependencies: ["BeakrNetCore", "BeakrNetSecurity"]
        ),
        .executableTarget(
            name: "BeakrNetNodeCLI",
            dependencies: ["BeakrNetCore", "BeakrNetSecurity"]
        ),
        .testTarget(
            name: "BeakrNetCoreTests",
            dependencies: ["BeakrNetCore", "BeakrNetSecurity", "BeakrNetTestSupport"]
        )
    ]
)
