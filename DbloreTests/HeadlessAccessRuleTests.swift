// HeadlessAccessRuleTests.swift
// The command-line tool and Shortcuts use only allowlisted, unlocked rows; the command line also
// skips AI-Never rows; a shared name is refused.

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("Headless access rule")
struct HeadlessAccessRuleTests {
  private let gate = AIAccessGate()
  private let registry = LockRegistry()
  private var rule: HeadlessAccessRule { HeadlessAccessRule(gate: gate, lockSource: registry) }

  private static func entry(
    name: String, host: String = "db.internal", access: AIAccessPolicy = .useDefault
  ) -> ConnectionHistoryEntry {
    var config = ConnectionConfig(
      databaseType: .postgresql, host: host, port: 5432, database: "app", username: "admin-user",
      name: name)
    config.aiAccess = access
    return ConnectionHistoryEntry(config: config)
  }

  private static func cli(
    _ allowed: Set<UUID>, default policy: AIAccessPolicy = .always
  ) -> HeadlessAccessRule.Caller {
    .cli(
      mcpAllowlist: allowed,
      aiSettings: AIConfiguration(
        activeProvider: nil, configs: [:], defaultConnectionAccess: policy))
  }

  private func refusal(
    _ reference: String, _ saved: [ConnectionHistoryEntry], _ caller: HeadlessAccessRule.Caller
  ) -> HeadlessAccessRule.Refusal? {
    do {
      _ = try rule.resolve(reference, saved: saved, caller: caller)
      return nil
    } catch {
      return error as? HeadlessAccessRule.Refusal
    }
  }

  @Test("the command line runs an allowlisted Ask-once connection with no approval")
  func cliAllowsAskOnce() throws {
    let ask = Self.entry(name: "Ask", access: .askOncePerSession)
    let resolved = try rule.resolve("Ask", saved: [ask], caller: Self.cli([ask.id]))
    #expect(resolved.id == ask.id)
    #expect(rule.entries(saved: [ask], caller: Self.cli([ask.id])).map(\.id) == [ask.id])
  }

  @Test("the command line refuses an allowlisted connection whose AI access is Never")
  func cliRefusesNever() {
    let never = Self.entry(name: "Never", access: .never)
    #expect(refusal(never.id.uuidString, [never], Self.cli([never.id])) == .aiAccessNever)
    #expect(rule.entries(saved: [never], caller: Self.cli([never.id])).isEmpty)
  }

  @Test("the command line refuses a Use-default connection while the global default is Never")
  func cliRefusesDefaultNever() {
    let row = Self.entry(name: "Default", access: .useDefault)
    #expect(
      refusal(row.id.uuidString, [row], Self.cli([row.id], default: .never)) == .aiAccessNever)
  }

  @Test("a non-allowlisted Never row of the same identity refuses the allowlisted one")
  func cliStrictestSavedRow() {
    let allowed = Self.entry(name: "Always", access: .always)
    let twin = Self.entry(name: "Twin", access: .never)
    #expect(
      refusal(allowed.id.uuidString, [allowed, twin], Self.cli([allowed.id])) == .aiAccessNever)
  }

  @Test("the command line refuses a connection that is not allowlisted")
  func cliRefusesNotAllowlisted() {
    let row = Self.entry(name: "Prod")
    #expect(refusal(row.id.uuidString, [row], Self.cli([])) == .notAllowlisted)
    #expect(refusal("Prod", [row], Self.cli([])) == .notFound)
  }

  @Test("a locked connection is refused, even after an unlock in the app")
  func lockedRefused() {
    let row = Self.entry(name: "Prod")
    let identity = LockIdentity(row.config)
    registry.setLockedConnections([identity])
    registry.grant(identity)
    #expect(refusal(row.id.uuidString, [row], Self.cli([row.id])) == .locked)
    #expect(
      refusal(row.id.uuidString, [row], .shortcuts(enabled: true, allowlist: [row.id])) == .locked)
  }

  @Test("Shortcuts is refused while off, even for an allowlisted row")
  func shortcutsOff() {
    let row = Self.entry(name: "Prod")
    let off = HeadlessAccessRule.Caller.shortcuts(enabled: false, allowlist: [row.id])
    #expect(refusal(row.id.uuidString, [row], off) == .shortcutsOff)
    #expect(refusal("Prod", [row], off) == .shortcutsOff)
    #expect(rule.entries(saved: [row], caller: off).isEmpty)
  }

  @Test("Shortcuts uses only rows on its own list, whatever the MCP list and AI access")
  func shortcutsAllowlist() throws {
    let listed = Self.entry(name: "Listed", access: .never)
    let other = Self.entry(name: "Other", host: "other.internal")
    let on = HeadlessAccessRule.Caller.shortcuts(enabled: true, allowlist: [listed.id])
    #expect(refusal(other.id.uuidString, [listed, other], on) == .notAllowlisted)
    #expect(try rule.resolve("Listed", saved: [listed, other], caller: on).id == listed.id)
  }

  @Test("a name two usable rows share is refused; the id still works")
  func ambiguousName() throws {
    let first = Self.entry(name: "Prod")
    let second = Self.entry(name: "Prod", host: "replica.internal")
    let caller = Self.cli([first.id, second.id])
    #expect(refusal("Prod", [first, second], caller) == .ambiguousName)
    #expect(
      HeadlessAccessRule.Refusal.ambiguousName.errorDescription
        == "The connection name is ambiguous; use the id.")
    #expect(
      try rule.resolve(second.id.uuidString, saved: [first, second], caller: caller).id
        == second.id)
  }
}
