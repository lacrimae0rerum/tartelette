// swift-tools-version:6.0

import PackageDescription

let package = Package(
  name: "TarteletteKit",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "TarteletteKit", targets: ["TarteletteKit"]),
    // Linked by the app project's `tartelette-mcp` tool target, which embeds the helper in the app.
    .library(name: "TarteletteMCP", targets: ["TarteletteMCP"]),
    .executable(name: "tartelette-mcp", targets: ["TarteletteMCPServer"]),
  ],
  dependencies: [
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
  ],
  targets: [
    // Domain: value types, command model and ports. No I/O.
    .target(name: "TarteletteCore"),
    // Adapter: drives the `tart` executable.
    .target(name: "TarteletteCLI", dependencies: ["TarteletteCore"]),
    // Adapter: host-side process, system and storage metrics.
    .target(name: "TarteletteMetrics", dependencies: ["TarteletteCore"]),
    // Adapter: guest command transports, guest metrics and clipboard bridge.
    .target(name: "TarteletteGuest", dependencies: ["TarteletteCore"]),
    // Agent access: per-VM policy, agent VM registry, authorization, audit log and tool logic.
    .target(name: "TarteletteAgents", dependencies: ["TarteletteCore", "TarteletteCLI", "TarteletteGuest"]),
    // MCP server: exposes the agent tools over the Model Context Protocol. Not part of the umbrella
    // module, so the app doesn't link the MCP SDK.
    .target(name: "TarteletteMCP", dependencies: [
      "TarteletteAgents", "TarteletteCLI", .product(name: "MCP", package: "swift-sdk"),
      .product(name: "Logging", package: "swift-log"),
    ]),
    // The `tartelette-mcp` helper agents launch over stdio.
    .executableTarget(name: "TarteletteMCPServer", dependencies: [
      "TarteletteMCP", .product(name: "MCP", package: "swift-sdk"),
    ]),
    // Umbrella module imported by the app.
    .target(name: "TarteletteKit", dependencies: [
      "TarteletteCore", "TarteletteCLI", "TarteletteMetrics", "TarteletteGuest", "TarteletteAgents",
    ]),
    .testTarget(name: "TarteletteCoreTests", dependencies: ["TarteletteCore"]),
    .testTarget(name: "TarteletteCLITests", dependencies: ["TarteletteCLI"]),
    .testTarget(name: "TarteletteMetricsTests", dependencies: ["TarteletteMetrics"]),
    .testTarget(name: "TarteletteGuestTests", dependencies: ["TarteletteGuest"]),
    .testTarget(name: "TarteletteAgentsTests", dependencies: ["TarteletteAgents"]),
    .testTarget(name: "TarteletteMCPTests", dependencies: [
      "TarteletteMCP", "TarteletteAgents", .product(name: "MCP", package: "swift-sdk"),
      .product(name: "Logging", package: "swift-log"),
    ]),
  ]
)
