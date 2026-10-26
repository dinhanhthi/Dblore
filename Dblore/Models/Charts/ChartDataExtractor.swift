// ChartDataExtractor.swift
// Finite chart points from a query result, downsampled with LTTB, optionally split in facets.

import Foundation

/// Horizontal position. A category keeps the label next to its first-seen index.
nonisolated enum ChartX: Hashable, Sendable {
  case number(Double)
  case category(index: Int, label: String)
}

/// One plotted sample. `x`, `y`, and `series` are stored.
nonisolated struct ChartPoint: Equatable, Sendable {
  var x: ChartX
  var y: Double
  var series: String?
}

/// Points ready to draw, plus how many source values were dropped.
nonisolated struct ChartSeries: Equatable, Sendable {
  var points: [ChartPoint]
  var droppedCount: Int
}

/// One small chart of a faceted spec. `removedByDownsample` counts the points LTTB left out.
nonisolated struct ChartFacet: Equatable, Sendable {
  var label: String
  var series: ChartSeries
  var removedByDownsample: Int
}

/// Small multiples for a spec with a facet column.
nonisolated struct ChartFacets: Equatable, Sendable {
  var facets: [ChartFacet]
  /// Distinct facet values past the facet cap. Their rows are not drawn.
  var omittedFacetCount: Int
  /// Lowest and highest plotted y across every facet, so the small charts share one y scale.
  /// Nil when nothing is plotted.
  var yDomain: ClosedRange<Double>?
  /// Point cap each series of each facet was downsampled to.
  var maxPoints: Int
  /// The x column is temporal in the whole result (numbers on x are seconds since 1970).
  var xIsTemporal: Bool

  var downsampledFacetCount: Int {
    facets.filter { $0.removedByDownsample > 0 }.count
  }

  var droppedCount: Int {
    facets.reduce(0) { $0 + $1.series.droppedCount }
  }
}

