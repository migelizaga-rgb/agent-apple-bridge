// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentAppleBridge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentAppleBridge", targets: ["AgentAppleBridge"]),
    ],
    targets: [
        .executableTarget(
            name: "AgentAppleBridge",
            path: "Sources/AgentAppleBridge",
            linkerSettings: [
                .linkedFramework("EventKit"),
            ]
        ),
        .testTarget(name: "AgentAppleBridgeTests", dependencies: ["AgentAppleBridge"]),
    ]
)
