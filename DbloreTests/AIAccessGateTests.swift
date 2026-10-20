// AIAccessGateTests.swift
// Unit tests for the per-connection AI access policy gate

import Foundation
import Testing

@testable import Dblore

@Suite("AI Access Gate Tests")
@MainActor
struct AIAccessGateTests {

  private func config(
    _ policy: AIAccessPolicy, type: DatabaseType = .postgresql, database: String = "app"
  ) -> ConnectionConfig {
    var config = ConnectionConfig(databaseType: type, host: "db.local", database: database)
    config.aiAccess = policy
    return config
  }

  private func settings(default policy: AIAccessPolicy) -> AIConfiguration {
    AIConfiguration(activeProvider: nil, configs: [:], defaultConnectionAccess: policy)
  }

  @Test(
    "Use default follows the global default",
    arguments: [
      (AIAccessPolicy.always, AIAccessGate.Decision.allowed),
      (.never, .denied),
      (.askOncePerSession, .needsApproval),
      // A global "use default" has nothing to follow: fail closed
      (.useDefault, .needsApproval),
    ])
  func useDefaultResolvesToGlobal(global: AIAccessPolicy, expected: AIAccessGate.Decision) {
    let gate = AIAccessGate()
    #expect(
      gate.decision(for: config(.useDefault), settings: settings(default: global)) == expected)
  }

  @Test("Ask once needs an approval per connection until the session is cleared")
  func askOncePerSession() {
    let gate = AIAccessGate()
    let global = settings(default: .always)
    let first = config(.askOncePerSession)
    let other = config(.askOncePerSession, database: "other")

    #expect(gate.decision(for: first, settings: global) == .needsApproval)
    gate.approveForSession(AIAccessGate.sessionKey(for: first))
    #expect(gate.decision(for: first, settings: global) == .allowed)
    #expect(gate.decision(for: other, settings: global) == .needsApproval)

    gate.clearSession()
    #expect(gate.decision(for: first, settings: global) == .needsApproval)
  }

  @Test("Never is denied even after an approval")
  func neverIsDenied() {
    let gate = AIAccessGate()
    let never = config(.never)
    gate.approveForSession(AIAccessGate.sessionKey(for: never))
    #expect(gate.decision(for: never, settings: settings(default: .always)) == .denied)
  }

  @Test("The session key is the length-prefixed connection identity, username included")
  func sessionKeyIdentity() {
    var ada = config(.always)
    ada.username = "ada"
    #expect(
      AIAccessGate.sessionKey(for: ada) == "v2|10:PostgreSQL|8:db.local|4:5432|3:app|3:ada")

    // An approval for one user never covers another user of the same database
    let gate = AIAccessGate()
    var userA = config(.askOncePerSession)
    userA.username = "alice"
    var userB = userA
    userB.username = "bob"
    gate.approveForSession(AIAccessGate.sessionKey(for: userA))
    #expect(gate.decision(for: userA, settings: settings(default: .always)) == .allowed)
    #expect(gate.decision(for: userB, settings: settings(default: .always)) == .needsApproval)

    // A separator inside a field never makes two identities equal
    let piped = ConnectionConfig(host: "h", database: "d|5432|x")
    let other = ConnectionConfig(host: "h|5432|d", database: "x")
    #expect(AIAccessGate.sessionKey(for: piped) != AIAccessGate.sessionKey(for: other))
  }

  @Test("The session key ignores host spelling but keeps file paths exact")
  func sessionKeyNormalization() {
    var variant = config(.always)
    variant.host = " DB.local. "
    #expect(AIAccessGate.sessionKey(for: variant) == AIAccessGate.sessionKey(for: config(.always)))

    let first = ConnectionConfig(databaseType: .sqlite, host: "", database: "/tmp/a.sqlite")
    let second = ConnectionConfig(databaseType: .sqlite, host: "", database: "/tmp/b.sqlite")
    let upper = ConnectionConfig(databaseType: .sqlite, host: "", database: "/tmp/A.sqlite")
    #expect(AIAccessGate.sessionKey(for: first) != AIAccessGate.sessionKey(for: second))
    #expect(AIAccessGate.sessionKey(for: first) != AIAccessGate.sessionKey(for: upper))
  }

  @Test("A MongoDB database switch keeps the key of the home database")
  func mongoSwitchKeepsKey() {
    let home = config(.askOncePerSession, type: .mongodb)
    let switched = WorkspaceManager.switchedMongoConfig(home, to: "sales")
    #expect(AIAccessGate.sessionKey(for: switched) == AIAccessGate.sessionKey(for: home))
    #expect(
      AIAccessGate.sessionKey(for: config(.always, type: .mongodb, database: "sales"))
        != AIAccessGate.sessionKey(for: home))
  }
}
