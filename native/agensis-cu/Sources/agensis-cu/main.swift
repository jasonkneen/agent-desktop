import CoreGraphics
import Foundation

// agensis-cu — computer-use host, MCP server over stdio.
//
//   agensis-cu [--no-prompt] [--event-tap hid|session] [--self-test]
//
// On launch it requests Screen Recording and Accessibility (unless --no-prompt)
// so the first run inside an account surfaces the system dialogs. Everything it
// can do is bounded by what the user grants THIS binary in that account.

func stderr(_ s: String) {
  FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

let arguments = Array(CommandLine.arguments.dropFirst())
let eventTap: CGEventTapLocation = arguments.contains(where: { $0 == "--event-tap" })
  && arguments.contains("session") ? .cgSessionEventTap : .cghidEventTap
let desktop = RealDesktop(eventTap: eventTap)

if !arguments.contains("--no-prompt") {
  if !CGPreflightScreenCaptureAccess() {
    stderr("agensis-cu: requesting Screen Recording — \(CGRequestScreenCaptureAccess())")
  }
  if !CGPreflightPostEventAccess() {
    stderr("agensis-cu: requesting Accessibility — \(CGRequestPostEventAccess())")
  }
}

let tools = Tools(desktop: desktop)
let server = MCPServer(tools: tools)

if arguments.contains("--self-test") {
  let p = desktop.permissions()
  stderr("self-test user=\(NSUserName()) screenRecording=\(p.screenRecording) accessibility=\(p.accessibility) displays=\(desktop.displays().count)")
  exit(p.screenRecording ? 0 : 3)
}

let out = FileHandle.standardOutput
func emit(_ object: [String: Any]) {
  guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
  out.write(data)
  out.write(Data([0x0a]))
}

stderr("agensis-cu ready on stdio as \(NSUserName()); permissions: \(desktop.permissions())")

// Newline-delimited JSON-RPC read loop.
var buffer = Data()
while true {
  let chunk = FileHandle.standardInput.availableData
  if chunk.isEmpty { break }
  buffer.append(chunk)
  while let nl = buffer.firstIndex(of: 0x0a) {
    let line = buffer[buffer.startIndex..<nl]
    buffer.removeSubrange(buffer.startIndex...nl)
    if line.isEmpty { continue }
    guard let message = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else {
      emit(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]])
      continue
    }
    if let response = server.handle(message) { emit(response) }
  }
}
