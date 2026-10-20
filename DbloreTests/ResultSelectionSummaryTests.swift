// ResultSelectionSummaryTests.swift
// Count, non-null count and Decimal statistics of the selected rows in the clicked column.

import Foundation
import Testing

@testable import Dblore

@Suite("Result selection summary")
struct ResultSelectionSummaryTests {
  private let english = Locale(identifier: "en_US")

  private func summary(
    _ values: [CellValue], type: String = "int4"
  ) throws
    -> ResultSelectionSummary
  {
    try ResultSelectionSummary.compute(values: values, columnName: "v", columnType: type)
  }

  @Test("One row in one column summarizes that cell")
  func oneCell() throws {
    let result = try summary([.int(7)])
    #expect(result.count == 1)
    #expect(result.nonNullCount == 1)
    #expect(result.sum == 7)
    #expect(result.average == 7)
    #expect(result.minimum == 7)
    #expect(result.maximum == 7)
  }

  @Test("Without a clicked column only the rows are counted")
  func rowsOnly() {
    let result = ResultSelectionSummary(rowCount: 3)
    #expect(result.columnName == nil)
    #expect(result.sum == nil)
    #expect(result.statusText(locale: english) == "3 rows")
  }

  @Test("Integers sum, average, min and max; NULL counts as a cell but not a value")
  func integersAndNull() throws {
    let result = try summary([.int(4), .null, .int(-2), .int(10)])
    #expect(result.count == 4)
    #expect(result.nonNullCount == 3)
    #expect(result.numericCount == 3)
    #expect(result.sum == 12)
    #expect(result.average == 4)
    #expect(result.minimum == -2)
    #expect(result.maximum == 10)
    #expect(!result.isMixed)
  }

  @Test("Doubles add without float drift")
  func doublesAreExact() throws {
    let result = try summary([.double(0.1), .double(0.2)], type: "float8")
    #expect(result.sum == Decimal(string: "0.3"))
    #expect(result.maximum == Decimal(string: "0.2"))
  }

  @Test("Exact decimal text counts only in a numeric column type")
  func decimalText() throws {
    let values: [CellValue] = [.string("12345678901234567890.25"), .string("0.75")]
    let numeric = try summary(values, type: "DECIMAL")
    #expect(numeric.sum == Decimal(string: "12345678901234567891"))
    #expect(numeric.numericCount == 2)
    let text = try summary(values, type: "VARCHAR")
    #expect(text.sum == nil)
    #expect(text.numericCount == 0)
    #expect(text.nonNullCount == 2)
  }

  @Test("Text with trailing garbage is not a number")
  func lenientTextIsRejected() throws {
    let result = try summary(
      [.string("12abc"), .string("1e3"), .string("."), .string("-.5")],
      type: "numeric(10,2)")
    #expect(result.numericCount == 2)
    #expect(result.sum == Decimal(string: "999.5"))
  }

  @Test("A mixed column summarizes its numeric cells and says so")
  func mixedColumn() throws {
    let result = try summary([.int(2), .string("n/a"), .double(3), .bool(true)], type: "text")
    #expect(result.numericCount == 2)
    #expect(result.nonNullCount == 4)
    #expect(result.sum == 5)
    #expect(result.isMixed)
    #expect(result.mixedNote(locale: english) == "Numeric cells only (2 of 4)")
  }

  @Test("JSON cells are not numbers, even in a numeric-typed column")
  func jsonIsNotNumeric() throws {
    let result = try summary([.json("1"), .json("2")], type: "numeric")
    #expect(result.numericCount == 0)
    #expect(result.sum == nil)
    #expect(result.statusText(locale: english) == "Count 2")
  }

  @Test("Numeric type names of the engines, with precision and unsigned")
  func numericTypeNames() {
    for type in ["int4", "BIGINT", "DECIMAL(18,3)", "int unsigned", "HUGEINT", "double precision"] {
      #expect(ResultSelectionSummary.isNumericType(type), "\(type)")
    }
    for type in ["text", "VARCHAR(10)", "jsonb", "money", "date"] {
      #expect(!ResultSelectionSummary.isNumericType(type), "\(type)")
    }
  }

  @Test("Status and copy text use the locale's number format")
  func text() throws {
    let result = try summary([.int(1000), .int(2000), .null])
    #expect(result.statusText(locale: english) == "Count 3 · Sum 3,000 · Avg 1,500")
    #expect(
      result.copyText(locale: english)
        == "v\nCount: 3\nNon-null: 2\nSum: 3,000\nAvg: 1,500\nMin: 1,000\nMax: 2,000")
  }

  @Test("Above the threshold the detached path gives the same summary")
  func detachedMatchesInline() async throws {
    let values = (0...ResultSelectionSummary.detachedThreshold).map { CellValue.int($0) }
    let detached = try await ResultSelectionSummary.summarize(
      values: values, columnName: "v", columnType: "int4")
    #expect(detached == (try summary(values)))
    #expect(detached.sum == Decimal(10_000 * 10_001 / 2))
  }

  @Test("Cancelling the caller cancels the detached work")
  func detachedIsCancellable() async {
    let values = Array(repeating: CellValue.int(1), count: 2_000_000)
    let task = Task {
      try await ResultSelectionSummary.summarize(
        values: values, columnName: "v", columnType: "int4")
    }
    task.cancel()
    let outcome = await task.result
    #expect(throws: CancellationError.self) { try outcome.get() }
  }
}
