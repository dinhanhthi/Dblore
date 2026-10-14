// ExportImportDialectTests.swift
// INSERT export and table import follow the connection dialect, not a PostgreSQL default.

import Foundation
import Testing

@testable import Dblore

@Suite("Export and import dialect")
@MainActor
struct ExportImportDialectTests {
  private static func cellResult() -> CellResult {
    CellResult(
      columns: [ColumnInfo(name: "name", type: "text")],
      rows: [[.string("O'Brien \\ co")]],
      rowCount: 1,
      tableName: "t")
  }

  @Test(
    "INSERT export quotes identifiers and literals with the dialect",
    arguments: [
      (SQLDialect.sqlite, #"INSERT INTO "t" ("name") VALUES ('O''Brien \ co');"#),
      (SQLDialect.mysql, #"INSERT INTO `t` (`name`) VALUES ('O''Brien \\ co');"#),
    ])
  func insertExport(dialect: SQLDialect, expected: String) {
    #expect(DataExporter.sqlInsert(result: Self.cellResult(), dialect: dialect) == expected)
  }

  @Test("Import batch quotes the destination with the dialect", .timeLimit(.minutes(1)))
  func importBatchDialect() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-import-\(UUID().uuidString).csv")
    try Data("name\nAda\n".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let model = TableImportModel()
    await model.loadFile(url)
    model.destination = .existing(schema: nil, table: "people")
    let batch = try await model.prepareBatch(dialect: .mysql, connectionEpoch: 0)
    #expect(batch.statements.first?.sql.hasPrefix("INSERT INTO `people` (`name`)") == true)
  }
}
