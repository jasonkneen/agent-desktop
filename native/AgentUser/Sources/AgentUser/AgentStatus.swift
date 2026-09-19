import Foundation

/// What a row in the list says. Ordered worst to best, so a list can be sorted
/// by "needs me most".
public enum AgentStatus: Equatable, Sendable {
  case notSetUp(String)   // account exists, setup unfinished — reason attached
  case signedOut          // nobody logged in; needs a human, every restart
  case waiting            // signed in, stream not up yet
  case idle(canDrive: Bool)   // stream up, nothing driving it
  case live(String?)          // stream up and an agent is working; what, if known

  public var label: String {
    switch self {
    case .notSetUp: return "SET UP"
    case .signedOut: return "SIGNED OUT"
    case .waiting: return "WAITING"
    case .idle: return "IDLE"
    case .live: return "LIVE"
    }
  }

  /// Can you open the viewer on it? Only when a stream is actually serving.
  public var watchable: Bool {
    switch self {
    case .idle, .live: return true
    default: return false
    }
  }

  public var detail: String {
    switch self {
    case .notSetUp(let why): return why
    case .signedOut: return "signed out since the last restart"
    case .waiting: return "signed in, stream not up"
    case .idle(let canDrive):
      return canDrive ? "idle, nothing connected"
                      : "watch only — the agent cannot drive it yet"
    case .live(let what): return what.map { "driving \($0)" } ?? "an agent is working"
    }
  }

  /// What the one button on the row does.
  public var action: String {
    switch self {
    case .notSetUp: return "Set up"
    case .signedOut: return "How"
    case .waiting: return "Start"
    case .idle, .live: return "Watch"
    }
  }
}

public struct AgentRow: Identifiable, Equatable, Sendable {
  public var agent: Agent
  public var status: AgentStatus
  public var id: String { agent.id }
}

/// Whether the computer-use host has its grants in that account. Separate from
/// whether you can watch: the stream is the eyes, agensis-cu is the hands, and
/// they are granted independently.
public enum Hands: Equatable, Sendable {
  case granted
  case unproven(String)
}

/// Turns the registry plus the machine's actual state into rows.
public struct AgentInspector: Sendable {
  let probe: SystemProbe
  let paths: Paths

  public init(probe: SystemProbe, paths: Paths = Paths()) {
    self.probe = probe
    self.paths = paths
  }

  public func rows(_ registry: Registry) -> [AgentRow] {
    registry.agents.map { AgentRow(agent: $0, status: status(for: $0)) }
  }

  public func status(for agent: Agent) -> AgentStatus {
    guard probe.userExists(agent.account) else {
      return .notSetUp("account not created yet")
    }
    guard probe.hasGUISession(agent.account) else { return .signedOut }

    // A serving port is the whole requirement for watching. The agent's own
    // grants are a separate question, and holding back the view until they
    // land would hide a desktop that is demonstrably streaming.
    guard probe.portOpen(agent.port) else {
      if case .unproven(let why) = hands(for: agent) { return .notSetUp(why) }
      return .waiting
    }
    if probe.isDriving(agent.account) { return .live(probe.drivingWhat(agent.account)) }
    return .idle(canDrive: hands(for: agent) == .granted)
  }

  /// Permissions can only be read inside the account they apply to, so the
  /// agent side writes a receipt. Per agent: one being set up says nothing
  /// about another.
  public func hands(for agent: Agent) -> Hands {
    let receipt = paths.prefix.appending(path: "self-test-\(agent.account).txt")
    let legacy = paths.selfTest  // the single-agent layout, before the registry
    let isFirst = agent.account == "agent"
    let proof = probe.contents(receipt) ?? (isFirst ? probe.contents(legacy) : nil)
    let owner = probe.fileOwner(receipt) ?? (isFirst ? probe.fileOwner(legacy) : nil)

    guard let proof else { return .unproven("permissions not granted yet") }
    guard owner == agent.account else {
      return .unproven("the receipt was not written by \(agent.account)")
    }
    guard proof.contains("screenRecording=true"), proof.contains("accessibility=true") else {
      return .unproven("a permission is denied")
    }
    return .granted
  }
}
