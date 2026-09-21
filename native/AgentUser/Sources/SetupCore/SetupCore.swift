import Foundation

/// Shared between the app and the root helper, so both sides validate the
/// same request the same way. Kept dependency-free on purpose: the helper
/// runs as root and should link as little as possible.

/// The account name rules. Mirrors what Directory Services accepts for a
/// short name, tightened to what this tool should ever create.
public enum AccountName {
  /// Accounts this tool must never touch, even though they pass the pattern.
  public static let reserved: Set<String> = [
    "root", "daemon", "nobody", "admin", "administrator",
    "daemon", "sshd", "_windowserver", "jamf", "support",
  ]

  public static func valid(_ name: String) -> Bool {
    guard !reserved.contains(name), name.count <= 20 else { return false }
    guard let first = name.first, first.isLowercase || first == "_" else { return false }
    return name.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "_" }
  }

  public static func reason(_ name: String) -> String? {
    if name.isEmpty { return "the account name is empty" }
    if reserved.contains(name) { return "‘\(name)’ is a reserved system account name" }
    if name.count > 20 { return "the account name is over 20 characters" }
    guard let first = name.first, first.isLowercase || first == "_" else {
      return "the account name must start with a lowercase letter"
    }
    guard name.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "_" }) else {
      return "the account name may use only lowercase letters, digits and underscores"
    }
    return nil
  }
}

/// What the app asks the helper to do. The password is deliberately absent:
/// the helper generates it as root and writes it straight to the pass file,
/// so it never crosses a process boundary or a command line.
///
/// `vncPort`/`vncPassFile` are optional: when present, the helper also
/// installs the per-user LaunchAgents that start the stream (and the app,
/// which in the agent's account is the permissions wizard) at every login,
/// and bootstraps them into the account's session straight away if it is
/// already signed in. Without them, a freshly created account logs in to an
/// empty desktop and nothing ever starts — the gap this caused once.
public struct CreationRequest: Codable, Equatable, Sendable {
  public var account: String
  public var display: String     // the agent's human name: "Scout"
  public var ownerUID: UInt32    // the console user; gets the pass file
  public var passFile: String
  public var vncPort: UInt16?
  public var vncPassFile: String?

  public init(account: String, display: String, ownerUID: UInt32, passFile: String,
              vncPort: UInt16? = nil, vncPassFile: String? = nil) {
    self.account = account
    self.display = display
    self.ownerUID = ownerUID
    self.passFile = passFile
    self.vncPort = vncPort
    self.vncPassFile = vncPassFile
  }
}

/// What the helper reports on success. The password is not in here — read
/// the pass file instead. `session` is the SkyLight session id of the
/// background login (non-zero when the account was signed in without a
/// human); `sessionConfirmed` says the session actually appeared in the
/// session list, not just that the call returned success.
public struct CreationResult: Codable, Equatable, Sendable {
  public var account: String
  public var uid: UInt32
  public var home: String
  public var session: UInt32?
  public var sessionConfirmed: Bool?

  public init(account: String, uid: UInt32, home: String) {
    self.account = account
    self.uid = uid
    self.home = home
  }

  public var signedIn: Bool { (session ?? 0) != 0 }
}
