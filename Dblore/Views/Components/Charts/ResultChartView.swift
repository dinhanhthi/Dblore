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
  /// Shown statement of a multi-statement run, part of the facet request.
  var statementIndex: Int? = nil
  @ViewBuilder var grid: () -> Grid

  @State private var internalMode: ResultDisplayMode = .grid
  /// Facets of a faceted spec, built off the main thread, with the request they answer.
  @State private var loadedFacets: LoadedFacets?

  /// What facet extraction reads: the plotted columns and the rows. The timestamp stands for
  /// the rows of one run, `dataRevision` for rows replaced within that run. `sourceQuery` and
  /// `statementIndex` tell the statements of one run apart: a file stores timestamps in whole
  /// seconds, so the statements of a fast run share one, and two statements can share a query.
  /// The chart kind is left out: it changes how facets are drawn, not what they hold.
  private struct FacetRequest: Equatable {
    var xColumn: String?
    var yColumns: [String]
    var seriesColumn: String?
    var facetColumn: String?
    var sourceQuery: String?
    var statementIndex: Int?
    var timestamp: Date
    var rowCount: Int
    var dataRevision: Int
  }

  private struct LoadedFacets {
    var request: FacetRequest
    var facets: ChartFacets
  }

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
          ChartConfigBar(
            columns: result.columns, spec: specBinding,
            exportEnabled: !ResultChartView.isFaceted(spec, columns: result.columns)
              || facets(for: spec) != nil
          ) {
            ChartPNGExporter.export(result: result, spec: spec, facets: facets(for: spec))
          }
          ResultChartView(result: result, spec: spec, facets: facets(for: spec))
            .frame(maxWidth: .infinity, maxHeight: fillsAvailableHeight ? .infinity : nil)
            .frame(height: fillsAvailableHeight ? nil : notebookChartHeight)
            .task(id: facetRequest(for: spec)) { await loadFacets(for: spec) }
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

extension ChartableResult {
  /// Nil when `spec` is not faceted.
  private func facetRequest(for spec: ChartSpec) -> FacetRequest? {
    guard ResultChartView.isFaceted(spec, columns: result.columns) else { return nil }
    return FacetRequest(
      xColumn: spec.xColumn, yColumns: spec.yColumns, seriesColumn: spec.seriesColumn,
      facetColumn: spec.facetColumn, sourceQuery: result.sourceQuery,
      statementIndex: statementIndex, timestamp: result.timestamp, rowCount: result.rows.count,
      dataRevision: result.dataRevision)
  }

  /// Loaded facets of `spec`; nil while they are built or when they belong to another spec.
  private func facets(for spec: ChartSpec) -> ChartFacets? {
    guard let loadedFacets, loadedFacets.request == facetRequest(for: spec) else { return nil }
    return loadedFacets.facets
  }

  /// Splits the rows off the main thread: up to 12 charts of 2,000 points each. Facets already
  /// loaded for the request (the chart shown again, or only the kind changed) are kept.
  private func loadFacets(for spec: ChartSpec) async {
    guard let request = facetRequest(for: spec) else {
      loadedFacets = nil
      return
    }
    if loadedFacets?.request == request { return }
    let query = ChartQueryResult.make(result)
    guard let facets = await buildFacets(query, spec: spec), !Task.isCancelled else { return }
    loadedFacets = LoadedFacets(request: request, facets: facets)
  }
}

