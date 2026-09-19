import AppKit
import ApplicationServices
import CoreGraphics

/// The reason this is an app and not a script: running inside the agent's
/// session, it can ask macOS for the grants itself, so the dialogs appear in
/// front of the person instead of sending them hunting through System Settings.
///
/// Nothing here works around a denial. If someone says no, the app says so and
/// stops — what the user grants is exactly what the agent can do.
public enum Permissions {
  public struct Status: Equatable, Sendable {
    public var screenRecording: Bool
    public var accessibility: Bool
    public var both: Bool { screenRecording && accessibility }
  }

  public static func status() -> Status {
    Status(screenRecording: CGPreflightScreenCaptureAccess(),
           accessibility: AXIsProcessTrusted())
  }

  /// Triggers the system dialogs. Returns immediately — macOS answers through
  /// the user, so callers poll `status()` rather than waiting on a result.
  public static func request() {
    if !CGPreflightScreenCaptureAccess() {
      CGRequestScreenCaptureAccess()
    }
    if !AXIsProcessTrusted() {
      // The constant is a global var, which Swift 6 will not let us touch
      // across concurrency domains. Its value is stable and documented.
      let opts = ["AXTrustedCheckOptionPrompt": true]
      _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }
  }

  public enum Pane: String {
    case screenRecording = "Privacy_ScreenCapture"
    case accessibility = "Privacy_Accessibility"
  }

  /// Opens System Settings at the exact pane.
  public static func openSettings(_ pane: Pane) {
    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")!
    NSWorkspace.shared.open(url)
  }

  /// Reveals a binary in Finder so it can be dragged into the permission list.
  ///
  /// This is not belt-and-braces. `agensis-cu` and `mac-vnc-server` are plain
  /// executables, not app bundles, and macOS often will not list them at all
  /// until one is dragged in — the step people get stuck on for ages, because
  /// nothing on screen says it is needed.
  public static func revealForDragging(_ binary: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([binary])
  }

  /// Open the pane and reveal the binary together, which is the pairing that
  /// makes the drag obvious: a Finder window holding the thing, next to the
  /// list it belongs in.
  public static func stageDrag(_ binary: URL, into pane: Pane) {
    openSettings(pane)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
      revealForDragging(binary)
    }
  }
}
