import Foundation
@testable import agensis_cu

/// Records every call so tests can assert routing and coordinate scaling
/// without a real screen or any TCC grant.
final class FakeDesktop: DesktopControl, @unchecked Sendable {
  struct Event: Equatable { var kind: String; var a: Double; var b: Double; var c: Double; var s: String }
  private let lock = NSLock()
  private(set) var events: [Event] = []
  var widthPoints: Double = 2560
  var perms = PermissionState(screenRecording: true, accessibility: true)
  var captureScale: Double = 2.0

  private func record(_ e: Event) { lock.withLock { events.append(e) } }

  func permissions() -> PermissionState { perms }
  func displays() -> [DisplaySummary] {
    [DisplaySummary(id: 1, x: 0, y: 0, width: widthPoints, height: 1440, isMain: true)]
  }
  func targetWidthPoints() -> Double { widthPoints }
  func capture(maxWidth: Int, quality: Double) throws -> Capture {
    if !perms.screenRecording { throw ToolError("no screen recording") }
    record(Event(kind: "capture", a: Double(maxWidth), b: quality, c: 0, s: ""))
    return Capture(jpeg: Data([0xff, 0xd8, 0xff]), width: 1280, height: 720, pointsPerPixel: captureScale)
  }
  func moveCursor(toPoints x: Double, _ y: Double) { record(Event(kind: "move", a: x, b: y, c: 0, s: "")) }
  func click(atPoints x: Double, _ y: Double, button: MouseButton, count: Int) {
    record(Event(kind: "click", a: x, b: y, c: Double(count), s: button.rawValue))
  }
  func mouseDown(atPoints x: Double, _ y: Double, button: MouseButton) {
    record(Event(kind: "down", a: x, b: y, c: 0, s: button.rawValue))
  }
  func mouseUp(atPoints x: Double, _ y: Double, button: MouseButton) {
    record(Event(kind: "up", a: x, b: y, c: 0, s: button.rawValue))
  }
  func scroll(atPoints x: Double, _ y: Double, dxPoints: Double, dyPoints: Double) {
    record(Event(kind: "scroll", a: x, b: y, c: dyPoints, s: ""))
  }
  func typeText(_ text: String) { record(Event(kind: "type", a: 0, b: 0, c: 0, s: text)) }
  func pressChord(_ chord: KeyChord) { record(Event(kind: "key", a: Double(chord.keyCode), b: Double(chord.flags), c: 0, s: "")) }
  func cursorPointLocation() -> (Double, Double) { (10, 20) }
  func openTarget(_ target: String, isApp: Bool) throws -> String {
    record(Event(kind: isApp ? "launch" : "open", a: 0, b: 0, c: 0, s: target))
    return "did \(target)"
  }
}