/// Facets off the main actor. Awaited, not detached, so the `.task` cancellation reaches the
/// extraction loop. Nil when cancelled.
@concurrent private nonisolated func buildFacets(
  _ query: QueryResult, spec: ChartSpec
) async -> ChartFacets? {
  ChartDataExtractor.facets(result: query, spec: spec)
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
  /// Facets of a faceted spec, built by the caller off the main thread; nil while loading.
  var facets: ChartFacets? = nil
  /// Off for PNG export: the facet grid is laid out in full instead of scrolling.
  var scrollsFacets = true

  /// The spec splits the chart by a column the result has.
  static func isFaceted(_ spec: ChartSpec, columns: [ColumnInfo]) -> Bool {
    guard let name = spec.facetColumn else { return false }
    return columns.contains { $0.name == name }
  }

  /// Name of the series of a point without one.
  fileprivate static let defaultSeriesName = "Value"

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
    if Self.isFaceted(spec, columns: result.columns) {
      facetedChart
    } else {
      singleChart
    }
  }

  private var singleChart: some View {
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

  @ViewBuilder
  private var facetedChart: some View {
    if let facets {
      VStack(alignment: .leading, spacing: Spacing.xs) {
        if facets.facets.isEmpty {
          Text("Nothing to plot")
            .font(.small)
            .foregroundStyle(Color.foreground)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ChartFacetGrid(facets: facets, kind: spec.kind, scrolls: scrollsFacets)
            .frame(maxWidth: .infinity, maxHeight: scrollsFacets ? .infinity : nil)
        }
        if let footnote = Self.facetFootnote(facets) {
          Text(footnote)
            .font(.small)
            .foregroundStyle(Color.foreground)
        }
      }
    } else {
      ProgressView()
        .controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  /// Facet cap, per-facet downsampling and null counts, like the single chart's footnote.
  private static func facetFootnote(_ facets: ChartFacets) -> String? {
    var parts: [String] = []
    if facets.omittedFacetCount > 0 {
      let total = facets.facets.count + facets.omittedFacetCount
      parts.append("Showing \(facets.facets.count) of \(total) facets")
    }
    if facets.downsampledFacetCount > 0 {
      parts.append("Downsampled to \(facets.maxPoints) points per facet")
    }
    if facets.droppedCount > 0 {
      parts.append("\(facets.droppedCount) nulls dropped")
    }
    guard !parts.isEmpty else { return nil }
    return parts.joined(separator: " · ")
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

  private var plottedChart: some View {
    Self.plot(series, kind: spec.kind, temporal: xIsTemporal)
  }

  /// One chart of `series`. `scales` makes the small charts of a facet grid share their axes.
  /// `legend` overrides the chart's own legend (a facet grid draws one shared legend). A date
  /// axis is drawn in the zone the grid shows its column in (`ChartSeries.xTimeZone`).
  @ViewBuilder
  fileprivate static func plot(
    _ series: ChartSeries, kind: ChartKind, temporal: Bool, scales: SharedScales? = nil,
    legend: Visibility? = nil
  ) -> some View {
    let useVectorPlots = series.points.count > 1_000
    switch samples(from: series.points, temporal: temporal) {
    case .category(let points):
      AxisChart(
        samples: points, kind: kind, useVectorPlots: useVectorPlots, scales: scales,
        legendOverride: legend, readoutText: { categoryReadout($0, samples: points) }
      )
    case .date(let points):
      let axis = ChartDateAxis(domain: dateDomain(points, scales: scales), zone: series.xTimeZone)
      AxisChart(
        samples: points, kind: kind, useVectorPlots: useVectorPlots, scales: scales,
        legendOverride: legend,
        readoutText: { dateReadout($0, samples: points, text: series.xText) }
      )
      .chartXAxis {
        AxisMarks(values: axis.values) { _ in
          AxisGridLine()
          AxisTick()
          AxisValueLabel(format: axis.format)
        }
      }
      .environment(\.timeZone, series.xTimeZone)
      .environment(\.calendar, axis.calendar)
    case .number(let points):
      AxisChart(
        samples: points, kind: kind, useVectorPlots: useVectorPlots, scales: scales,
        legendOverride: legend, readoutText: { numberReadout($0, samples: points) }
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
      let name = point.series ?? defaultSeriesName
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

  /// `text` is the grid's text of a date of the x column (`ChartSeries.xText`)
  private static func dateReadout(
    _ selected: Date, samples: [PlotSample<Date>], text: (Date) -> String
  ) -> String {
    guard
      let nearest = samples.min(by: {
        abs($0.x.timeIntervalSince(selected)) < abs($1.x.timeIntervalSince(selected))
      })
    else {
      return text(selected)
    }
    return readoutLine(x: text(nearest.x), matches: samples.filter { $0.x == nearest.x })
  }

  /// The x range the axis spans: the facet grid's shared one, else the points'
  private static func dateDomain(
    _ samples: [PlotSample<Date>], scales: SharedScales?
  ) -> ClosedRange<Date> {
    if case .dates(let range) = scales?.x { return range }
    let dates = samples.map(\.x)
    guard let low = dates.min(), let high = dates.max() else { return Date()...Date() }
    return low...high
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
}

/// Ticks and labels of a date x axis, both in `zone`, the one the grid shows the column in
/// (`ChartSeries.xTimeZone`): the automatic axis labels follow the Mac's zone, not the
/// environment's. The step is the shortest that leaves at most `maxTicks` ticks over the span:
/// times of day, then days, months and years. Steps start on a whole minute, hour, day, month
/// or year of `zone`.
nonisolated struct ChartDateAxis {
  let values: [Date]
  let format: Date.FormatStyle
  let calendar: Calendar

  static let maxTicks = 6

  private struct Step {
    var component: Calendar.Component
    var count: Int
    var seconds: Double
  }

  private static let day = 86_400.0
  private static let year = 365.25 * day

  private static let steps: [Step] =
    [1, 5, 15, 30].map { Step(component: .second, count: $0, seconds: Double($0)) }
    + [1, 5, 15, 30].map { Step(component: .minute, count: $0, seconds: Double($0) * 60) }
    + [1, 3, 6, 12].map { Step(component: .hour, count: $0, seconds: Double($0) * 3_600) }
    + [1, 2, 7, 14].map { Step(component: .day, count: $0, seconds: Double($0) * day) }
    + [1, 3, 6].map { Step(component: .month, count: $0, seconds: Double($0) * year / 12) }
    + [1, 2, 5, 10, 25, 50, 100, 250, 500, 1_000].map {
      Step(component: .year, count: $0, seconds: Double($0) * year)
    }

  init(domain: ClosedRange<Date>, zone: TimeZone, locale: Locale = .autoupdatingCurrent) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    calendar.locale = locale
    self.calendar = calendar
    let base = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: zone)
    let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
    // An infinite or zero span (absurd numbers in a date column, or one date) gets one tick
    guard span > 0, span.isFinite else {
      // One date: its day, and its time unless it is midnight
      values = [domain.lowerBound]
      let date = base.month(.abbreviated).day().year()
      format =
        calendar.startOfDay(for: domain.lowerBound) == domain.lowerBound
        ? date : date.hour().minute()
      return
    }
    let step =
      Self.steps.first { span / $0.seconds <= Double(Self.maxTicks) }
      ?? Step(
        component: .year,
        count: Int(min((span / (Double(Self.maxTicks) * Self.year)).rounded(.up), 1_000_000)),
        seconds: 0)
    let ticks = Self.ticks(domain, step: step, calendar: calendar)
    values = ticks.isEmpty ? [domain.lowerBound] : ticks
    switch step.component {
    case .second: format = base.hour().minute().second()
    case .minute: format = base.hour().minute()
    case .hour: format = span > Self.day ? base.month(.abbreviated).day().hour() : base.hour()
    case .day: format = base.month(.abbreviated).day()
    case .month: format = base.month(.abbreviated).year()
    default: format = base.year()
    }
  }

  /// Every multiple of `step` from the start of the enclosing minute, hour, day, month or year
  /// (for a year step, the last year that is a multiple of its count) that falls in `domain`
  private static func ticks(
    _ domain: ClosedRange<Date>, step: Step, calendar: Calendar
  ) -> [Date] {
    let anchor: Date?
    switch step.component {
    case .second: anchor = calendar.dateInterval(of: .minute, for: domain.lowerBound)?.start
    case .minute: anchor = calendar.dateInterval(of: .hour, for: domain.lowerBound)?.start
    case .hour: anchor = calendar.startOfDay(for: domain.lowerBound)
    case .day: anchor = calendar.dateInterval(of: .month, for: domain.lowerBound)?.start
    case .month: anchor = calendar.dateInterval(of: .year, for: domain.lowerBound)?.start
    default:
      let year = calendar.component(.year, from: domain.lowerBound)
      let first = year - ((year % step.count) + step.count) % step.count
      anchor = calendar.date(from: DateComponents(year: first, month: 1, day: 1))
    }
    guard let anchor else { return [] }
    var ticks: [Date] = []
    // Bounded: the anchor is at most one enclosing unit before the domain
    for multiple in 0..<10_000 {
      guard
        let tick = calendar.date(
          byAdding: step.component, value: multiple * step.count, to: anchor),
        tick <= domain.upperBound
      else { break }
      if tick >= domain.lowerBound { ticks.append(tick) }
    }
    return ticks
  }
}

/// Chart for one x type. `chartXSelection` (macOS 14) drives the hover readout.
private struct AxisChart<X: Plottable>: View {
  let samples: [PlotSample<X>]
  let kind: ChartKind
  let useVectorPlots: Bool
  var scales: SharedScales? = nil
  var legendOverride: Visibility? = nil
  let readoutText: (X) -> String

  @State private var selected: X?

  private var legend: Visibility {
    if let legendOverride { return legendOverride }
    return Set(samples.map(\.series)).count > 1 ? .automatic : .hidden
  }

  var body: some View {
    chart
      .sharedXScale(scales?.x)
      .sharedYScale(scales?.y)
      .sharedSeriesScale(scales?.series)
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

/// Small multiples: one titled chart per facet, every chart on the same x, y and series scales.
/// One legend above the grid when there are several series; the small charts draw none.
/// Scrolls in an adaptive grid; PNG export lays it out in full instead.
private struct ChartFacetGrid: View {
  let facets: ChartFacets
  let kind: ChartKind
  let scrolls: Bool

  private static let cellHeight: CGFloat = 180
  private static let minCellWidth: CGFloat = 240
  private static let exportColumns = 4

  var body: some View {
    let scales = SharedScales(facets: facets, kind: kind)
    VStack(alignment: .leading, spacing: Spacing.sm) {
      if scales.series.count > 1 {
        SharedSeriesLegend(series: scales.series)
      }
      grid(scales: scales)
    }
  }

  @ViewBuilder
  private func grid(scales: SharedScales) -> some View {
    if scrolls {
      ScrollView {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: Self.minCellWidth), spacing: Spacing.md)],
          spacing: Spacing.md
        ) {
          ForEach(facets.facets.indices, id: \.self) { index in
            cell(facets.facets[index], scales: scales)
          }
        }
      }
    } else {
      Grid(horizontalSpacing: Spacing.md, verticalSpacing: Spacing.md) {
        ForEach(exportRows, id: \.self) { row in
          GridRow {
            ForEach(row, id: \.self) { index in
              cell(facets.facets[index], scales: scales)
            }
          }
        }
      }
    }
  }

  private var exportRows: [[Int]] {
    stride(from: 0, to: facets.facets.count, by: Self.exportColumns).map { start in
      Array(start..<min(start + Self.exportColumns, facets.facets.count))
    }
  }

  private func cell(_ facet: ChartFacet, scales: SharedScales) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(verbatim: facet.label)
        .font(.small)
        .fontWeight(.medium)
        .foregroundStyle(Color.foreground)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(facet.label)
      if facet.series.points.isEmpty {
        Text("Nothing to plot")
          .font(.small)
          .foregroundStyle(Color.foregroundMuted)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ResultChartView.plot(
          facet.series, kind: kind, temporal: facets.xIsTemporal, scales: scales,
          legend: .hidden
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .padding(Spacing.sm)
    .frame(maxWidth: .infinity)
    .frame(height: Self.cellHeight)
    .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: CornerRadius.lg))
    .overlay(HairlineBorder(shape: RoundedRectangle(cornerRadius: CornerRadius.lg)))
  }
}

/// The series legend of a facet grid, drawn by Swift Charts on the grid's series scale so its
/// colors are the small charts' colors. The plot area has no height and its marks are invisible.
private struct SharedSeriesLegend: View {
  let series: [String]

  var body: some View {
    Chart(series, id: \.self) { name in
      PointMark(x: .value("X", 0), y: .value("Y", 0))
        .foregroundStyle(by: .value("Series", name))
        .opacity(0)
    }
    .sharedSeriesScale(series)
    .chartXAxis(.hidden)
    .chartYAxis(.hidden)
    .chartLegend(position: .top, alignment: .leading)
    .chartPlotStyle { plot in plot.frame(height: 0) }
    .fixedSize(horizontal: false, vertical: true)
  }
}

/// X domain shared by the charts of a facet grid.
private enum SharedXDomain {
  case categories([String])
  case numbers(ClosedRange<Double>)
  case dates(ClosedRange<Date>)
}

/// Scales the small charts of a facet grid share, so their marks compare across charts.
private struct SharedScales {
  var x: SharedXDomain?
  var y: ClosedRange<Double>?
  /// Series names in first-seen order: one color per series in every chart.
  var series: [String]

  init(facets: ChartFacets, kind: ChartKind) {
    var categories: [String] = []
    var seenCategories: Set<String> = []
    var names: [String] = []
    var seenNames: Set<String> = []
    var low = Double.infinity
    var high = -Double.infinity
    for facet in facets.facets {
      for point in facet.series.points {
        let name = point.series ?? ResultChartView.defaultSeriesName
        if seenNames.insert(name).inserted { names.append(name) }
        switch point.x {
        case .category(_, let label):
          if seenCategories.insert(label).inserted { categories.append(label) }
        case .number(let number):
          low = min(low, number)
          high = max(high, number)
        }
      }
    }
    if !categories.isEmpty {
      x = .categories(categories)
    } else if low < high {
      x =
        facets.xIsTemporal
        ? .dates(Date(timeIntervalSince1970: low)...Date(timeIntervalSince1970: high))
        : .numbers(low...high)
    } else {
      x = nil
    }
    y = Self.yDomain(facets, kind: kind)
    series = names
  }

  /// The extractor's domain. Bars and areas start at zero and stack the values of one x, so
  /// theirs also covers zero and the stacked totals; lines and points get 5% headroom. A flat
  /// domain is widened to stay valid.
  private static func yDomain(_ facets: ChartFacets, kind: ChartKind) -> ClosedRange<Double>? {
    guard let domain = facets.yDomain else { return nil }
    var low = domain.lowerBound
    var high = domain.upperBound
    if kind == .bar || kind == .area {
      low = min(low, 0)
      high = max(high, 0)
      for facet in facets.facets {
        var above: [ChartX: Double] = [:]
        var below: [ChartX: Double] = [:]
        for point in facet.series.points {
          if point.y >= 0 {
            above[point.x, default: 0] += point.y
          } else {
            below[point.x, default: 0] += point.y
          }
        }
        high = max(high, above.values.max() ?? high)
        low = min(low, below.values.min() ?? low)
      }
    } else {
      // Lines and points: a little headroom so the extremes do not sit on the plot edge
      let pad = (high - low) * 0.05
      low -= pad
      high += pad
    }
    if low == high {
      low -= 1
      high += 1
    }
    return low...high
  }
}

extension View {
  @ViewBuilder
  fileprivate func sharedXScale(_ domain: SharedXDomain?) -> some View {
    switch domain {
    case .categories(let labels):
      chartXScale(domain: labels)
    case .numbers(let range):
      chartXScale(domain: range)
    case .dates(let range):
      chartXScale(domain: range)
    case nil:
      self
    }
  }

  @ViewBuilder
  fileprivate func sharedYScale(_ domain: ClosedRange<Double>?) -> some View {
    if let domain {
      chartYScale(domain: domain)
    } else {
      self
    }
  }

  @ViewBuilder
  fileprivate func sharedSeriesScale(_ names: [String]?) -> some View {
    if let names, !names.isEmpty {
      chartForegroundStyleScale(domain: names)
    } else {
      self
    }
  }
}
