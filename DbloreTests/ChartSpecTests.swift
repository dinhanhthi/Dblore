// ChartSpecTests.swift
// Suggested chart spec: temporal line, low-cardinality bar, numeric y columns.

import Foundation
import Testing

@testable import Dblore

@Suite("Chart spec")
struct ChartSpecTests {
  @Test("A time series suggests a line chart with the date column on x")
  func timeSeriesSuggestsLine() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let result = queryResult(
      columns: [
        ColumnInfo(name: "region", type: "text"),
        ColumnInfo(name: "observed_at", type: "timestamp"),
        ColumnInfo(name: "value", type: "float8"),
      ],
      rows: [
        [.string("east"), .date(start), .double(1)],
        [.string("west"), .date(start.addingTimeInterval(3600)), .double(2)],
      ]
    )

    let spec = ChartSpec.suggested(for: result)
    #expect(spec?.kind == .line)
    #expect(spec?.xColumn == "observed_at")
    #expect(spec?.yColumns == ["value"])
    #expect(spec?.seriesColumn == nil)
  }

  @Test("Category text with few distinct values suggests a bar chart")
  func categorySuggestsBar() {
    let result = queryResult(
      columns: [
        ColumnInfo(name: "status", type: "text"),
        ColumnInfo(name: "count", type: "int4"),
      ],
      rows: [
        [.string("open"), .int(3)],
        [.string("closed"), .int(8)],
        [.string("open"), .int(1)],
      ]
    )

    let spec = ChartSpec.suggested(for: result)
    #expect(spec?.kind == .bar)
    #expect(spec?.xColumn == "status")
    #expect(spec?.yColumns == ["count"])
    #expect(spec?.seriesColumn == nil)
  }

  @Test("No numeric column returns nil")
  func noNumericColumnReturnsNil() {
    let result = queryResult(
      columns: [
        ColumnInfo(name: "name", type: "text"),
        ColumnInfo(name: "observed_at", type: "timestamp"),
      ],
      rows: [
        [.string("a"), .date(Date(timeIntervalSince1970: 1_700_000_000))],
        [.string("b"), .date(Date(timeIntervalSince1970: 1_700_003_600))],
      ]
    )
    #expect(ChartSpec.suggested(for: result) == nil)
  }

  @Test("Numeric SQL types count as y even when the cell is a numeric string")
  func numericSQLTypeStringIsY() {
    for type in ["int2", "int4", "int8", "float4", "float8", "numeric", "decimal"] {
      let result = queryResult(
        columns: [
          ColumnInfo(name: "label", type: "text"),
          ColumnInfo(name: "n", type: type),
        ],
        rows: [[.string("only"), .string("2.5")]]
      )
      let spec = ChartSpec.suggested(for: result)
      #expect(spec?.yColumns == ["n"], "type \(type)")
      #expect(spec?.kind == .bar)
      #expect(spec?.xColumn == "label")
    }

    let textNumbers = queryResult(
      columns: [ColumnInfo(name: "n", type: "text")],
      rows: [[.string("2.5")]]
    )
    #expect(ChartSpec.suggested(for: textNumbers) == nil)
  }

  @Test("The first text column with at most 50 distinct values is x; otherwise the row index")
  func categoryCardinalityChoosesX() {
    let fifty = queryResult(
      columns: [
        ColumnInfo(name: "bucket", type: "text"),
        ColumnInfo(name: "n", type: "int4"),
      ],
      rows: (0..<50).map { [CellValue.string("b\($0)"), .int($0)] }
    )
    #expect(ChartSpec.suggested(for: fifty)?.xColumn == "bucket")
    #expect(ChartSpec.suggested(for: fifty)?.kind == .bar)

    let fiftyOne = queryResult(
      columns: [
        ColumnInfo(name: "bucket", type: "text"),
        ColumnInfo(name: "n", type: "int4"),
      ],
      rows: (0..<51).map { [CellValue.string("b\($0)"), .int($0)] }
    )
    let wide = ChartSpec.suggested(for: fiftyOne)
    #expect(wide?.xColumn == nil)
    #expect(wide?.kind == .bar)
    #expect(wide?.yColumns == ["n"])
  }

  @Test("At most five numeric columns are suggested as y")
  func yColumnsAreCappedAtFive() {
    let names = ["a", "b", "c", "d", "e", "f", "g"]
    let result = queryResult(
      columns: names.map { ColumnInfo(name: $0, type: "float8") },
      rows: [names.map { _ in CellValue.double(1) }]
    )
    #expect(ChartSpec.suggested(for: result)?.yColumns == ["a", "b", "c", "d", "e"])
    #expect(ChartSpec.suggested(for: result)?.xColumn == nil)
    #expect(ChartSpec.suggested(for: result)?.kind == .bar)
  }

  @Test("A chart spec round-trips through JSON")
  func codableRoundTrip() throws {
    for kind in [ChartKind.bar, .line, .area, .point] {
      let spec = ChartSpec(kind: kind, xColumn: "t", yColumns: ["y"], seriesColumn: "s")
      let data = try JSONEncoder().encode(spec)
      let decoded = try JSONDecoder().decode(ChartSpec.self, from: data)
      #expect(decoded == spec)
    }
  }

  private func queryResult(columns: [ColumnInfo], rows: [[CellValue]]) -> QueryResult {
    QueryResult(columns: columns, rows: rows, rowCount: rows.count, executionTime: 0)
  }
}
