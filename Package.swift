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
        .library(name: "BeakrNetAuthority", targets: ["BeakrNetAuthority"]),
        .library(name: "BeakrNetRelayTransport", targets: ["BeakrNetRelayTransport"]),
        .library(name: "BeakrNetTestSupport", targets: ["BeakrNetTestSupport"]),
        .executable(name: "BeakrNetHandoffLab", targets: ["BeakrNetHandoffLab"]),
        .executable(name: "BeakrNetRelayServer", targets: ["BeakrNetRelayServer"]),
        .executable(name: "BeakrNetNodeCLI", targets: ["BeakrNetNodeCLI"]),
        .executable(name: "BeakrNetCredentialTool", targets: ["BeakrNetCredentialTool"])
    ],
    targets: [
        .target(name: "BeakrNetCore"),
        .target(
            name: "BeakrNetSecurity",
            dependencies: ["BeakrNetCore"]
        ),
        .target(
            name: "BeakrNetAuthority",
            dependencies: ["BeakrNetCore", "BeakrNetSecurity"]
        ),
        .target(
            name: "BeakrNetRelayTransport",
            dependencies: ["BeakrNetCore", "BeakrNetSecurity", "BeakrNetAuthority"]
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
            dependencies: ["BeakrNetCore", "BeakrNetSecurity", "BeakrNetAuthority"]
        ),
        .executableTarget(
            name: "BeakrNetNodeCLI",
            dependencies: ["BeakrNetCore", "BeakrNetSecurity", "BeakrNetAuthority", "BeakrNetRelayTransport"]
        ),
        .executableTarget(
            name: "BeakrNetCredentialTool",
            dependencies: ["BeakrNetCore", "BeakrNetSecurity", "BeakrNetAuthority"]
        ),
        .testTarget(
            name: "BeakrNetCoreTests",
            dependencies: ["BeakrNetCore", "BeakrNetSecurity", "BeakrNetAuthority", "BeakrNetRelayTransport", "BeakrNetTestSupport"]
        )
    ]
)
