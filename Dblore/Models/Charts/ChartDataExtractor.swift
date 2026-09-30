// ChartDataExtractor.swift
// Finite chart points from a query result, downsampled with LTTB.

import Foundation

/// Horizontal position. A category keeps the label next to its first-seen index.
nonisolated enum ChartX: Equatable, Sendable {
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

/// Builds `ChartPoint` values for a `ChartSpec`.
///
/// Y is coerced to `Double`. Nulls and non-finite numbers are omitted and counted.
/// A temporal x column is sorted ascending. Each series longer than `maxPoints` is
/// downsampled with Largest-Triangle-Three-Buckets, which keeps the first point,
/// the last point, and the largest triangle in every bucket (so a lone peak survives).
nonisolated enum ChartDataExtractor {
  static func points(
    result: QueryResult, spec: ChartSpec, maxPoints: Int = 2_000
  ) -> ChartSeries {
    let xIndex = index(of: spec.xColumn, in: result.columns)
    let yIndexes = spec.yColumns.map { index(of: $0, in: result.columns) }
    let seriesIndex = index(of: spec.seriesColumn, in: result.columns)
    let temporal =
      xIndex.map { index in
        ChartSpec.isTemporal(
          result.columns[index], values: ChartSpec.columnValues(result, at: index))
      } ?? false
    let splitBySeries = spec.seriesColumn != nil
    let nameYColumns = spec.yColumns.count > 1

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
            categories: &categories
          )
          resolvedX = true
        }
        guard let x = rowX else {
          droppedCount += 1
          continue
        }
        let series = seriesName(
          yColumn: spec.yColumns[offset],
          split: splitBySeries ? seriesLabel(cell(row, at: seriesIndex)) : nil,
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
    categories: inout [String: Int]
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
        if let date = ISO8601DateFormatter().date(from: trimmed) {
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

  private static func seriesLabel(_ value: CellValue?) -> String? {
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
      return ISO8601DateFormatter().string(from: date)
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
