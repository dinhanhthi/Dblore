// ConnectionFormAIDraftTests.swift
// The AI section of the connection form: policy options, the rules counter and clamp, the
// write into the config, the edited flag and the seed from the saved connection.

import Foundation
import Testing

@testable import Dblore

@Suite("Connection form AI draft")
@MainActor
struct ConnectionFormAIDraftTests {
  private static func config(
    _ policy: AIAccessPolicy, rules: String = "", remember: Bool = true
  ) -> ConnectionConfig {
    var config = ConnectionConfig(
      host: "db.example", database: "app", username: "ada", rememberConnection: remember)
    config.aiAccess = policy
    config.aiRules = rules
    return config
  }

  @Test("The picker lists Use default first and names the current default")
  func pickerOptionsAndDefaultLabel() {
    #expect(ConnectionAIDraft.policyOptions == [.useDefault, .always, .askOncePerSession, .never])
    #expect(ConnectionAIDraft.policyTitle(.useDefault, default: .always) == "Use default (Always)")
    // A global Use default has nothing to follow and asks (fail closed)
    #expect(
      ConnectionAIDraft.policyTitle(.useDefault, default: .useDefault)
        == "Use default (Ask once per session)")
    #expect(ConnectionAIDraft.policyTitle(.never, default: .always) == "Never")
  }

  @Test("A pasted 2,500-character rule is saved as 2,000 and the counter shows the limit")
  func rulesClampAndCounter() {
    var draft = ConnectionAIDraft(config: Self.config(.useDefault))
    draft.access = .askOncePerSession
    draft.rules = String(repeating: "r", count: 2_500)
    let saved = draft.applied(to: Self.config(.always, rules: "Old."))
    #expect(saved.aiAccess == .askOncePerSession)
    #expect(saved.aiRules.count == 2_000)
    #expect(ConnectionAIDraft.counterText(saved.aiRules) == "2,000 / 2,000")
    #expect(ConnectionAIDraft.counterText("Only orders.") == "12 / 2,000")
  }

  @Test("The edited flag is set only when the AI fields differ from the seed")
  func editedOnlyWhenChanged() {
    let seed = ConnectionAIDraft(config: Self.config(.never, rules: "No payments."))
    var form = Self.config(.never, rules: "No payments.")
    form.port = 6543
    #expect(!ConnectionAIDraft(config: form).isEdited(from: seed))
    form.aiRules = "No payments, no users."
    #expect(ConnectionAIDraft(config: form).isEdited(from: seed))
  }

  @Test(
    "The seed takes the exact saved row's AI fields over a stale form copy, unless Remember is off")
  func seedPrefersSavedRow() {
    let saved = Self.config(.never, rules: "Saved rules.")
    let stale = Self.config(.always, rules: "Stale rules.")
    let seed = ConnectionAIDraft.seed(for: stale, saved: saved)
    #expect(seed == ConnectionAIDraft(config: saved))
    #expect(seed.applied(to: stale).aiAccess == .never)

    // Remember off writes no row: the live choice stays
    let live = Self.config(.never, rules: "Live rules.", remember: false)
    let always = Self.config(.always)
    #expect(ConnectionAIDraft.seed(for: live, saved: always) == ConnectionAIDraft(config: live))
    #expect(ConnectionAIDraft.seed(for: stale, saved: nil) == ConnectionAIDraft(config: stale))
  }

  @Test(
    "Turning Remember on after a Remember-off seed writes the shown AI fields, not the saved row")
  func rememberTurnedOnWritesShownFields() {
    // Live Never chosen for this session, over an older saved Always row
    let live = Self.config(.never, remember: false)
    let seed = ConnectionAIDraft.seed(for: live, saved: Self.config(.always))
    var form = seed.applied(to: live)
    #expect(form.aiAccess == .never)
    #expect(!ConnectionAIDraft(config: form).isEdited(from: seed))
    form.rememberConnection = true
    #expect(ConnectionAIDraft(config: form).isEdited(from: seed))

    // A Remember-on seed shows the saved row: turning Remember off is no AI edit
    let saved = Self.config(.never)
    let remembered = ConnectionAIDraft.seed(for: Self.config(.always), saved: saved)
    var off = remembered.applied(to: Self.config(.always))
    off.rememberConnection = false
    #expect(!ConnectionAIDraft(config: off).isEdited(from: remembered))
  }
}
