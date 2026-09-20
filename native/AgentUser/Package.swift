// swift-tools-version: 6.0
// AgentUser — the setup wizard and viewer for an agent's own macOS desktop.
//
// One binary, three faces, chosen by where it is running and how far setup has
// got: a host-side wizard, an agent-side permissions wizard that requests the
// TCC grants directly (the reason this is an app and not a script), and a
// viewer that wraps noVNC and authenticates for you.
import PackageDescription

let package = Package(
  name: "AgentUser",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "AgentUser", targets: ["AgentUser"]),
    .executable(name: "agentdesktop-setup", targets: ["SetupHelper"]),
  ],
  targets: [
    .executableTarget(name: "AgentUser", dependencies: ["SetupCore"]),
    .executableTarget(name: "SetupHelper", dependencies: ["SetupCore"]),
    .target(name: "SetupCore"),
    .testTarget(name: "AgentUserTests", dependencies: ["AgentUser", "SetupCore"]),
  ]
)
