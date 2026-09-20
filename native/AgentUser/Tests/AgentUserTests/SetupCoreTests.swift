import Testing
import Foundation
@testable import SetupCore
@testable import AgentUser

/// The name rules are the safety rail between the UI and a root helper, so
/// they get their own tests: what the helper refuses, the app must refuse
/// first, and identically.
@Suite struct SetupCoreTests {
  @Test func acceptsPlainAgentNames() {
    for good in ["agent", "agent2", "scout", "a1_b2", "_helper"] {
      #expect(AccountName.valid(good), "expected \(good) to be accepted")
      #expect(AccountName.reason(good) == nil)
    }
  }

  @Test func rejectsBadCharacters() {
    for bad in ["Agent2", "agent 2", "agent-2", "2agent", "", "agent$"] {
      #expect(!AccountName.valid(bad), "expected \(bad) to be rejected")
      #expect(AccountName.reason(bad) != nil)
    }
  }

  @Test func rejectsReservedSystemNames() {
    for bad in AccountName.reserved {
      #expect(!AccountName.valid(bad), "expected \(bad) to be rejected")
    }
  }

  @Test func rejectsLongNames() {
    #expect(AccountName.valid(String(repeating: "a", count: 20)))
    #expect(!AccountName.valid(String(repeating: "a", count: 21)))
  }

  @Test func requestRoundTrips() throws {
    let request = CreationRequest(account: "agent2", display: "Scout",
                                  ownerUID: 501, passFile: "/Users/Shared/agensis/agent2-pass")
    let data = try JSONEncoder().encode(request)
    #expect(try JSONDecoder().decode(CreationRequest.self, from: data) == request)
  }

  @Test func resultRoundTripsAndOmitsPassword() throws {
    let result = CreationResult(account: "agent2", uid: 502, home: "/Users/agent2")
    let data = try JSONEncoder().encode(result)
    let text = String(decoding: data, as: UTF8.self)
    #expect(!text.lowercased().contains("password"))
    #expect(try JSONDecoder().decode(CreationResult.self, from: data) == result)
  }
}

/// Registering an agent whose account already exists (the helper made it
/// before registration) must keep the account and port that are true on the
/// machine, not recompute them.
@Suite struct ExplicitRegistryAddTests {
  @Test func keepsGivenAccountAndPort() {
    var r = Registry()
    let a = r.add(name: "Scout", account: "agent7", port: 5909)
    #expect(a.account == "agent7")
    #expect(a.port == 5909)
    #expect(r.agents.count == 1)
  }

  @Test func nextAccountSkipsExplicitlyAddedOnes() {
    var r = Registry()
    _ = r.add(name: "Scout", account: "agent", port: 5902)
    #expect(r.nextAccount() == "agent2")
    #expect(r.nextPort() == 5903)
  }
}
