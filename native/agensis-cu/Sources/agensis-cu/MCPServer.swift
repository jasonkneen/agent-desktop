import Foundation

/// Minimal MCP server over newline-delimited JSON-RPC 2.0 on stdio — the
/// transport Claude Code, Codex and the Agensis relay all speak for a local
/// server. Pure request/response so it is unit-testable without real IO.
final class MCPServer {
  let tools: Tools
  let name: String

  init(tools: Tools, name: String = "agensis-cu") {
    self.tools = tools
    self.name = name
  }

  /// Handle one decoded JSON-RPC message. Returns the response object, or nil
  /// for a notification (no id) that needs no reply.
  func handle(_ message: [String: Any]) -> [String: Any]? {
    let id = message["id"]
    guard let method = message["method"] as? String else { return nil }
    let params = message["params"] as? [String: Any] ?? [:]

    switch method {
    case "initialize":
      return result(id, [
        "protocolVersion": "2024-11-05",
        "serverInfo": ["name": name, "version": "0.1.0"],
        "capabilities": ["tools": [String: Any]()],
      ])
    case "notifications/initialized", "initialized":
      return nil
    case "ping":
      return result(id, [String: Any]())
    case "tools/list":
      return result(id, ["tools": Tools.definitions()])
    case "tools/call":
      guard let toolName = params["name"] as? String else {
        return error(id, -32602, "tools/call requires a name")
      }
      let args = params["arguments"] as? [String: Any] ?? [:]
      let outcome = tools.call(toolName, args)
      var content: [[String: Any]] = []
      if let text = outcome.text { content.append(["type": "text", "text": text]) }
      if let img = outcome.imageBase64 {
        content.append(["type": "image", "data": img, "mimeType": outcome.imageMime ?? "image/jpeg"])
      }
      if content.isEmpty { content = [["type": "text", "text": "ok"]] }
      return result(id, ["content": content, "isError": outcome.isError])
    default:
      // A request (has id) to an unknown method gets an error; a notification is
      // dropped silently, per JSON-RPC.
      return id == nil ? nil : error(id, -32601, "method not found: \(method)")
    }
  }

  private func result(_ id: Any?, _ value: [String: Any]) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": value]
  }
  private func error(_ id: Any?, _ code: Int, _ message: String) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
  }
}
