// DatabaseTypePickerTests.swift
// Connection form engine picker (DuckDB only with its plugin, but a saved DuckDB connection keeps
// its selection) and the connect error that offers to install the plugin.

import Foundation
import Testing

@testable import Dblore

@Suite("Database Type Picker")
struct DatabaseTypePickerTests {

  @Test(
    "A new connection lists DuckDB only when its plugin is installed",
    arguments: [
      (false, [DatabaseType.postgresql, .sqlite]), (true, [.postgresql, .sqlite, .duckdb]),
    ]
  )
  func pickerFollowsPluginProvider(installed: Bool, expected: [DatabaseType]) {
    let types = ConnectionFormModal.pickerTypes(
      showExperimental: false, current: .postgresql, isPluginInstalled: { _ in installed })
    #expect(types == expected)
  }

  @Test("A saved DuckDB connection keeps DuckDB selectable without the plugin")
  func savedDuckDBKeepsSelection() {
    let types = ConnectionFormModal.pickerTypes(
      showExperimental: false, current: .duckdb, isPluginInstalled: { _ in false })
    #expect(types == [.postgresql, .sqlite, .duckdb])
  }

  @Test("A missing DuckDB plugin offers to open Settings > Plugins")
  func engineUnavailableOpensPluginSettings() {
    let error = DatabaseError.engineUnavailable(.duckdb)
    #expect(ConnectionErrorAction.action(for: error) == .openPluginSettings)
  }

  @Test("A missing plugin wrapped by a catalog fetch still offers the install")
  func wrappedEngineUnavailableOpensPluginSettings() {
    let inner = DatabaseError.engineUnavailable(.duckdb)
    let wrapped = DatabaseError.queryFailed(
      "Failed to fetch schemas: \(inner.localizedDescription)", 0)
    #expect(ConnectionErrorAction.action(for: wrapped) == .openPluginSettings)
    #expect(ConnectionErrorAction.action(forMessage: wrapped.localizedDescription) != nil)
  }

  @Test("Other connect errors offer no action")
  func otherErrorsHaveNoAction() {
    let errors: [DatabaseError] = [
      .connectionFailed("timeout"), .queryFailed("syntax error", 0), .notConnected,
    ]
    for error in errors {
      #expect(ConnectionErrorAction.action(for: error) == nil)
      #expect(ConnectionErrorAction.action(forMessage: error.localizedDescription) == nil)
    }
  }
}
