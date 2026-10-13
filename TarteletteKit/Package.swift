// swift-tools-version:6.0

import PackageDescription

let package = Package(
  name: "TarteletteKit",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "TarteletteKit", targets: ["TarteletteKit"])
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
    // Agent access: per-VM policy, agent VM registry, authorization and audit log.
    .target(name: "TarteletteAgents", dependencies: ["TarteletteCore"]),
    // Umbrella module imported by the app.
    .target(name: "TarteletteKit", dependencies: [
      "TarteletteCore", "TarteletteCLI", "TarteletteMetrics", "TarteletteGuest", "TarteletteAgents",
    ]),
    .testTarget(name: "TarteletteCoreTests", dependencies: ["TarteletteCore"]),
    .testTarget(name: "TarteletteCLITests", dependencies: ["TarteletteCLI"]),
    .testTarget(name: "TarteletteMetricsTests", dependencies: ["TarteletteMetrics"]),
    .testTarget(name: "TarteletteGuestTests", dependencies: ["TarteletteGuest"]),
    .testTarget(name: "TarteletteAgentsTests", dependencies: ["TarteletteAgents"]),
  ]
)
