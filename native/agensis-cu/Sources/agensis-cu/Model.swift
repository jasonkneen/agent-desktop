import Foundation

/// A JPEG screenshot plus the scale needed to turn image pixels back into
/// display points. The agent sees and clicks in image-pixel space; every action
/// multiplies by `pointsPerPixel` before it reaches the display.
struct Capture: Sendable {
  var jpeg: Data
  var width: Int
  var height: Int
  var pointsPerPixel: Double
}

struct DisplaySummary: Codable, Sendable {
  var id: UInt32
  var x: Double
  var y: Double
  var width: Double
  var height: Double
  var isMain: Bool
}

struct PermissionState: Codable, Sendable {
  var screenRecording: Bool
  var accessibility: Bool
}

enum MouseButton: String, Sendable, CaseIterable {
  case left, right, middle
}

/// The surface the MCP tools call. `RealDesktop` drives the live session;
/// tests substitute a fake so tool routing and coordinate math run without any
/// TCC grant or window server.
protocol DesktopControl: Sendable {
  func permissions() -> PermissionState
  func displays() -> [DisplaySummary]
  /// Display points across the whole targeted region, used to scale coordinates
  /// before any capture has fixed a scale on this connection.
  func targetWidthPoints() -> Double
  func capture(maxWidth: Int, quality: Double) throws -> Capture
  func moveCursor(toPoints x: Double, _ y: Double)
  func click(atPoints x: Double, _ y: Double, button: MouseButton, count: Int)
  func mouseDown(atPoints x: Double, _ y: Double, button: MouseButton)
  func mouseUp(atPoints x: Double, _ y: Double, button: MouseButton)
  func scroll(atPoints x: Double, _ y: Double, dxPoints: Double, dyPoints: Double)
  func typeText(_ text: String)
  func pressChord(_ chord: KeyChord)
  func cursorPointLocation() -> (Double, Double)
  /// Launches an app by name (open -a) or opens a URL/file (open). Returns the
  /// human-readable result. Governed by the same account permissions.
  func openTarget(_ target: String, isApp: Bool) throws -> String
}

struct ToolError: Error, CustomStringConvertible {
  var message: String
  var description: String { message }
  init(_ message: String) { self.message = message }
}
