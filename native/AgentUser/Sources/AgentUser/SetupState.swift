import Foundation

/// Where everything lives. Overridable so tests never touch the real prefix.
public struct Paths: Sendable {
  public var prefix: URL
  public var account: String

  public init(prefix: URL = URL(fileURLWithPath: "/Users/Shared/agensis"),
              account: String = "agent") {
    self.prefix = prefix
    self.account = account
  }

  public var computerUseHost: URL { prefix.appending(path: "agensis-cu") }
  public var vncServer: URL { prefix.appending(path: "mac-vnc-server") }
  public var vncPassword: URL { prefix.appending(path: "vnc-pass") }

  /// The permissions receipt is per account: agent2's grants say nothing about
  /// agent3's. The pre-registry layout was a bare `self-test.txt`, which
  /// AgentInspector still honours for the original `agent` account.
  public var selfTest: URL { prefix.appending(path: "self-test-\(account).txt") }
}

/// One setup step's state. `blocked` means an earlier step must land first —
/// shown differently from `todo` so nobody burns time on a step that cannot
/// succeed yet.
public enum StepState: Equatable, Sendable {
  case done(String)
  case todo(String)
  case blocked(String)

  public var isDone: Bool { if case .done = self { return true }; return false }
  public var detail: String {
    switch self {
    case .done(let d), .todo(let d), .blocked(let d): return d
    }
  }
}

public enum Step: String, CaseIterable, Sendable {
  case account, session, hosts, permissions, stream, view

  public var title: String {
    switch self {
    case .account: return "Agent account"
    case .session: return "Signed in"
    case .hosts: return "Hosts installed"
    case .permissions: return "Permissions granted"
    case .stream: return "Screen stream"
    case .view: return "Live view"
    }
  }

  /// Steps only a human can do, and why. Shown in the UI so the manual parts
  /// read as deliberate rather than as something the app failed to automate.
  /// A desktop session is no longer on this list: the helper starts it in the
  /// background, so nothing human stands between an account and its desktop.
  public var humanReason: String? {
    switch self {
    case .account: return "Creating a user needs admin rights."
    case .permissions:
      return "macOS only shows these dialogs inside the account they apply to."
    default: return nil
    }
  }
}

/// Everything the UI needs to decide what to show. Pure data: gathering it is
/// someone else's job, so this is trivially testable.
public struct SetupState: Sendable {
  public var steps: [Step: StepState]

  public init(steps: [Step: StepState] = [:]) { self.steps = steps }

  public subscript(_ s: Step) -> StepState { steps[s] ?? .todo("unknown") }

  /// The first step that is not done. The wizard always points here, because
  /// a later failure is usually just fallout from this one.
  public var current: Step? { Step.allCases.first { !self[$0].isDone } }
  public var isComplete: Bool { current == nil }

  public var progress: Double {
    let done = Step.allCases.filter { self[$0].isDone }.count
    return Double(done) / Double(Step.allCases.count)
  }
}

/// Reads the world. Split from `SetupState` so tests inject facts instead of
/// shelling out.
public protocol SystemProbe: Sendable {
  func userExists(_ name: String) -> Bool
  func hasGUISession(_ name: String) -> Bool
  func isExecutable(_ url: URL) -> Bool
  func portOpen(_ port: UInt16) -> Bool
  func fileOwner(_ url: URL) -> String?
  func contents(_ url: URL) -> String?
  func modified(_ url: URL) -> Date?

  /// Is the computer-use host running for this account? That is the difference
  /// between a desktop you can watch and one something is actually using.
  func isDriving(_ account: String) -> Bool
  /// The frontmost app in that session, when it can be seen. Nil is normal, not
  /// an error — never treat it as "nothing is happening".
  func drivingWhat(_ account: String) -> String?
}

public extension SystemProbe {
  func isDriving(_ account: String) -> Bool { false }
  func drivingWhat(_ account: String) -> String? { nil }
}

public struct SetupInspector: Sendable {
  let probe: SystemProbe
  let paths: Paths
  /// The port this account's stream belongs on — each agent has its own, so a
  /// hardcoded one would describe a different agent's desktop.
  let port: UInt16

  public init(probe: SystemProbe, paths: Paths = Paths(), port: UInt16 = Registry.firstPort) {
    self.probe = probe
    self.paths = paths
    self.port = port
  }

  public func inspect() -> SetupState {
    var s: [Step: StepState] = [:]

    let account = probe.userExists(paths.account)
    s[.account] = account
      ? .done("'\(paths.account)' exists")
      : .todo("no such user yet")

    if !account {
      s[.session] = .blocked("needs the account first")
    } else if probe.hasGUISession(paths.account) {
      s[.session] = .done("desktop running in the background")
    } else {
      s[.session] = .todo("not signed in")
    }

    let hosts = probe.isExecutable(paths.computerUseHost) && probe.isExecutable(paths.vncServer)
    s[.hosts] = hosts
      ? .done("agensis-cu and mac-vnc-server installed")
      : .todo("not built yet")

    s[.permissions] = permissionState(accountExists: account, hostsInstalled: hosts)

    let streamUp = probe.portOpen(port)
    if !s[.permissions]!.isDone && !streamUp {
      s[.stream] = .blocked("needs screen recording")
    } else {
      s[.stream] = streamUp ? .done("serving on \(String(port))") : .todo("not running")
    }

    // Watching is the owner-side app's job; a serving stream is the whole
    // requirement for it, so the stream and the view land together.
    s[.view] = streamUp
      ? .done("watchable from your account")
      : (s[.permissions]!.isDone ? .todo("start the stream first") : .blocked("needs the stream"))

    return SetupState(steps: s)
  }

  /// Permissions are per-account and readable only from inside that account,
  /// so the agent side writes a receipt we verify here. Two things make a
  /// receipt worthless: the wrong author, and a host binary newer than it —
  /// macOS ties TCC grants to the binary's signature, so a rebuild voids them.
  private func permissionState(accountExists: Bool, hostsInstalled: Bool) -> StepState {
    guard accountExists, hostsInstalled else { return .blocked("needs the account and hosts") }
    guard let body = probe.contents(paths.selfTest) else {
      return .todo("unproven — run the agent-side wizard")
    }
    guard probe.fileOwner(paths.selfTest) == paths.account else {
      return .todo("permissions were checked from a different account than '\(paths.account)' — it proves nothing")
    }
    guard body.contains("screenRecording=true"), body.contains("accessibility=true") else {
      return .todo("a permission is denied")
    }
    if let host = probe.modified(paths.computerUseHost),
       let receipt = probe.modified(paths.selfTest), host > receipt {
      return .todo("host rebuilt since — macOS drops grants on a new signature")
    }
    return .done("screen recording and accessibility granted")
  }
}
