import Foundation
import SetupCore

/// Runs the root helper that creates the agent's macOS account.
///
/// The app never holds root itself: it asks osascript for the standard
/// administrator prompt, and the helper does the OpenDirectory work as root
/// and hands back JSON. The generated password travels only root → pass
/// file; the app reads that file afterwards as the console user.
enum AccountCreator {
  enum CreationError: LocalizedError {
    case helperMissing
    case cancelled
    case badName(String)
    case failed(String)

    var errorDescription: String? {
      switch self {
      case .helperMissing:
        "The setup helper is not installed. Reinstall Agent Desktop (scripts/install.sh) and try again."
      case .cancelled:
        nil   // the user dismissed the admin prompt; not an error worth a dialog
      case .badName(let why): why
      case .failed(let why): why
      }
    }
  }

  struct Outcome {
    var result: CreationResult
    var password: String
  }

  /// The helper inside our own bundle first (that is where a DMG install
  /// puts it), falling back to the prefix (where install.sh puts it).
  static func helperURL() -> URL {
    if let exe = Bundle.main.executableURL {
      let sibling = exe.deletingLastPathComponent().appending(path: "agentdesktop-setup")
      if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }
    }
    return Paths().prefix.appending(path: "agentdesktop-setup")
  }

  static func available() -> Bool {
    FileManager.default.isExecutableFile(atPath: helperURL().path)
  }

  /// Shell-quote a value for the do shell script string. The account and
  /// display names come from our own UI, but the helper re-validates
  /// everything anyway; quoting is defence, not the safety story.
  private static func sh(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  static func create(account: String, display: String) async throws -> Outcome {
    if let why = AccountName.reason(account) { throw CreationError.badName(why) }
    let helper = helperURL().path
    guard FileManager.default.isExecutableFile(atPath: helper) else {
      throw CreationError.helperMissing
    }

    let ownerUID = UInt32(getuid())
    let passFile = Paths().prefix.appending(path: account + "-pass").path

    let command =
      "\(sh(helper)) create --account \(sh(account)) --display \(sh(display)) " +
      "--owner-uid \(ownerUID) --pass-file \(sh(passFile))"
    let script =
      "do shell script \(sh(command)) with administrator privileges " +
      "with prompt \(sh("Agent Desktop wants to create the macOS account “\(account)”"))"

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    proc.arguments = ["-e", script]
    let out = Pipe(), err = Pipe()
    proc.standardOutput = out
    proc.standardError = err
    try proc.run()
    let stdout = out.fileHandleForReading.readDataToEndOfFile()
    let stderr = err.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()

    guard proc.terminationStatus == 0 else {
      let message = String(decoding: stderr, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if message.contains("User canceled") || message.contains("(-128)") {
        throw CreationError.cancelled
      }
      // The helper writes its refusal reason to stderr; surface it as-is.
      throw CreationError.failed(message.isEmpty ? "the setup helper failed" : message)
    }

    do {
      let result = try JSONDecoder().decode(CreationResult.self, from: stdout)
      let password = String(decoding: try Data(contentsOf: URL(fileURLWithPath: passFile)),
                            as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !password.isEmpty else { throw CreationError.failed("the pass file is empty") }
      return Outcome(result: result, password: password)
    } catch let e as CreationError {
      throw e
    } catch {
      throw CreationError.failed("could not read the setup helper's result: \(error.localizedDescription)")
    }
  }
}
