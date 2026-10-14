// ResultRowCapTests.swift
// C6: one result row cap for notebook and editor. Global `AppSettings.resultRowCap`
// (default 10,000, clamped to `SessionBrakeLimits.rowCapRange`), a per-connection
// `rowCapOverride` that wins when set, and a one-time migration of the legacy
// `maxRowLimit` / `editorMaxRowLimit` UserDefaults keys. Every UserDefaults test uses an
// isolated suite, never `UserDefaults.standard`.

import Foundation
import Testing

@testable import Dblore

@Suite("Result Row Cap")
@MainActor
struct ResultRowCapTests {
  private static let legacyNotebookKey = "app.settings.maxRowLimit"
  private static let legacyEditorKey = "app.settings.editorMaxRowLimit"

  /// A fresh, empty UserDefaults suite, removed when `body` returns
  private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
    let name = "ResultRowCapTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    try body(defaults)
  }

  // MARK: - Global default

  @Test("Global cap is clamped to 100...100000 (non-positive -> default)")
  func globalClamped() {
    #expect(AppSettings.clampResultRowCap(5) == 100)
    #expect(AppSettings.clampResultRowCap(150) == 150)
    #expect(AppSettings.clampResultRowCap(500_000) == 100_000)
    #expect(AppSettings.clampResultRowCap(0) == AppSettings.defaultResultRowCap)
    #expect(AppSettings.clampResultRowCap(-3) == AppSettings.defaultResultRowCap)
  }

  // MARK: - Resolver

  @Test("Connection override beats the global cap")
  func overrideBeatsGlobal() {
    #expect(SettingsResolver.effectiveRowCap(override: 5000, global: 100) == 5000)
    #expect(SettingsResolver.effectiveRowCap(override: 120, global: 150) == 120)
    #expect(SettingsResolver.effectiveRowCap(override: nil, global: 150) == 150)
  }

  @Test("Connection override is clamped; non-positive override falls back to global")
  func overrideClamped() {
    #expect(SettingsResolver.effectiveRowCap(override: 50, global: 300) == 100)
    #expect(SettingsResolver.effectiveRowCap(override: 200_000, global: 300) == 100_000)
    #expect(SettingsResolver.effectiveRowCap(override: 0, global: 300) == 300)
    #expect(SettingsResolver.effectiveRowCap(override: -4, global: 300) == 300)
  }

  @Test("View model cap uses its connection override, else the global setting")
  func viewModelEffectiveCap() {
    let viewModel = NotebookViewModel()
    // Pinned: other suites reset `AppSettings.shared` while tests run in parallel
    viewModel.globalRowCap = { 250 }
    viewModel.notebook.connectionConfig = ConnectionConfig(rowCapOverride: 120)
    #expect(viewModel.effectiveRowCap == 120)
    viewModel.notebook.connectionConfig = ConnectionConfig(rowCapOverride: 7)
    #expect(viewModel.effectiveRowCap == 100)
    viewModel.notebook.connectionConfig = ConnectionConfig()
    #expect(viewModel.effectiveRowCap == 250)
    viewModel.notebook.connectionConfig = nil
    #expect(viewModel.effectiveRowCap == 250)
    viewModel.globalRowCap = { 150 }
    #expect(viewModel.effectiveRowCap == 150)
  }

  // MARK: - Legacy migration

  @Test("Legacy keys migrate to the larger of the two and are removed")
  func legacyMigratesMax() throws {
    try withIsolatedDefaults { defaults in
      defaults.set(80, forKey: Self.legacyNotebookKey)
      defaults.set(180, forKey: Self.legacyEditorKey)
      #expect(AppSettings.loadResultRowCap(from: defaults) == 180)
      #expect(defaults.integer(forKey: AppSettings.resultRowCapKey) == 180)
      #expect(defaults.object(forKey: Self.legacyNotebookKey) == nil)
      #expect(defaults.object(forKey: Self.legacyEditorKey) == nil)
    }
  }

  @Test("An existing new key wins; leftover legacy keys are only deleted")
  func newKeyWins() throws {
    try withIsolatedDefaults { defaults in
      defaults.set(2500, forKey: AppSettings.resultRowCapKey)
      defaults.set(200, forKey: Self.legacyEditorKey)
      #expect(AppSettings.loadResultRowCap(from: defaults) == 2500)
      #expect(defaults.integer(forKey: AppSettings.resultRowCapKey) == 2500)
      #expect(defaults.object(forKey: Self.legacyEditorKey) == nil)
    }
  }

  @Test("A stored 100 (the old default) is an explicit choice and is kept")
  func storedOldDefaultKept() throws {
    try withIsolatedDefaults { defaults in
      defaults.set(100, forKey: AppSettings.resultRowCapKey)
      #expect(AppSettings.loadResultRowCap(from: defaults) == 100)
    }
  }
}
