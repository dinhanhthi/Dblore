// ChartDataExtractorTests.swift
// Point extraction: finite y values, temporal order, LTTB downsampling, and facets.

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

  @Test("A DATE column's date-only text charts as a temporal x")
  func dateOnlyTextChartsAsTemporal() {
    let result = queryResult(
      columns: [
        ColumnInfo(name: "month", type: "DATE"),
        ColumnInfo(name: "value", type: "float8"),
      ],
      rows: [
        [.string("2025-02-01"), .double(20)],
        [.string("2025-01-01"), .double(10)],
      ]
    )
    let spec = ChartSpec(kind: .line, xColumn: "month", yColumns: ["value"], seriesColumn: nil)
    let series = ChartDataExtractor.points(result: result, spec: spec)

    #expect(series.droppedCount == 0)
    #expect(series.points.map(\.y) == [10, 20])
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

  @Test("Facets split the points per value in first-seen order, NULL as its own facet")
  func facetsSplitPerValue() throws {
    let result = queryResult(
      columns: [
        ColumnInfo(name: "region", type: "text"),
        ColumnInfo(name: "value", type: "int4"),
      ],
      rows: [
        [.string("west"), .int(1)],
        [.null, .int(5)],
        [.string("east"), .int(2)],
        [.string("west"), .int(3)],
      ]
    )
    let spec = ChartSpec(
      kind: .bar, xColumn: nil, yColumns: ["value"], seriesColumn: nil, facetColumn: "region")
    let faceted = try #require(ChartDataExtractor.facets(result: result, spec: spec))

    #expect(faceted.facets.map(\.label) == ["west", "NULL", "east"])
    #expect(faceted.facets.map { $0.series.points.map(\.y) } == [[1, 3], [5], [2]])
    #expect(faceted.omittedFacetCount == 0)
  }

  @Test("At most 12 facets are drawn; the rest are counted as omitted")
  func facetCountIsCapped() throws {
    let rows: [[CellValue]] = (0..<15).map { [.string("f\($0)"), .int($0)] }
    let result = queryResult(
      columns: [
        ColumnInfo(name: "name", type: "text"),
        ColumnInfo(name: "value", type: "int4"),
      ],
      rows: rows
    )
    let spec = ChartSpec(
      kind: .bar, xColumn: nil, yColumns: ["value"], seriesColumn: nil, facetColumn: "name")
    let faceted = try #require(ChartDataExtractor.facets(result: result, spec: spec))

    #expect(faceted.facets.map(\.label) == (0..<12).map { "f\($0)" })
    #expect(faceted.omittedFacetCount == 3)
  }

  @Test("Each facet is downsampled to the point cap and the cut is reported")
  func facetPointsAreCapped() throws {
    var rows: [[CellValue]] = (0..<30).map { [.string("big"), .int($0)] }
    rows += (0..<5).map { [.string("small"), .int($0)] }
    let result = queryResult(
      columns: [
        ColumnInfo(name: "name", type: "text"),
        ColumnInfo(name: "value", type: "int4"),
      ],
      rows: rows
    )
    let spec = ChartSpec(
      kind: .line, xColumn: nil, yColumns: ["value"], seriesColumn: nil, facetColumn: "name")
    let faceted = try #require(ChartDataExtractor.facets(result: result, spec: spec, maxPoints: 10))

    #expect(faceted.facets.map { $0.series.points.count } == [10, 5])
    #expect(faceted.facets.map(\.removedByDownsample) == [20, 0])
    #expect(faceted.downsampledFacetCount == 1)
  }

  @Test("The y domain is shared across all facets")
  func facetsShareTheYDomain() throws {
    let result = queryResult(
      columns: [
        ColumnInfo(name: "name", type: "text"),
        ColumnInfo(name: "value", type: "float8"),
      ],
      rows: [
        [.string("low"), .double(1)],
        [.string("low"), .double(2)],
        [.string("high"), .double(-4)],
        [.string("high"), .double(40)],
      ]
    )
    let spec = ChartSpec(
      kind: .point, xColumn: nil, yColumns: ["value"], seriesColumn: nil, facetColumn: "name")
    let faceted = try #require(ChartDataExtractor.facets(result: result, spec: spec))

    #expect(faceted.yDomain == -4...40)
  }

  @Test("A facet whose own x values are dates still follows the result-wide temporal decision")
  func facetsShareTheTemporalDecision() throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let result = queryResult(
      columns: [
        ColumnInfo(name: "kind", type: "text"),
        ColumnInfo(name: "seen", type: "mixed"),
        ColumnInfo(name: "value", type: "float8"),
      ],
      rows: [
        [.string("dated"), .date(start.addingTimeInterval(20)), .double(20)],
        [.string("dated"), .date(start), .double(10)],
        [.string("named"), .string("later"), .double(5)],
      ]
    )
    let spec = ChartSpec(
      kind: .line, xColumn: "seen", yColumns: ["value"], seriesColumn: nil, facetColumn: "kind")
    let faceted = try #require(ChartDataExtractor.facets(result: result, spec: spec))

    #expect(!faceted.xIsTemporal)
    // Not temporal: the dated facet keeps row order instead of sorting by date
    #expect(faceted.facets.map { $0.series.points.map(\.y) } == [[20, 10], [5]])
  }

  private func queryResult(columns: [ColumnInfo], rows: [[CellValue]]) -> QueryResult {
    QueryResult(columns: columns, rows: rows, rowCount: rows.count, executionTime: 0)
  }
}
