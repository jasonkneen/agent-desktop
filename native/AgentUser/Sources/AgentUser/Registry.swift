import Foundation

/// One agent: a macOS account, a desktop, a port. Two agents never share a
/// desktop — macOS gives one session per account, and two agents on one screen
/// would fight over the pointer.
public struct Agent: Codable, Identifiable, Equatable, Sendable {
  public var name: String        // what you call it: "Scout"
  public var account: String     // the macOS account: "agent2"
  public var port: UInt16        // its VNC port: 5903
  public var addedAt: Date

  public var id: String { account }

  public init(name: String, account: String, port: UInt16, addedAt: Date = Date()) {
    self.name = name
    self.account = account
    self.port = port
    // Whole seconds: the registry is stored as ISO-8601, which has no
    // sub-second precision, so keeping any would make a decoded Agent unequal
    // to the one that was written.
    self.addedAt = Date(timeIntervalSince1970: addedAt.timeIntervalSince1970.rounded(.down))
  }
}

/// The list of agents, on disk at `<prefix>/agents.json`.
///
/// Explicit beats inference: guessing from account names would pick up any
/// account that happened to start with "agent", and would have no way to store
/// a display name or a port.
public struct Registry: Codable, Equatable, Sendable {
  public var agents: [Agent]

  public init(agents: [Agent] = []) { self.agents = agents }

  public static let firstPort: UInt16 = 5902

  /// Lowest free port at or above 5902, so removing an agent lets the next one
  /// reuse its number rather than drifting upward forever.
  public func nextPort() -> UInt16 {
    let taken = Set(agents.map(\.port))
    var p = Self.firstPort
    while taken.contains(p) { p += 1 }
    return p
  }

  /// `agent`, then `agent2`, `agent3`… matching how the docs and the original
  /// single-agent setup already name things.
  public func nextAccount() -> String {
    let taken = Set(agents.map(\.account))
    if !taken.contains("agent") { return "agent" }
    var n = 2
    while taken.contains("agent\(n)") { n += 1 }
    return "agent\(n)"
  }

  public func agent(account: String) -> Agent? {
    agents.first { $0.account == account }
  }

  public mutating func add(name: String) -> Agent {
    let a = Agent(name: name, account: nextAccount(), port: nextPort())
    agents.append(a)
    return a
  }

  /// For an account created outside the registry (the setup helper makes it
  /// before registration): keep the account and port that were actually
  /// created rather than recomputing them, so the registry matches reality.
  public mutating func add(name: String, account: String, port: UInt16) -> Agent {
    let a = Agent(name: name, account: account, port: port)
    agents.append(a)
    return a
  }
}

public enum RegistryStore {
  public static func url(prefix: URL) -> URL { prefix.appending(path: "agents.json") }

  /// A machine set up before the registry existed has an `agent` account and no
  /// file. Rather than showing an empty list and losing it, adopt it.
  public static func load(prefix: URL, probe: SystemProbe) -> Registry {
    let file = url(prefix: prefix)
    if let data = try? Data(contentsOf: file),
       let reg = try? JSONDecoder.registry.decode(Registry.self, from: data) {
      return reg
    }
    if probe.userExists("agent") {
      return Registry(agents: [Agent(name: "Agent", account: "agent", port: Registry.firstPort)])
    }
    return Registry()
  }

  @discardableResult
  public static func save(_ reg: Registry, prefix: URL) -> Bool {
    guard let data = try? JSONEncoder.registry.encode(reg) else { return false }
    return (try? data.write(to: url(prefix: prefix), options: .atomic)) != nil
  }
}

extension JSONDecoder {
  static var registry: JSONDecoder {
    let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
  }
}

extension JSONEncoder {
  static var registry: JSONEncoder {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    return e
  }
}
