// ChartDataExtractorTests.swift
// Point extraction: finite y values, temporal order, and LTTB downsampling.

import Foundation
import Testing

@testable import Dblore

@Suite("Chart data extractor")
struct ChartDataExtractorTests {
  @Test(
    "LTTB of a series longer than maxPoints keeps the first point, the last point, and the peak")
  func lttbKeepsEndpointsAndPeak() {
    let count = 120
    let peakIndex = 47
    var rows: [[CellValue]] = []
    rows.reserveCapacity(count)
    for index in 0..<count {
      let y = index == peakIndex ? 1_000.0 : Double(index % 5)
      rows.append([.double(y)])
    }
    let result = queryResult(
      columns: [ColumnInfo(name: "y", type: "float8")],
      rows: rows
    )
    let spec = ChartSpec(kind: .line, xColumn: nil, yColumns: ["y"], seriesColumn: nil)

    let withinCap = ChartDataExtractor.points(result: result, spec: spec, maxPoints: count)
    #expect(withinCap.points.count == count)
    #expect(withinCap.droppedCount == 0)

    let sampled = ChartDataExtractor.points(result: result, spec: spec, maxPoints: 12)
    #expect(sampled.points.count == 12)
    #expect(sampled.droppedCount == 0)
    #expect(sampled.points.first?.x == .number(0))
    #expect(sampled.points.first?.y == 0)
    #expect(sampled.points.last?.x == .number(Double(count - 1)))
    #expect(sampled.points.contains { $0.y == 1_000 })
    #expect(sampled.points.allSatisfy { $0.series == nil })
  }

  @Test("Nulls and non-finite y values are counted and omitted")
  func nullsAndNaNAreOmitted() {
    let result = queryResult(
      columns: [ColumnInfo(name: "y", type: "float8")],
      rows: [
        [.int(1)],
        [.null],
        [.double(.nan)],
        [.string("2.5")],
        [.double(.infinity)],
        [.double(4)],
        [.double(-.infinity)],
        [.string("nope")],
      ]
    )
    let spec = ChartSpec(kind: .bar, xColumn: nil, yColumns: ["y"], seriesColumn: nil)
    let series = ChartDataExtractor.points(result: result, spec: spec, maxPoints: 100)

    #expect(series.droppedCount == 5)
    #expect(series.points.map(\.y) == [1, 2.5, 4])
    #expect(series.points.map(\.x) == [.number(0), .number(3), .number(5)])
  }

  @Test("Temporal x is sorted before points are returned")
  func temporalXIsSorted() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let result = queryResult(
      columns: [
        ColumnInfo(name: "observed_at", type: "timestamp"),
        ColumnInfo(name: "value", type: "float8"),
      ],
      rows: [
        [.date(start.addingTimeInterval(20)), .double(20)],
        [.date(start), .double(10)],
        [.date(start.addingTimeInterval(10)), .double(30)],
      ]
    )
    let spec = ChartSpec(
      kind: .line, xColumn: "observed_at", yColumns: ["value"], seriesColumn: nil)
    let series = ChartDataExtractor.points(result: result, spec: spec)

    #expect(series.droppedCount == 0)
    #expect(series.points.map(\.y) == [10, 30, 20])
    #expect(
      series.points.map(\.x) == [
        .number(start.timeIntervalSince1970),
        .number(start.addingTimeInterval(10).timeIntervalSince1970),
        .number(start.addingTimeInterval(20).timeIntervalSince1970),
      ]
    )
  }

  @Test("Category x is a labeled index in first-seen order")
  func categoryUsesLabeledIndex() {
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
    let spec = ChartSpec(kind: .bar, xColumn: "status", yColumns: ["count"], seriesColumn: nil)
    let series = ChartDataExtractor.points(result: result, spec: spec)

    #expect(series.droppedCount == 0)
    #expect(
      series.points.map(\.x) == [
        .category(index: 0, label: "open"),
        .category(index: 1, label: "closed"),
        .category(index: 0, label: "open"),
      ]
    )
    #expect(series.points.map(\.y) == [3, 8, 1])
  }

  private func queryResult(columns: [ColumnInfo], rows: [[CellValue]]) -> QueryResult {
    QueryResult(columns: columns, rows: rows, rowCount: rows.count, executionTime: 0)
  }
}
