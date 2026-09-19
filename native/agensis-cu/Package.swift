// swift-tools-version: 6.0
// agensis-cu — the computer-use HOST for an Agensis relay.
//
// Runs inside a macOS user account (typically a dedicated background agent
// account) and exposes local computer use — screen capture and synthetic mouse
// and keyboard — as an MCP server over stdio. Any agent that speaks MCP (Claude
// Code, Codex, or this relay via --mcp-allow) loads it and can then see and
// drive that account's desktop.
//
// The macOS permissions the user grants to this binary in that account are the
// only thing that bounds it. It requests them on launch and reports their
// state; it never works around a denial.
import PackageDescription

let package = Package(
  name: "agensis-cu",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "agensis-cu", targets: ["agensis-cu"]),
  ],
  targets: [
    .executableTarget(name: "agensis-cu"),
    .testTarget(name: "agensis-cuTests", dependencies: ["agensis-cu"]),
  ]
)
