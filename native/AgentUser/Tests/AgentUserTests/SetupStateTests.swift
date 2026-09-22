import Testing
import Foundation
@testable import AgentUser

/// Facts, injected. No shelling out, so these say something about the logic
/// rather than about this machine.
struct FakeProbe: SystemProbe {
  var users: Set<String> = []
  var sessions: Set<String> = []
  var executables: Set<String> = []
  var ports: Set<UInt16> = []
  var owners: [String: String] = [:]
  var files: [String: String] = [:]
  var times: [String: Date] = [:]

  func userExists(_ name: String) -> Bool { users.contains(name) }
  func hasGUISession(_ name: String) -> Bool { sessions.contains(name) }
  func isExecutable(_ url: URL) -> Bool { executables.contains(url.path) }
  func portOpen(_ port: UInt16) -> Bool { ports.contains(port) }
  func fileOwner(_ url: URL) -> String? { owners[url.path] }
  func contents(_ url: URL) -> String? { files[url.path] }
  func modified(_ url: URL) -> Date? { times[url.path] }
}

private let paths = Paths()

/// A machine with everything in place, which each test then breaks in one way.
private func healthy() -> FakeProbe {
  FakeProbe(
    users: ["agent"],
    sessions: ["agent"],
    executables: [paths.computerUseHost.path, paths.vncServer.path],
    ports: [5902, 6080],
    owners: [paths.selfTest.path: "agent"],
    files: [paths.selfTest.path: "screenRecording=true accessibility=true"],
    times: [paths.computerUseHost.path: Date(timeIntervalSince1970: 100),
            paths.selfTest.path: Date(timeIntervalSince1970: 200)]
  )
}

@Test func fullyConfiguredMachineIsComplete() {
  let s = SetupInspector(probe: healthy()).inspect()
  #expect(s.isComplete)
  #expect(s.progress == 1.0)
}

@Test func missingAccountBlocksTheSession() {
  var p = healthy(); p.users = []; p.sessions = []
  let s = SetupInspector(probe: p).inspect()
  #expect(s.current == .account)
  if case .blocked = s[.session] {} else {
    Issue.record("session should be blocked, not merely todo, when no account exists")
  }
}

/// The failure that cost the most: a receipt written from the user's own
/// session proves nothing, because `su` keeps the caller's login session.
@Test func receiptFromTheWrongAccountIsRejected() {
  var p = healthy()
  p.owners[paths.selfTest.path] = "console-user"
  let s = SetupInspector(probe: p).inspect()
  #expect(!s[.permissions].isDone)
  #expect(s[.permissions].detail.contains("proves nothing"))
}

/// macOS ties TCC grants to the binary's signature, so a rebuild silently
/// voids them. An old receipt must not keep the row green.
@Test func rebuildingAHostInvalidatesAnOlderReceipt() {
  var p = healthy()
  p.times[paths.computerUseHost.path] = Date(timeIntervalSince1970: 300)
  let s = SetupInspector(probe: p).inspect()
  #expect(!s[.permissions].isDone)
}

@Test func deniedPermissionIsNotTreatedAsGranted() {
  var p = healthy()
  p.files[paths.selfTest.path] = "screenRecording=true accessibility=false"
  #expect(!SetupInspector(probe: p).inspect()[.permissions].isDone)
}

@Test func missingReceiptIsUnprovenRatherThanGranted() {
  var p = healthy(); p.files = [:]
  let s = SetupInspector(probe: p).inspect()
  #expect(!s[.permissions].isDone)
  #expect(s[.permissions].detail.contains("unproven"))
}

/// The server's own self-check outranks the receipt — the fix for "all
/// approved" sitting next to a read-only view. When the binary reports
/// directly, a flattering receipt counts for nothing.
@Test func serverSelfCheckOverridesAFlatteringReceipt() {
  var p = healthy()
  p.files[paths.selfTest.path] = "screenRecording=true accessibility=true"   // the app vouching
  var sp = ServerPermissions()
  sp.screenRecording = false   // the server, the one that matters: cannot even capture
  #expect(!SetupInspector(probe: p).inspect(serverPermissions: sp)[.permissions].isDone)
}

/// Same shape, the good direction: everything the server reports is granted,
/// so the step is done even when the receipt never landed.
@Test func serverSelfCheckAloneProvesTheGrants() {
  var p = healthy(); p.files = [:]
  var sp = ServerPermissions()
  sp.screenRecording = true; sp.postEvent = true; sp.accessibility = true
  #expect(SetupInspector(probe: p).inspect(serverPermissions: sp)[.permissions].isDone)
}

/// The exact live failure: server could see (screen recording granted) but
/// not click. The step must say watch-only, not done, and name the pane.
@Test func serverThatCannotClickIsWatchOnly() {
  var sp = ServerPermissions()
  sp.screenRecording = true; sp.postEvent = true
  let s = SetupInspector(probe: healthy()).inspect(serverPermissions: sp)
  #expect(!s[.permissions].isDone)
  #expect(s[.permissions].detail.contains("watch-only"))
  #expect(s[.permissions].detail.contains("Device Control and Data Access"))
}

@Test func streamIsBlockedUntilPermissionsLand() {
  var p = healthy(); p.files = [:]; p.ports = []
  let s = SetupInspector(probe: p).inspect()
  if case .blocked = s[.stream] {} else {
    Issue.record("the stream cannot start without screen recording")
  }
}

@Test func wizardAlwaysPointsAtTheFirstUnfinishedStep() {
  var p = healthy(); p.executables = []
  #expect(SetupInspector(probe: p).inspect().current == .hosts)
}

/// Receipts are per agent: agent3's grants say nothing about agent's, so the
/// file names must differ. The pre-registry bare self-test.txt stays honoured
/// by AgentInspector for the original account.
@Test func receiptPathsArePerAccount() {
  #expect(Paths(account: "agent3").selfTest.path.hasSuffix("self-test-agent3.txt"))
  #expect(Paths(account: "agent").selfTest.path.hasSuffix("self-test-agent.txt"))
}

/// Each agent streams on its own port. A wizard that checked a hardcoded one
/// would report a streaming agent as "not running" — and start a second
/// stream on the first agent's port.
@Test func theStreamIsCheckedOnThisAgentsPort() {
  var p = healthy(); p.ports = [5904]   // 5902 closed, 5904 serving
  let s = SetupInspector(probe: p, port: 5904).inspect()
  #expect(s[.stream].isDone)
  #expect(s[.stream].detail.contains("5904"))
  #expect(!SetupInspector(probe: p).inspect()[.stream].isDone)   // default port: honest
}
