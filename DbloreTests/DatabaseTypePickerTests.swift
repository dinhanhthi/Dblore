// DatabaseTypePickerTests.swift
// Connection form engine picker (MySQL and MongoDB always, DuckDB only with its plugin, but a
// saved DuckDB connection keeps its selection) and the connect error that offers to install the
// plugin.

import Foundation
import Testing

@testable import Dblore

@Suite("Database Type Picker")
struct DatabaseTypePickerTests {

  @Test("A saved DuckDB connection keeps DuckDB selectable without the plugin")
  func savedDuckDBKeepsSelection() {
    let types = ConnectionFormModal.pickerTypes(
      showExperimental: false, current: .duckdb, isPluginInstalled: { _ in false })
    #expect(types == [.postgresql, .sqlite, .duckdb, .mysql, .mongodb])
  }

  @Test("A missing plugin wrapped by a catalog fetch still offers the install")
  func wrappedEngineUnavailableOpensPluginSettings() {
    let inner = DatabaseError.engineUnavailable(.duckdb)
    let wrapped = DatabaseError.queryFailed(
      "Failed to fetch schemas: \(inner.localizedDescription)", 0)
    #expect(ConnectionErrorAction.action(for: wrapped) == .openPluginSettings)
    #expect(ConnectionErrorAction.action(forMessage: wrapped.localizedDescription) != nil)
  }
}
