import Foundation

/// Turns MCP tool calls into DesktopControl operations. Coordinates arrive in
/// image-pixel space (the last screenshot the caller took) and are scaled to
/// display points here. Stateless except for the remembered scale, so one
/// instance serves the whole stdio session.
final class Tools: @unchecked Sendable {
  private let desktop: DesktopControl
  private let lock = NSLock()
  private var pointsPerPixel: Double

  init(desktop: DesktopControl) {
    self.desktop = desktop
    let w = desktop.targetWidthPoints()
    self.pointsPerPixel = w > 0 ? w / min(w, 1280) : 1
  }

  /// The tool catalogue as MCP `tools/list` entries.
  static func definitions() -> [[String: Any]] {
    func tool(_ name: String, _ desc: String, _ props: [String: Any], _ required: [String]) -> [String: Any] {
      ["name": name, "description": desc,
       "inputSchema": ["type": "object", "properties": props, "required": required,
                       "additionalProperties": false]]
    }
    let xy: [String: Any] = ["x": ["type": "number", "description": "X in pixels of the last screenshot"],
                             "y": ["type": "number", "description": "Y in pixels of the last screenshot"]]
    let button: [String: Any] = ["button": ["type": "string", "enum": ["left", "right", "middle"]]]
    return [
      tool("permissions", "Report whether Screen Recording and Accessibility are granted to this account, and the displays visible. Call this first; if either is false, ask the user to allow it in System Settings for this account.", [:], []),
      tool("screenshot", "Capture the desktop as a JPEG. Returns the image plus its pixel size. All click/move/scroll coordinates are in the pixel space of the most recent screenshot.",
           ["max_width": ["type": "integer", "description": "Longest edge in pixels (default 1280)"],
            "quality": ["type": "number", "description": "JPEG quality 0.1-1.0 (default 0.7)"]], []),
      tool("move", "Move the cursor to a point.", xy, ["x", "y"]),
      tool("click", "Click at a point.", xy.merging(button) { a, _ in a }.merging(
           ["count": ["type": "integer", "description": "1 single, 2 double, 3 triple (default 1)"]]) { a, _ in a }, ["x", "y"]),
      tool("mouse_down", "Press a mouse button and hold, for drags.", xy.merging(button) { a, _ in a }, ["x", "y"]),
      tool("mouse_up", "Release a held mouse button at a point.", xy.merging(button) { a, _ in a }, ["x", "y"]),
      tool("scroll", "Scroll at a point. Positive dy scrolls content up (wheel toward you); negative scrolls down.",
           xy.merging(["dx": ["type": "number"], "dy": ["type": "number"]]) { a, _ in a }, ["x", "y"]),
      tool("type", "Type Unicode text at the current focus. Newlines are sent as Return.",
           ["text": ["type": "string"]], ["text"]),
      tool("key", "Press a key chord such as \"cmd+space\", \"return\", \"cmd+shift+t\", \"pagedown\".",
           ["keys": ["type": "string"]], ["keys"]),
      tool("cursor_position", "Report the current cursor position, in display points.", [:], []),
      tool("open", "Open a URL or file path with the default handler (like the `open` command).",
           ["target": ["type": "string", "description": "URL or file path"]], ["target"]),
      tool("launch_app", "Launch an application by name (like `open -a`).",
           ["name": ["type": "string"]], ["name"]),
    ]
  }

  struct CallResult {
    var text: String?
    var imageBase64: String?
    var imageMime: String?
    var isError: Bool = false
  }

