import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Drives the login session this process runs in. All coordinates in/out are
/// display points on the target display; the tool layer converts image pixels
/// to points before calling here.
final class RealDesktop: DesktopControl, @unchecked Sendable {
  /// `.cghidEventTap` posts into the HID stream, which reaches the session the
  /// process belongs to (the reason input worked in the background account);
  /// `.cgSessionEventTap` is the per-session tap. HID is the reliable default.
  let eventTap: CGEventTapLocation

  init(eventTap: CGEventTapLocation = .cghidEventTap) {
    self.eventTap = eventTap
  }

  var targetDisplay: CGDirectDisplayID { CGMainDisplayID() }

  func permissions() -> PermissionState {
    PermissionState(screenRecording: CGPreflightScreenCaptureAccess(),
                    accessibility: CGPreflightPostEventAccess())
  }

  func displays() -> [DisplaySummary] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
    return ids.prefix(Int(count)).map { id in
      let b = CGDisplayBounds(id)
      return DisplaySummary(id: id, x: b.origin.x, y: b.origin.y, width: b.width, height: b.height,
                            isMain: CGDisplayIsMain(id) != 0)
    }
  }

  func targetWidthPoints() -> Double {
    let w = CGDisplayBounds(targetDisplay).width
    return w > 0 ? w : 1280
  }

  func capture(maxWidth: Int, quality: Double) throws -> Capture {
    guard CGPreflightScreenCaptureAccess() else {
      throw ToolError("Screen Recording is not granted to agensis-cu in \(NSUserName())'s account. Ask the user to allow it, then call permissions.")
    }
    let displayID = targetDisplay
    let bounds = CGDisplayBounds(displayID)
    guard bounds.width > 0, bounds.height > 0 else {
      throw ToolError("this session has no active display to capture")
    }
    let width = min(Int(bounds.width), max(64, maxWidth))
    let height = Int((Double(width) * bounds.height / bounds.width).rounded())
    let jpeg = try blockingAwait(timeout: 12) {
      try await Self.captureJPEG(displayID: displayID, width: width, height: height, quality: quality)
    }
    return Capture(jpeg: jpeg, width: width, height: height, pointsPerPixel: bounds.width / Double(width))
  }

  private static func captureJPEG(displayID: CGDirectDisplayID, width: Int, height: Int,
                                  quality: Double) async throws -> Data {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
      throw ToolError("ScreenCaptureKit lists no display \(displayID) in this session")
    }
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let config = SCStreamConfiguration()
    config.width = width
    config.height = height
    config.showsCursor = true
    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
      throw ToolError("cannot create JPEG encoder")
    }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw ToolError("JPEG encode failed") }
    return out as Data
  }

  private var origin: CGPoint { CGDisplayBounds(targetDisplay).origin }
  private func global(_ x: Double, _ y: Double) -> CGPoint {
    CGPoint(x: origin.x + x, y: origin.y + y)
  }
  private var source: CGEventSource? { CGEventSource(stateID: .combinedSessionState) }

  func moveCursor(toPoints x: Double, _ y: Double) {
    post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                 mouseCursorPosition: global(x, y), mouseButton: .left))
  }

  func click(atPoints x: Double, _ y: Double, button: MouseButton, count: Int) {
    let p = global(x, y)
    let (down, up, cg) = Self.types(button)
    post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: cg))
    for n in 1...max(1, count) {
      for type in [down, up] {
        let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: cg)
        e?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
        post(e)
      }
    }
  }

  func mouseDown(atPoints x: Double, _ y: Double, button: MouseButton) {
    let (down, _, cg) = Self.types(button)
    post(CGEvent(mouseEventSource: source, mouseType: down, mouseCursorPosition: global(x, y), mouseButton: cg))
  }

  func mouseUp(atPoints x: Double, _ y: Double, button: MouseButton) {
    let (_, up, cg) = Self.types(button)
    post(CGEvent(mouseEventSource: source, mouseType: up, mouseCursorPosition: global(x, y), mouseButton: cg))
  }

  func scroll(atPoints x: Double, _ y: Double, dxPoints: Double, dyPoints: Double) {
    post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                 mouseCursorPosition: global(x, y), mouseButton: .left))
    post(CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                 wheel1: Int32(-dyPoints), wheel2: Int32(-dxPoints), wheel3: 0))
  }

  func typeText(_ text: String) {
    // Unicode string events preserve case and layout-independence; newlines
    // become real Return presses so multi-line input submits naturally.
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    for (i, line) in lines.enumerated() {
      typeUnicode(String(line))
      if i < lines.count - 1 { tap(keyCode: 36, flags: 0) }
    }
  }

  func pressChord(_ chord: KeyChord) {
    tap(keyCode: chord.keyCode, flags: chord.flags)
  }

  func cursorPointLocation() -> (Double, Double) {
    let p = CGEvent(source: nil)?.location ?? .zero
    return (p.x - origin.x, p.y - origin.y)
  }

  func openTarget(_ target: String, isApp: Bool) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = isApp ? ["-a", target] : [target]
    let pipe = Pipe()
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus == 0 {
      return isApp ? "launched app \(target)" : "opened \(target)"
    }
    let err = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    throw ToolError("open failed (\(process.terminationStatus)): \(err.trimmingCharacters(in: .whitespacesAndNewlines))")
  }

  private func typeUnicode(_ text: String) {
    let units = Array(text.utf16)
    var i = 0
    while i < units.count {
      let chunk = Array(units[i..<min(i + 20, units.count)])
      for down in [true, false] {
        let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
        chunk.withUnsafeBufferPointer { e?.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
        post(e)
      }
      i += 20
    }
  }

  private func tap(keyCode: UInt16, flags: UInt64) {
    for down in [true, false] {
      let e = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)
      e?.flags = CGEventFlags(rawValue: flags)
      post(e)
    }
  }

  private func post(_ event: CGEvent?) {
    event?.post(tap: eventTap)
    usleep(8_000)
  }

  private static func types(_ button: MouseButton) -> (CGEventType, CGEventType, CGMouseButton) {
    switch button {
    case .left: (.leftMouseDown, .leftMouseUp, .left)
    case .right: (.rightMouseDown, .rightMouseUp, .right)
    case .middle: (.otherMouseDown, .otherMouseUp, .center)
    }
  }
}

private final class Box<T: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Result<T, Error>?
  func set(_ v: Result<T, Error>) { lock.withLock { value = v } }
  func get() -> Result<T, Error>? { lock.withLock { value } }
}

/// Runs an async ScreenCaptureKit call to completion on a blocking thread.
func blockingAwait<T: Sendable>(timeout: TimeInterval,
                                _ body: @escaping @Sendable () async throws -> T) throws -> T {
  let box = Box<T>()
  let done = DispatchSemaphore(value: 0)
  Task.detached {
    do { box.set(.success(try await body())) } catch { box.set(.failure(error)) }
    done.signal()
  }
  guard done.wait(timeout: .now() + timeout) == .success, let result = box.get() else {
    throw ToolError("timed out after \(Int(timeout))s")
  }
  return try result.get()
}
