//
//  ResultChartView.swift
//  Dblore
//
//  Swift Charts view of a query result. Marks on macOS 14; vectorized plots when
//  the plotted point count is over 1 000 and the system is macOS 15 or newer.
//

import Charts
import SwiftUI

/// Builds the `QueryResult` the chart models already accept.
enum ChartQueryResult {
  static func make(_ result: CellResult) -> QueryResult {
    QueryResult(
      columns: result.columns,
      rows: result.rows,
      rowCount: result.rowCount,
      executionTime: result.executionTime,
      wasLimited: result.wasLimited,
      affectedRows: result.affectedRows
    )
  }
}

/// Fixed chart height in a notebook cell. The editor panel fills its parent instead.
private let notebookChartHeight: CGFloat = 320

/// Grid or chart for one result. The toggle is shown only when a chart can be suggested,
/// unless the caller draws it elsewhere (the editor result header, or the notebook query bar).
struct ChartableResult<Grid: View>: View {
  let result: CellResult
  @Binding var chartSpec: ChartSpec?
  var fillsAvailableHeight = false
  /// Shared with the result header when that header draws the Grid / Chart control.
  var mode: Binding<ResultDisplayMode>? = nil
  var showsPicker = true
  @ViewBuilder var grid: () -> Grid

  @State private var internalMode: ResultDisplayMode = .grid

  private var modeBinding: Binding<ResultDisplayMode> {
    mode ?? $internalMode
  }

  private var suggested: ChartSpec? {
    ChartSpec.suggested(for: ChartQueryResult.make(result))
  }

  /// Stored spec when its y columns still exist; otherwise the suggestion.
  private var resolved: ChartSpec? {
    let names = Set(result.columns.map(\.name))
    if let stored = chartSpec, stored.yColumns.contains(where: { names.contains($0) }) {
      return stored
    }
    return suggested
  }

  private var showChart: Bool {
    modeBinding.wrappedValue == .chart && suggested != nil && resolved != nil
  }

  private var specBinding: Binding<ChartSpec> {
    Binding(
      get: {
        resolved ?? ChartSpec(kind: .bar, xColumn: nil, yColumns: [], seriesColumn: nil)
      },
      set: { chartSpec = $0 }
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      if showsPicker, suggested != nil {
        ResultDisplayPicker(mode: modeBinding)
      }
      if showChart, let spec = resolved {
        VStack(alignment: .leading, spacing: Spacing.sm) {
          ChartConfigBar(columns: result.columns, spec: specBinding) {
            ChartPNGExporter.export(result: result, spec: spec)
          }
          ResultChartView(result: result, spec: spec)
            .frame(maxWidth: .infinity, maxHeight: fillsAvailableHeight ? .infinity : nil)
            .frame(height: fillsAvailableHeight ? nil : notebookChartHeight)
        }
        .padding(Spacing.md)
      } else {
        grid()
          .frame(maxWidth: .infinity, maxHeight: fillsAvailableHeight ? .infinity : nil)
      }
    }
    .frame(
      maxWidth: .infinity,
      maxHeight: fillsAvailableHeight ? .infinity : nil,
      alignment: .topLeading
    )
  }
}

/// One plotted sample. `series` is never empty so a single series still has a name.
private struct PlotSample<X: Plottable>: Identifiable {
  let id: Int
  let x: X
  let y: Double
  let series: String
}

/// Draws `spec` for `result`, with a hover readout and a downsample / null footnote.
struct ResultChartView: View {
  let result: CellResult
  let spec: ChartSpec

  private var query: QueryResult { ChartQueryResult.make(result) }

  private var series: ChartSeries {
    ChartDataExtractor.points(result: query, spec: spec)
  }

  private var xIsTemporal: Bool {
    guard let name = spec.xColumn,
      let index = result.columns.firstIndex(where: { $0.name == name })
    else { return false }
    return ChartSpec.isTemporal(
      result.columns[index], values: ChartSpec.columnValues(query, at: index))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      if series.points.isEmpty {
        Text("Nothing to plot")
          .font(.small)
          .foregroundStyle(Color.foreground)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        plottedChart
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      if let footnote {
        Text(footnote)
          .font(.small)
          .foregroundStyle(Color.foreground)
      }
    }
  }

  /// Downsample and null counts come from `ChartSeries` (points kept, values dropped).
  private var footnote: String? {
    let dropped = series.droppedCount
    let sourceCount = result.rows.count * spec.yColumns.count
    let removedByDownsample = sourceCount - dropped - series.points.count
    var parts: [String] = []
    if removedByDownsample > 0 {
      parts.append("Downsampled to \(series.points.count) points")
    }
    if dropped > 0 {
      parts.append("\(dropped) nulls dropped")
    }
    guard !parts.isEmpty else { return nil }
    return parts.joined(separator: " · ")
  }

  @ViewBuilder
  private var plottedChart: some View {
    let useVectorPlots = series.points.count > 1_000
    let temporal = xIsTemporal
    let samples = Self.samples(from: series.points, temporal: temporal)
    switch samples {
    case .category(let points):
      AxisChart(
        samples: points, kind: spec.kind, useVectorPlots: useVectorPlots,
        readoutText: { Self.categoryReadout($0, samples: points) }
      )
    case .date(let points):
      AxisChart(
        samples: points, kind: spec.kind, useVectorPlots: useVectorPlots,
        readoutText: { Self.dateReadout($0, samples: points) }
      )
    case .number(let points):
      AxisChart(
        samples: points, kind: spec.kind, useVectorPlots: useVectorPlots,
        readoutText: { Self.numberReadout($0, samples: points) }
      )
    }
  }

