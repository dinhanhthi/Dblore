import Foundation
import Testing

@testable import Dblore

@Suite("Import type inference")
struct ImportTypeInferenceTests {
  @Test("Empty cells are NULL and do not change inferred column types")
  func inferColumns() {
    let rows: [[String?]] = [
      ["1", "1.5", "true", "2026-10-03", "2026-10-03T12:30:00Z", "hello", nil],
      ["2", "3", "false", "2026-10-04", "2026-10-04", "42", "  "],
      [" ", nil, "", nil, nil, "world", ""],
    ]

    #expect(
      ImportTypeInference.infer(rows: rows, columnCount: 7) == [
        .integer, .decimal, .boolean, .date, .timestamp, .text, .text,
      ])
    #expect(ImportTypeInference.normalizedValue("  ") == nil)
    #expect(ImportTypeInference.normalizedValue("  42  ") == "  42  ")
  }

  @Test("Incompatible or malformed values make a column text")
  func rejectPartialMatches() {
    let rows: [[String?]] = [
      ["1", "2026-02-30", "1.2x", "1", "-9223372036854775809"],
      ["2", "2026-03-01", "3.4", "true", "0"],
    ]
    #expect(
      ImportTypeInference.infer(rows: rows, columnCount: 5) == [
        .integer, .text, .text, .text, .decimal,
      ])
  }

  @Test("Leading-zero values stay text so their zeros are kept")
  func leadingZerosAreText() {
    let rows: [[String?]] = [["00501", "0"], ["02134", "-12"], ["007", "34"]]
    #expect(ImportTypeInference.infer(rows: rows, columnCount: 2) == [.text, .integer])
  }

  @Test("Database types match the inferred kind")
  func sqlTypes() {
    let kinds: [ImportTypeInference.Kind] = [
      .integer, .decimal, .boolean, .date, .timestamp, .text,
    ]
    #expect(
      kinds.map { $0.sqlType(dialect: .postgresql) } == [
        "bigint", "numeric", "boolean", "date", "timestamptz", "text",
      ])
    #expect(
      kinds.map { $0.sqlType(dialect: .sqlite) } == [
        "INTEGER", "REAL", "INTEGER", "TEXT", "TEXT", "TEXT",
      ])
  }
}
