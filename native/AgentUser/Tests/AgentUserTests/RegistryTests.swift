import Testing
import Foundation
@testable import AgentUser

@Test func firstAgentTakesTheOriginalAccountAndPort() {
  var r = Registry()
  let a = r.add(name: "Scout")
  #expect(a.account == "agent")
  #expect(a.port == 5902)
}

@Test func laterAgentsGetTheirOwnAccountAndPort() {
  var r = Registry()
  _ = r.add(name: "Scout")
  let b = r.add(name: "Builder")
  let c = r.add(name: "Researcher")
  #expect(b.account == "agent2" && b.port == 5903)
  #expect(c.account == "agent3" && c.port == 5904)
}

/// Removing an agent should free its number rather than leaving a hole that
/// pushes every later agent further up.
@Test func removingAnAgentFreesItsPort() {
  var r = Registry()
  _ = r.add(name: "A"); _ = r.add(name: "B"); _ = r.add(name: "C")
  r.agents.removeAll { $0.account == "agent2" }
  #expect(r.nextPort() == 5903)
  #expect(r.nextAccount() == "agent2")
}

@Test func registrySurvivesARoundTrip() throws {
  var r = Registry()
  _ = r.add(name: "Scout"); _ = r.add(name: "Builder")
  let data = try JSONEncoder.registry.encode(r)
  #expect(try JSONDecoder.registry.decode(Registry.self, from: data) == r)
}

/// A machine set up before the registry existed has an `agent` account and no
/// file. It must be adopted, not shown as an empty list.
@Test func aPreRegistryMachineIsAdopted() {
  var p = FakeProbe(); p.users = ["agent"]
  let r = RegistryStore.load(prefix: URL(fileURLWithPath: "/nonexistent"), probe: p)
  #expect(r.agents.count == 1)
  #expect(r.agents.first?.account == "agent")
  #expect(r.agents.first?.port == 5902)
}

@Test func aCleanMachineStartsEmpty() {
  let r = RegistryStore.load(prefix: URL(fileURLWithPath: "/nonexistent"), probe: FakeProbe())
  #expect(r.agents.isEmpty)
}

// MARK: - per-agent status

private func agent(_ account: String = "agent", port: UInt16 = 5902) -> Agent {
  Agent(name: "Scout", account: account, port: port)
}

private let prefix = Paths().prefix

/// A fully set-up agent, which each test then breaks in one way.
private func ready(_ a: Agent) -> FakeProbe {
  let receipt = prefix.appending(path: "self-test-\(a.account).txt").path
  return FakeProbe(
    users: [a.account], sessions: [a.account], ports: [a.port],
    owners: [receipt: a.account],
    files: [receipt: "screenRecording=true accessibility=true"]
  )
}

@Test func aServingDesktopWithNothingAttachedIsIdle() {
  let a = agent()
  #expect(AgentInspector(probe: ready(a)).status(for: a) == .idle(canDrive: true))
}

@Test func aSignedOutAccountSaysSoRatherThanWaiting() {
  let a = agent()
  var p = ready(a); p.sessions = []
  #expect(AgentInspector(probe: p).status(for: a) == .signedOut)
}

@Test func aSignedInAgentWithNoStreamIsWaiting() {
  let a = agent()
  var p = ready(a); p.ports = []
  #expect(AgentInspector(probe: p).status(for: a) == .waiting)
}

/// A serving stream can be watched whether or not the agent's own grants have
/// landed. Holding the view back would hide a desktop that is demonstrably
/// streaming — the bug this test exists to prevent.
@Test func aServingStreamIsWatchableEvenBeforeTheAgentCanDriveIt() {
  let a = agent()
  var p = ready(a); p.files = [:]
  let status = AgentInspector(probe: p).status(for: a)
  #expect(status.watchable)
  #expect(status == .idle(canDrive: false))
  #expect(status.detail.contains("watch only"))
}

@Test func anUngrantedAgentWithNoStreamReportsThePermissions() {
  let a = agent()
  var p = ready(a); p.files = [:]; p.ports = []
  if case .notSetUp = AgentInspector(probe: p).status(for: a) {} else {
    Issue.record("with no stream, the unmet permission is the useful thing to say")
  }
}

/// Each agent's receipt is its own. One being ready says nothing about another.
/// Each agent's receipt is its own. One being ready says nothing about another.
@Test func oneAgentsReceiptDoesNotVouchForAnother() {
  let first = agent(), second = agent("agent2", port: 5903)
  var p = ready(first)
  p.users.insert(second.account); p.sessions.insert(second.account)
  #expect(AgentInspector(probe: p).hands(for: second) != .granted)
  #expect(AgentInspector(probe: p).hands(for: first) == .granted)
}

@Test func onlyServingAgentsCanBeWatched() {
  #expect(AgentStatus.idle(canDrive: true).watchable)
  #expect(AgentStatus.live(nil).watchable)
  #expect(!AgentStatus.waiting.watchable)
  #expect(!AgentStatus.signedOut.watchable)
  #expect(!AgentStatus.notSetUp("x").watchable)
}