/// Builds `ChartPoint` values for a `ChartSpec`.
///
/// Y is coerced to `Double`. Nulls and non-finite numbers are omitted and counted.
/// A temporal x column is sorted ascending. Each series longer than `maxPoints` is
/// downsampled with Largest-Triangle-Three-Buckets, which keeps the first point,
/// the last point, and the largest triangle in every bucket (so a lone peak survives).
nonisolated enum ChartDataExtractor {
  /// `xIsTemporal` overrides the temporal decision taken on `result`'s own rows (a facet takes
  /// the one of the whole result). Nil decides on `result`.
  static func points(
    result: QueryResult, spec: ChartSpec, maxPoints: Int = 2_000, xIsTemporal: Bool? = nil
  ) -> ChartSeries {
    let xIndex = index(of: spec.xColumn, in: result.columns)
    let yIndexes = spec.yColumns.map { index(of: $0, in: result.columns) }
    let seriesIndex = index(of: spec.seriesColumn, in: result.columns)
    let temporal =
      xIsTemporal
      ?? xIndex.map { index in
        ChartSpec.isTemporal(
          result.columns[index], values: ChartSpec.columnValues(result, at: index))
      } ?? false
    let splitBySeries = spec.seriesColumn != nil
    let nameYColumns = spec.yColumns.count > 1
    // One per extraction, not shared: extraction runs off the main thread
    let dateFormatter = ISO8601DateFormatter()
    // A DATE column's `2025-01-01`, at local midnight so the axis shows that day
    let dayFormatter = ISO8601DateFormatter()
    dayFormatter.formatOptions = [.withFullDate]
    dayFormatter.timeZone = .current

    var categories: [String: Int] = [:]
    var droppedCount = 0
    var grouped: [String?: [ChartPoint]] = [:]
    var seriesOrder: [String?] = []

    for (rowIndex, row) in result.rows.enumerated() {
      var resolvedX = false
      var rowX: ChartX?
      for (offset, yIndex) in yIndexes.enumerated() {
        guard let y = finiteY(cell(row, at: yIndex)) else {
          droppedCount += 1
          continue
        }
        if !resolvedX {
          rowX = makeX(
            cell: cell(row, at: xIndex),
            rowIndex: rowIndex,
            xColumn: spec.xColumn,
            temporal: temporal,
            categories: &categories,
            dateFormatter: dateFormatter,
            dayFormatter: dayFormatter
          )
          resolvedX = true
        }
        guard let x = rowX else {
          droppedCount += 1
          continue
        }
        let series = seriesName(
          yColumn: spec.yColumns[offset],
          split: splitBySeries
            ? seriesLabel(cell(row, at: seriesIndex), dateFormatter: dateFormatter) : nil,
          nameYColumns: nameYColumns
        )
        let point = ChartPoint(x: x, y: y, series: series)
        if grouped[series] == nil {
          seriesOrder.append(series)
          grouped[series] = []
        }
        grouped[series]?.append(point)
      }
    }

    var points: [ChartPoint] = []
    for series in seriesOrder {
      var samples = grouped[series] ?? []
      if temporal {
        samples.sort { position($0.x) < position($1.x) }
      }
      points.append(contentsOf: downsample(samples, maxPoints: maxPoints))
    }
    return ChartSeries(points: points, droppedCount: droppedCount)
  }

  /// Splits `result` per value of `spec.facetColumn` and runs `points` on each facet, so every
  /// facet gets the same null handling, temporal order and LTTB. Facets come in order of first
  /// appearance (the order category x values use). At most `maxFacets` facets: rows of later
  /// values are left out and counted in `omittedFacetCount`. `maxPoints` caps each series of a
  /// facet, as it caps each series of a single chart. A NULL facet value is its own facet,
  /// labelled like a NULL cell. No facets when the facet column is missing from the result.
  /// Nil when the current task is cancelled (checked every `cancellationStride` rows and before
  /// each facet).
  static func facets(
    result: QueryResult, spec: ChartSpec, maxFacets: Int = 12, maxPoints: Int = 2_000
  ) -> ChartFacets? {
    guard let facetIndex = index(of: spec.facetColumn, in: result.columns) else {
      return ChartFacets(
        facets: [], omittedFacetCount: 0, yDomain: nil, maxPoints: maxPoints, xIsTemporal: false)
    }
    // nil is the NULL facet, kept apart from a text value that reads "NULL"
    var order: [String?] = []
    var rowsByFacet: [String?: [[CellValue]]] = [:]
    var omitted: Set<String?> = []
    let dateFormatter = ISO8601DateFormatter()
    for (rowIndex, row) in result.rows.enumerated() {
      if rowIndex % cancellationStride == 0, Task.isCancelled { return nil }
      let key = seriesLabel(cell(row, at: facetIndex), dateFormatter: dateFormatter)
      if rowsByFacet[key] == nil {
        guard order.count < maxFacets else {
          omitted.insert(key)
          continue
        }
        order.append(key)
        rowsByFacet[key] = []
      }
      rowsByFacet[key]?.append(row)
    }

    let xIsTemporal =
      index(of: spec.xColumn, in: result.columns).map { index in
        ChartSpec.isTemporal(
          result.columns[index], values: ChartSpec.columnValues(result, at: index))
      } ?? false
    var facetSpec = spec
    facetSpec.facetColumn = nil
    var facets: [ChartFacet] = []
    var low = Double.infinity
    var high = -Double.infinity
    for key in order {
      if Task.isCancelled { return nil }
      let rows = rowsByFacet[key] ?? []
      let subset = QueryResult(
        columns: result.columns, rows: rows, rowCount: rows.count,
        executionTime: result.executionTime)
      let series = points(
        result: subset, spec: facetSpec, maxPoints: maxPoints, xIsTemporal: xIsTemporal)
      for point in series.points {
        low = min(low, point.y)
        high = max(high, point.y)
      }
      let sourceCount = rows.count * spec.yColumns.count
      facets.append(
        ChartFacet(
          label: key ?? CellValue.null.displayString,
          series: series,
          removedByDownsample: sourceCount - series.droppedCount - series.points.count))
    }
    return ChartFacets(
      facets: facets,
      omittedFacetCount: omitted.count,
      yDomain: low <= high ? low...high : nil,
      maxPoints: maxPoints,
      xIsTemporal: xIsTemporal)
  }

  /// Rows between two cancellation checks of `facets`
  private static let cancellationStride = 1_024

  private static func index(of name: String?, in columns: [ColumnInfo]) -> Int? {
    guard let name else { return nil }
    return columns.firstIndex { $0.name == name }
  }

  private static func cell(_ row: [CellValue], at index: Int?) -> CellValue? {
    guard let index, index < row.count else { return nil }
    return row[index]
  }

  private static func finiteY(_ value: CellValue?) -> Double? {
    guard let value else { return nil }
    let number: Double?
    switch value {
    case .int(let int):
      number = Double(int)
    case .double(let double):
      number = double
    case .string(let text):
      number = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
    case .null, .bool, .json, .date, .data:
      number = nil
    }
    guard let number, number.isFinite else { return nil }
    return number
  }

  private static func makeX(
    cell: CellValue?,
    rowIndex: Int,
    xColumn: String?,
    temporal: Bool,
    categories: inout [String: Int],
    dateFormatter: ISO8601DateFormatter,
    dayFormatter: ISO8601DateFormatter
  ) -> ChartX? {
    guard xColumn != nil else { return .number(Double(rowIndex)) }
    guard let cell else { return nil }
    switch cell {
    case .null:
      return nil
    case .date(let date):
      return .number(date.timeIntervalSince1970)
    case .int(let int):
      return .number(Double(int))
    case .double(let double) where double.isFinite:
      return .number(double)
    case .string(let text):
      if temporal {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Double(trimmed), number.isFinite { return .number(number) }
        if let date = dateFormatter.date(from: trimmed) ?? dayFormatter.date(from: trimmed) {
          return .number(date.timeIntervalSince1970)
        }
        return nil
      }
      return .category(index: categoryIndex(for: text, in: &categories), label: text)
    case .bool, .json, .data, .double:
      return nil
    }
  }

  private static func categoryIndex(for label: String, in categories: inout [String: Int]) -> Int {
    if let existing = categories[label] { return existing }
    let index = categories.count
    categories[label] = index
    return index
  }

  private static func seriesLabel(
    _ value: CellValue?, dateFormatter: ISO8601DateFormatter
  ) -> String? {
    switch value {
    case .string(let text), .json(let text):
      return text
    case .int(let int):
      return String(int)
    case .double(let double):
      return String(double)
    case .bool(let flag):
      return flag ? "true" : "false"
    case .date(let date):
      return dateFormatter.string(from: date)
    case .data(let data):
      return data.base64EncodedString()
    case .none, .null:
      return nil
    }
  }

  private static func seriesName(yColumn: String, split: String?, nameYColumns: Bool) -> String? {
    if nameYColumns {
      if let split { return "\(split) · \(yColumn)" }
      return yColumn
    }
    return split
  }

  private static func position(_ x: ChartX) -> Double {
    switch x {
    case .number(let number):
      return number
    case .category(let index, _):
      return Double(index)
    }
  }

  /// Largest-Triangle-Three-Buckets. `maxPoints` includes the kept endpoints.
  private static func downsample(_ points: [ChartPoint], maxPoints: Int) -> [ChartPoint] {
    let count = points.count
    guard maxPoints < count else { return points }
    guard count >= 2, maxPoints >= 2 else {
      if maxPoints >= 1, let first = points.first { return [first] }
      return []
    }
    if maxPoints == 2 {
      return [points[0], points[count - 1]]
    }

    var sampled: [ChartPoint] = []
    sampled.reserveCapacity(maxPoints)
    sampled.append(points[0])

    let bucketSize = Double(count - 2) / Double(maxPoints - 2)
    var previous = 0
    for bucket in 0..<(maxPoints - 2) {
      let average = bucketAverage(
        points, from: bucketBound(bucket + 1, bucketSize: bucketSize, count: count),
        to: bucketBound(bucket + 2, bucketSize: bucketSize, count: count))
      let start = bucketBound(bucket, bucketSize: bucketSize, count: count)
      let end = bucketBound(bucket + 1, bucketSize: bucketSize, count: count)
      let selected = largestTriangle(
        points, from: start, to: end, previous: previous, average: average)
      sampled.append(points[selected])
      previous = selected
    }
    sampled.append(points[count - 1])
    return sampled
  }

  /// `floor(step * bucketSize) + 1`, clamped to the last index (the endpoint is not a candidate).
  private static func bucketBound(_ step: Int, bucketSize: Double, count: Int) -> Int {
    let bound = Int((Double(step) * bucketSize).rounded(.down)) + 1
    return min(bound, count)
  }

  private static func bucketAverage(
    _ points: [ChartPoint], from start: Int, to end: Int
  ) -> (x: Double, y: Double) {
    let last = points[points.count - 1]
    guard end > start else { return (position(last.x), last.y) }
    var sumX = 0.0
    var sumY = 0.0
    for index in start..<end {
      sumX += position(points[index].x)
      sumY += points[index].y
    }
    let length = Double(end - start)
    return (sumX / length, sumY / length)
  }

  private static func largestTriangle(
    _ points: [ChartPoint], from start: Int, to end: Int, previous: Int,
    average: (x: Double, y: Double)
  ) -> Int {
    let anchorX = position(points[previous].x)
    let anchorY = points[previous].y
    var maxArea = -1.0
    var selected = min(start, points.count - 1)
    guard start < end else { return selected }
    for index in start..<end {
      let x = position(points[index].x)
      let y = points[index].y
      let area =
        abs((anchorX - average.x) * (y - anchorY) - (anchorX - x) * (average.y - anchorY)) * 0.5
      if area > maxArea {
        maxArea = area
        selected = index
      }
    }
    return selected
  }
}
