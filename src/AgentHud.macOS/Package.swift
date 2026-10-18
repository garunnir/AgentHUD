// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentHud",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AgentHud", targets: ["AgentHud"])
    ],
    targets: [
        .executableTarget(
            name: "AgentHud",
            path: "AgentHud",
            resources: [
                .copy("Resources/Strings.tsv")
            ]
        ),
        .testTarget(name: "AgentHudTests", dependencies: ["AgentHud"], path: "Tests")
    ]
)