  private enum AxisSamples {
    case category([PlotSample<String>])
    case date([PlotSample<Date>])
    case number([PlotSample<Double>])
  }

  private static func samples(from points: [ChartPoint], temporal: Bool) -> AxisSamples {
    var categories: [PlotSample<String>] = []
    var dates: [PlotSample<Date>] = []
    var numbers: [PlotSample<Double>] = []
    for (index, point) in points.enumerated() {
      let name = point.series ?? "Value"
      switch point.x {
      case .category(_, let label):
        categories.append(PlotSample(id: index, x: label, y: point.y, series: name))
      case .number(let number):
        if temporal {
          dates.append(
            PlotSample(
              id: index, x: Date(timeIntervalSince1970: number), y: point.y, series: name))
        } else {
          numbers.append(PlotSample(id: index, x: number, y: point.y, series: name))
        }
      }
    }
    if !categories.isEmpty { return .category(categories) }
    if temporal, !dates.isEmpty { return .date(dates) }
    return .number(numbers)
  }

  private static func categoryReadout(_ selected: String, samples: [PlotSample<String>]) -> String {
    readoutLine(x: selected, matches: samples.filter { $0.x == selected })
  }

  private static func numberReadout(_ selected: Double, samples: [PlotSample<Double>]) -> String {
    guard let nearest = samples.min(by: { abs($0.x - selected) < abs($1.x - selected) }) else {
      return formatNumber(selected)
    }
    return readoutLine(x: formatNumber(nearest.x), matches: samples.filter { $0.x == nearest.x })
  }

  private static func dateReadout(_ selected: Date, samples: [PlotSample<Date>]) -> String {
    guard
      let nearest = samples.min(by: {
        abs($0.x.timeIntervalSince(selected)) < abs($1.x.timeIntervalSince(selected))
      })
    else {
      return hoverDateFormatter.string(from: selected)
    }
    let label = hoverDateFormatter.string(from: nearest.x)
    return readoutLine(x: label, matches: samples.filter { $0.x == nearest.x })
  }

  private static func readoutLine<X>(x: String, matches: [PlotSample<X>]) -> String {
    let values = matches.map { "\($0.series) \(formatNumber($0.y))" }.joined(separator: "  ")
    if values.isEmpty { return x }
    return "\(x)  \(values)"
  }

  private static func formatNumber(_ value: Double) -> String {
    if !value.isFinite { return String(value) }
    if value == value.rounded(), abs(value) < 1e15 {
      return String(format: "%.0f", value)
    }
    return String(format: "%.4g", value)
  }

  private static let hoverDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
  }()
}

/// Chart for one x type. `chartXSelection` (macOS 14) drives the hover readout.
private struct AxisChart<X: Plottable>: View {
  let samples: [PlotSample<X>]
  let kind: ChartKind
  let useVectorPlots: Bool
  let readoutText: (X) -> String

  @State private var selected: X?

  private var legend: Visibility {
    Set(samples.map(\.series)).count > 1 ? .automatic : .hidden
  }

  var body: some View {
    chart
      .overlay(alignment: .topLeading) {
        if let selected {
          Text(readoutText(selected))
            .font(.monoSmall)
            .foregroundStyle(Color.foreground)
            .lineLimit(1)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xxs)
            .background(Color.appBackground.opacity(0.92))
            .allowsHitTesting(false)
        }
      }
  }

  @ViewBuilder
  private var chart: some View {
    if useVectorPlots {
      if #available(macOS 15, *) {
        vectorChart
      } else {
        markChart
      }
    } else {
      markChart
    }
  }

  private var markChart: some View {
    Chart(samples) { sample in
      mark(sample)
    }
    .chartXSelection(value: $selected)
    .chartLegend(legend)
  }

  @ChartContentBuilder
  private func mark(_ sample: PlotSample<X>) -> some ChartContent {
    let x = PlottableValue.value("X", sample.x)
    let y = PlottableValue.value("Y", sample.y)
    let series = PlottableValue.value("Series", sample.series)
    switch kind {
    case .bar:
      BarMark(x: x, y: y)
        .foregroundStyle(by: series)
    case .line:
      LineMark(x: x, y: y, series: series)
        .foregroundStyle(by: series)
    case .area:
      AreaMark(x: x, y: y, series: series)
        .foregroundStyle(by: series)
    case .point:
      PointMark(x: x, y: y)
        .foregroundStyle(by: series)
    }
  }

  @available(macOS 15, *)
  @ViewBuilder
  private var vectorChart: some View {
    if kind == .bar {
      Chart {
        BarPlot(samples, x: .value("X", \.x), y: .value("Y", \.y))
          .foregroundStyle(by: .value("Series", \.series))
      }
      .chartXSelection(value: $selected)
      .chartLegend(legend)
    } else if kind == .line {
      Chart {
        LinePlot(
          samples, x: .value("X", \.x), y: .value("Y", \.y),
          series: .value("Series", \.series))
      }
      .chartXSelection(value: $selected)
      .chartLegend(legend)
    } else if kind == .area {
      Chart {
        AreaPlot(
          samples, x: .value("X", \.x), y: .value("Y", \.y),
          series: .value("Series", \.series))
      }
      .chartXSelection(value: $selected)
      .chartLegend(legend)
    } else {
      Chart {
        PointPlot(samples, x: .value("X", \.x), y: .value("Y", \.y))
          .foregroundStyle(by: .value("Series", \.series))
      }
      .chartXSelection(value: $selected)
      .chartLegend(legend)
    }
  }
}
