//
//  SQLAutocompleteProviderTests.swift
//  SQLNotebookTests
//
//  The provider is fed from the already loaded schema (no own fetching)
//

import Testing

@testable import SQLNotebook

@MainActor
@Suite("SQLAutocompleteProvider")
struct SQLAutocompleteProviderTests {
  private func table(_ name: String, columns: [String]) -> DatabaseTable {
    DatabaseTable(
      schema: "public", name: name,
      columns: columns.map { DatabaseColumn(name: $0, type: "text") })
  }

  @Test("update(tables:) indexes columns of all 80 tables")
  func indexesAllTables() {
    let provider = SQLAutocompleteProvider()
    let tables = (1...80).map { table("t\($0)", columns: ["col_\($0)"]) }
    provider.update(tables: tables)

    #expect(provider.tables.count == 80)
    #expect(provider.columnsByTable.count == 80)
    #expect(provider.columnsByTable["public.t80"]?.first?.name == "col_80")

    let text = "SELECT col_80 FROM t80"
    let suggestions = provider.getSuggestions(for: text, at: 13)
    #expect(suggestions.contains { $0.text == "col_80" })
  }

  @Test("after FROM t the column suggestions come from t")
  func columnsComeFromReferencedTable() {
    let provider = SQLAutocompleteProvider()
    provider.update(tables: [
      table("users", columns: ["zeta_name"]),
      table("orders", columns: ["zeta_total"]),
    ])
    let text = "SELECT zeta FROM users"
    let suggestions = provider.getSuggestions(for: text, at: 11)
    #expect(suggestions.contains { $0.text == "zeta_name" })
    #expect(!suggestions.contains { $0.text == "zeta_total" })
  }

  @Test("clearCache empties tables and columns")
  func clearCacheEmpties() {
    let provider = SQLAutocompleteProvider()
    provider.update(tables: [table("users", columns: ["id"])])
    provider.clearCache()
    #expect(provider.tables.isEmpty)
    #expect(provider.columnsByTable.isEmpty)
  }

  @Test("update replaces the previous schema")
  func updateReplaces() {
    let provider = SQLAutocompleteProvider()
    provider.update(tables: [table("old_table", columns: ["old_col"])])
    provider.update(tables: [table("new_table", columns: ["new_col"])])
    #expect(provider.tables.map(\.name) == ["new_table"])
    #expect(provider.columnsByTable.keys.sorted() == ["public.new_table"])
  }
}
