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
    // A leading plus stays text on purpose; negative zero is still an integer
    #expect(ImportTypeInference.infer(rows: [["+5", "-0"]], columnCount: 2) == [.text, .integer])
  }

  /// DECIMAL(65,30) on MySQL holds 35 integer and 30 fraction digits; scientific notation is
  /// text so its value is never rounded or rejected
  @Test("Decimals that would not fit DECIMAL(65,30), and scientific notation, are text")
  func decimalBounds() {
    let integer35 = String(repeating: "9", count: 35)
    let fraction30 = String(repeating: "1", count: 30)
    let fits: [String] = [
      "1.5", "-12.25", "123456789012345678901234.5", "\(integer35).\(fraction30)",
      "-\(integer35)", "0.\(fraction30)",
    ]
    for value in fits {
      #expect(ImportTypeInference.infer(rows: [[value]], columnCount: 1) == [.decimal], "\(value)")
    }
    let tooWide: [String] = [
      "1e40", "3.2e-45", "1E5", "-1e5", "1.5e+3", "1\(integer35)", "0.\(fraction30)1",
    ]
    for value in tooWide {
      #expect(ImportTypeInference.infer(rows: [[value]], columnCount: 1) == [.text], "\(value)")
    }
    // One exponent value makes the whole column text
    #expect(ImportTypeInference.infer(rows: [["1.5"], ["2e3"]], columnCount: 1) == [.text])
  }

  /// A naive timestamp export (`2026-10-15 12:00:00.123456`) re-imports as a naive column so
  /// the server keeps its wall clock; a column mixing naive and zoned text stays text
  @Test("Naive timestamps infer a zone-less kind, and mixed zones stay text")
  func localTimestamps() {
    let rows: [[String?]] = [
      ["2026-10-15 12:00:00.123456", "2026-10-15T08:30:00", "2026-10-15 12:00:00"],
      ["2026-10-16 23:59:59", "2026-10-16T08:30:00.5", "2026-10-15T12:00:00Z"],
    ]
    #expect(
      ImportTypeInference.infer(rows: rows, columnCount: 3) == [
        .localTimestamp, .localTimestamp, .text,
      ])
    #expect(ImportTypeInference.Kind.localTimestamp.sqlType(dialect: .postgresql) == "timestamp")
  }

  /// Decimals keep every digit: never a binary float type (SQLite has no exact decimal type).
  /// DuckDB decimals are text unless the builder has their digits (`ImportSQLBuilderTests`).
  @Test("Database types match the inferred kind")
  func sqlTypes() {
    let kinds: [ImportTypeInference.Kind] = [
      .integer, .decimal, .boolean, .date, .timestamp, .localTimestamp, .text,
    ]
    #expect(
      kinds.map { $0.sqlType(dialect: .postgresql) } == [
        "bigint", "numeric", "boolean", "date", "timestamptz", "timestamp", "text",
      ])
    #expect(
      kinds.map { $0.sqlType(dialect: .sqlite) } == [
        "INTEGER", "TEXT", "INTEGER", "TEXT", "TEXT", "TEXT", "TEXT",
      ])
    #expect(
      kinds.map { $0.sqlType(dialect: .mysql) } == [
        "BIGINT", "DECIMAL(65,30)", "BOOLEAN", "DATE", "DATETIME(6)", "DATETIME(6)", "LONGTEXT",
      ])
    #expect(
      kinds.map { $0.sqlType(dialect: .duckdb) } == [
        "bigint", "text", "boolean", "date", "timestamptz", "timestamp", "text",
      ])
  }
}