  func call(_ name: String, _ args: [String: Any]) -> CallResult {
    do {
      switch name {
      case "permissions":
        let p = desktop.permissions()
        let payload: [String: Any] = [
          "screen_recording": p.screenRecording,
          "accessibility": p.accessibility,
          "user": NSUserName(),
          "displays": desktop.displays().map {
            ["id": $0.id, "width": $0.width, "height": $0.height, "main": $0.isMain]
          },
          "advice": (p.screenRecording && p.accessibility)
            ? "Both granted; screenshot and input are available."
            : "Ask the user to grant the missing permission to agensis-cu in System Settings > Privacy & Security for THIS account, then call permissions again.",
        ]
        return .init(text: json(payload))

      case "screenshot":
        let shot = try desktop.capture(maxWidth: intArg(args, "max_width") ?? 1280,
                                       quality: doubleArg(args, "quality") ?? 0.7)
        lock.withLock { pointsPerPixel = shot.pointsPerPixel }
        return .init(text: json(["width": shot.width, "height": shot.height]),
                     imageBase64: shot.jpeg.base64EncodedString(), imageMime: "image/jpeg")

      case "move":
        let (x, y) = try points(args)
        desktop.moveCursor(toPoints: x, y)
        return ok("moved")

      case "click":
        let (x, y) = try points(args)
        desktop.click(atPoints: x, y, button: try button(args), count: intArg(args, "count") ?? 1)
        return ok("clicked")

      case "mouse_down":
        let (x, y) = try points(args)
        desktop.mouseDown(atPoints: x, y, button: try button(args))
        return ok("mouse down")

      case "mouse_up":
        let (x, y) = try points(args)
        desktop.mouseUp(atPoints: x, y, button: try button(args))
        return ok("mouse up")

      case "scroll":
        let (x, y) = try points(args)
        let scale = lock.withLock { pointsPerPixel }
        desktop.scroll(atPoints: x, y, dxPoints: (doubleArg(args, "dx") ?? 0) * scale,
                       dyPoints: (doubleArg(args, "dy") ?? 0) * scale)
        return ok("scrolled")

      case "type":
        guard let text = args["text"] as? String, !text.isEmpty else { throw ToolError("type needs text") }
        desktop.typeText(text)
        return ok("typed \(text.count) chars")

      case "key":
        guard let keys = args["keys"] as? String, let chord = KeyChord.parse(keys) else {
          throw ToolError("unrecognised key chord \(args["keys"] ?? "")")
        }
        desktop.pressChord(chord)
        return ok("pressed \(keys)")

      case "cursor_position":
        let (x, y) = desktop.cursorPointLocation()
        return .init(text: json(["x": x, "y": y]))

      case "open":
        guard let target = args["target"] as? String, !target.isEmpty else { throw ToolError("open needs target") }
        return ok(try desktop.openTarget(target, isApp: false))

      case "launch_app":
        guard let appName = args["name"] as? String, !appName.isEmpty else { throw ToolError("launch_app needs name") }
        return ok(try desktop.openTarget(appName, isApp: true))

      default:
        return .init(text: "unknown tool \(name)", isError: true)
      }
    } catch {
      return .init(text: "\(error)", isError: true)
    }
  }

  private func points(_ args: [String: Any]) throws -> (Double, Double) {
    guard let x = doubleArg(args, "x"), let y = doubleArg(args, "y") else {
      throw ToolError("needs numeric x and y")
    }
    let scale = lock.withLock { pointsPerPixel }
    return (x * scale, y * scale)
  }

  private func button(_ args: [String: Any]) throws -> MouseButton {
    guard let raw = args["button"] as? String else { return .left }
    guard let b = MouseButton(rawValue: raw) else { throw ToolError("button must be left, right or middle") }
    return b
  }

  private func ok(_ s: String) -> CallResult { .init(text: s) }
  private func intArg(_ a: [String: Any], _ k: String) -> Int? { (a[k] as? NSNumber)?.intValue ?? (a[k] as? Int) }
  private func doubleArg(_ a: [String: Any], _ k: String) -> Double? { (a[k] as? NSNumber)?.doubleValue ?? (a[k] as? Double) }
  private func json(_ v: [String: Any]) -> String {
    (try? String(data: JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]), encoding: .utf8)) ?? "{}"
  }
}
