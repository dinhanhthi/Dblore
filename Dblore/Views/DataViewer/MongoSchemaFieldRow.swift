//
//  MongoSchemaFieldRow.swift
//  Dblore
//
//  One field of a MongoDB schema analysis: its path, a stacked bar of the types it holds in the
//  sample ("undefined" where a document lacks it), and its values: a bar chart of the most
//  common ones, weekday and hour histograms for dates and ObjectId times, or sample chips.
//  Everything shown is derived once in `init`. A click on a type or a top value hands its
//  filter condition to the Schema view (Shift adds the value to the field's `$in`).
//

import Charts
import SwiftUI

struct MongoSchemaFieldRow: View {
  let field: MongoSchemaAnalyzer.Field
  /// Called with the clicked condition and whether Shift was held
  let onFilter: (MongoSchemaFilter.Condition, _ adding: Bool) -> Void

  /// No key of the path is empty, holds a dot or starts with `$`: a dotted path addresses it
  private let isFilterable: Bool
  private let parentPrefix: String
  private let leafName: String
  private let segments: [TypeSegment]
  private let elementsLine: String?
  private let detail: Detail

  private enum Layout {
    static let typeColumn: CGFloat = 240
    static let typeBarHeight: CGFloat = 6
    static let valueChartHeight: CGFloat = 76
    static let histogramHeight: CGFloat = 56
    /// Top values above this count hide their x labels
    static let labeledValueLimit = 8
  }

  private static let unfilterableHelp = "This field name can't be used in a filter"

  fileprivate struct TypeSegment: Identifiable {
    var id: String { name }
    let name: String
    let fraction: Double
    let percent: String
    let color: Color
  }

  fileprivate struct ValuePoint: Identifiable {
    var id: String { key }
    /// Unique x category (the analyzer's values are distinct)
    let key: String
    /// Strings quoted, so the string "5" and the number 5 read apart
    let label: String
    let fraction: Double
    let percent: String
    /// Exact value to filter on; nil when the counted text was cut
    let filterValue: MongoValue?
  }

  fileprivate struct BucketPoint: Identifiable {
    var id: String { key }
    let key: String
    let count: Int
  }

  private enum Detail {
    case values(points: [ValuePoint], summary: String?)
    case dates(weekdays: [BucketPoint], hours: [BucketPoint], range: String)
    case samples([String])
    case none
  }

  init(
    field: MongoSchemaAnalyzer.Field,
    onFilter: @escaping (MongoSchemaFilter.Condition, _ adding: Bool) -> Void
  ) {
    self.field = field
    self.onFilter = onFilter
    isFilterable = field.keyPath.allSatisfy { key in
      !key.isEmpty && !key.contains(".") && !key.hasPrefix("$")
    }
    parentPrefix = field.depth > 1 ? field.parentPath + "." : ""
    leafName = field.name.isEmpty ? #""""# : field.name
    let total = field.types.reduce(0) { $0 + $1.count }
    segments = field.types.map { share in
      TypeSegment(
        name: share.name, fraction: Self.fraction(share.count, of: total),
        percent: Self.percent(share.count, of: total), color: Self.color(ofType: share.name))
    }
    elementsLine = field.elementTypes.flatMap { types in
      types.isEmpty ? nil : "elements: " + types.map(\.name).joined(separator: ", ")
    }
    detail = Self.detail(of: field)
  }

  var body: some View {
    HStack(alignment: .top, spacing: Spacing.lg) {
      typeColumn
        .frame(width: Layout.typeColumn, alignment: .leading)
      detailView
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(Spacing.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardStyle()
    .padding(.leading, CGFloat(max(field.depth - 1, 0)) * Spacing.lg)
  }

  // MARK: - Types

  private var typeColumn: some View {
    VStack(alignment: .leading, spacing: Spacing.xsm) {
      HStack(spacing: 0) {
        if !parentPrefix.isEmpty {
          Text(parentPrefix)
            .foregroundColor(.foregroundSubtle)
            .lineLimit(1)
            .truncationMode(.head)
        }
        Text(leafName)
          .fontWeight(.semibold)
          .foregroundColor(.foreground)
          .lineLimit(1)
          .truncationMode(.middle)
          .layoutPriority(1)
      }
      .font(.monoMedium)
      .help(field.path)
      typeBar
      typeLegend
      if let elementsLine {
        Text(elementsLine)
          .font(.smallest)
          .foregroundColor(.foregroundMuted)
          .lineLimit(1)
          .truncationMode(.tail)
          .help(elementsLine)
      }
    }
  }

  /// One segment per type, as wide as its share of the occurrences
  private var typeBar: some View {
    GeometryReader { geometry in
      HStack(spacing: 1) {
        ForEach(segments) { segment in
          Rectangle()
            .fill(segment.color)
            .frame(width: max(0, geometry.size.width * segment.fraction - 1))
        }
      }
    }
    .frame(height: Layout.typeBarHeight)
    .clipShape(Capsule())
    .accessibilityHidden(true)
  }

  /// "string 74%" per type, each a filter button: one line when it fits, else stacked
  @ViewBuilder
  private var typeLegend: some View {
    let legend = ViewThatFits(in: .horizontal) {
      HStack(spacing: Spacing.sm) { legendItems }
      VStack(alignment: .leading, spacing: Spacing.xxs) { legendItems }
    }
    if isFilterable {
      legend
    } else {
      // The help on the container: a disabled button may not show its own
      legend
        .disabled(true)
        .help(Self.unfilterableHelp)
    }
  }

  private var legendItems: some View {
    ForEach(segments) { segment in
      TypeShareButton(segment: segment) {
        filter(
          segment.name == MongoSchemaAnalyzer.undefinedTypeName ? .missing : .type(segment.name))
      }
    }
  }

  /// Hands the clicked condition on, with Shift read at click time
  private func filter(_ kind: MongoSchemaFilter.Kind) {
    let adding = NSEvent.modifierFlags.contains(.shift)
    onFilter(MongoSchemaFilter.Condition(keyPath: field.keyPath, kind: kind), adding)
  }

  // MARK: - Values

  @ViewBuilder
  private var detailView: some View {
    switch detail {
    case .values(let points, let summary):
      VStack(alignment: .leading, spacing: Spacing.xs) {
        if isFilterable {
          ValueChart(
            points: points, showsLabels: points.count <= Layout.labeledValueLimit,
            onSelect: { filter(.value($0)) }
          )
          .frame(height: Layout.valueChartHeight)
        } else {
          ValueChart(
            points: points, showsLabels: points.count <= Layout.labeledValueLimit, onSelect: nil
          )
          .frame(height: Layout.valueChartHeight)
          .help(Self.unfilterableHelp)
        }
        if let summary {
          caption(summary)
        }
      }
    case .dates(let weekdays, let hours, let range):
      VStack(alignment: .leading, spacing: Spacing.xs) {
        HStack(alignment: .top, spacing: Spacing.lg) {
          histogram("Weekday", weekdays, axisValues: weekdays.map(\.key)) { key in
            Self.weekdayLetters[Int(key) ?? 0]
          }
          .frame(maxWidth: .infinity)
          histogram("Hour", hours, axisValues: ["0", "6", "12", "18", "23"]) { $0 }
            .frame(maxWidth: .infinity)
            .layoutPriority(1)
        }
        caption(range)
      }
    case .samples(let samples):
      VStack(alignment: .leading, spacing: Spacing.xs) {
        ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
          Text(sample)
            .font(.monoSmall)
            .foregroundColor(.structureCellForeground)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, Spacing.xsm)
            .padding(.vertical, Spacing.xxs)
            .background(Color.controlBackground, in: Capsule())
            .overlay(HairlineBorder(shape: Capsule()))
            .help(sample)
        }
      }
    case .none:
      caption("No values")
    }
  }

  private func caption(_ text: String) -> some View {
    Text(text)
      .font(.smallest)
      .foregroundColor(.foregroundMuted)
      .monospacedDigit()
      .lineLimit(1)
      .truncationMode(.tail)
      .textSelection(.enabled)
  }

  /// Count per bucket, one accent color, the x axis labeled at `axisValues`
  private func histogram(
    _ title: String, _ points: [BucketPoint], axisValues: [String],
    label: @escaping (String) -> String
  ) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xxs) {
      Text(title)
        .font(.smallest)
        .foregroundColor(.foregroundSubtle)
      Chart(points) { point in
        BarMark(x: .value(title, point.key), y: .value("Count", point.count))
          .foregroundStyle(Color.accent)
      }
      .chartXScale(domain: points.map(\.key))
      .chartXAxis {
        AxisMarks(values: axisValues) { value in
          AxisValueLabel {
            if let key = value.as(String.self) {
              Text(label(key))
            }
          }
          .font(.smallest)
          .foregroundStyle(Color.foregroundSubtle)
        }
      }
      .chartYAxis(.hidden)
      .chartLegend(.hidden)
      .frame(height: Layout.histogramHeight)
    }
  }

  // MARK: - Derived data

  private static let weekdayLetters = ["S", "M", "T", "W", "T", "F", "S"]

  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
  }()

  /// Top values for strings, numbers and bools; dates and ObjectId times; else samples
  private static func detail(of field: MongoSchemaAnalyzer.Field) -> Detail {
    if !field.topValues.isEmpty {
      let present = field.presentCount
      let points = field.topValues.enumerated().map { index, share in
        ValuePoint(
          key: "\(index)", label: share.isString ? "\"\(share.value)\"" : share.value,
          fraction: fraction(share.count, of: present),
          percent: percent(share.count, of: present), filterValue: share.filterValue)
      }
      var parts: [String] = []
      if let distinct = field.distinctCount {
        parts.append("\(distinct.formatted()) distinct " + (distinct == 1 ? "value" : "values"))
      }
      if let range = field.numberRange {
        parts.append("min \(number(range.lowerBound)) · max \(number(range.upperBound))")
      }
      return .values(points: points, summary: parts.isEmpty ? nil : parts.joined(separator: " · "))
    }
    if let range = field.dateRange {
      let weekdays = (field.weekdays ?? Array(repeating: 0, count: 7)).enumerated().map {
        BucketPoint(key: "\($0.offset)", count: $0.element)
      }
      let hours = (field.hours ?? Array(repeating: 0, count: 24)).enumerated().map {
        BucketPoint(key: "\($0.offset)", count: $0.element)
      }
      let first = dateFormatter.string(from: range.lowerBound)
      let last = dateFormatter.string(from: range.upperBound)
      return .dates(weekdays: weekdays, hours: hours, range: "first: \(first) · last: \(last)")
    }
    if !field.samples.isEmpty {
      return .samples(field.samples)
    }
    return .none
  }

  private static func fraction(_ count: Int, of total: Int) -> Double {
    total > 0 ? Double(count) / Double(total) : 0
  }

  /// Whole percent; "<1%" for a share that rounds to zero
  private static func percent(_ count: Int, of total: Int) -> String {
    let value = fraction(count, of: total) * 100
    if value > 0 && value < 0.5 { return "<1%" }
    return "\(Int(value.rounded()))%"
  }

  /// Whole numbers without decimals, else four significant digits
  private static func number(_ value: Double) -> String {
    if value == value.rounded(), abs(value) < 1e15 {
      return String(format: "%.0f", value)
    }
    return String(format: "%.4g", value)
  }

  /// The result grid's type tones; a missing field in a muted neutral
  private static func color(ofType name: String) -> Color {
    switch name {
    case MongoSchemaAnalyzer.undefinedTypeName: Color.foregroundSubtle.opacity(0.35)
    case "string": .gridString
    case "int", "long", "double", "decimal": .gridNumber
    case "date", "timestamp": .gridDate
    case "objectId": .accent
    case "bool": .gridBoolean
    case "object", "array": .gridJSON
    case "null": .foregroundSubtle
    default: .foregroundMuted
    }
  }
}

// MARK: - Type share button

/// One type of the legend; a click filters on it. Hover shows a pill behind it.
private struct TypeShareButton: View {
  let segment: MongoSchemaFieldRow.TypeSegment
  let action: () -> Void

  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovering = false

  var body: some View {
    if isEnabled {
      button.linkPointer()
    } else {
      button
    }
  }

  private var button: some View {
    Button(action: action) {
      HStack(spacing: Spacing.xs) {
        Circle()
          .fill(segment.color)
          .frame(width: 6, height: 6)
        Text(segment.name)
          .foregroundColor(.foregroundMuted)
        Text(segment.percent)
          .foregroundColor(.foregroundSubtle)
          .monospacedDigit()
      }
      .font(.smallest)
      .lineLimit(1)
      .fixedSize()
      .opacity(isEnabled ? 1 : 0.5)
      // The pill reaches past the label; the negative padding keeps the legend aligned
      .padding(.horizontal, Spacing.xs)
      .padding(.vertical, Spacing.xxs)
      .background(
        isHovering && isEnabled ? Color.cellBackgroundHover : Color.clear,
        in: RoundedRectangle(cornerRadius: CornerRadius.md)
      )
      .contentShape(RoundedRectangle(cornerRadius: CornerRadius.md))
      .padding(.horizontal, -Spacing.xs)
      .padding(.vertical, -Spacing.xxs)
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .help(help)
  }

  private var help: String {
    segment.name == MongoSchemaAnalyzer.undefinedTypeName
      ? "Filter on documents without this field"
      : "Filter on documents where this field is \(segment.name)"
  }
}

// MARK: - Top values chart

/// Share of the present values per top value, one accent color, a percent axis. Hovering a bar
/// shows its value and share; a click hands its value to `onSelect` (nil: bars do nothing).
/// A value cut too long to filter by is dimmed.
private struct ValueChart: View {
  let points: [MongoSchemaFieldRow.ValuePoint]
  let showsLabels: Bool
  let onSelect: ((MongoValue) -> Void)?

  @State private var selectedKey: String?

  var body: some View {
    Chart(points) { point in
      BarMark(x: .value("Value", point.key), y: .value("Share", point.fraction))
        .foregroundStyle(Color.accent.opacity(opacity(of: point)))
    }
    .chartXScale(domain: points.map(\.key))
    // Hover and click read the bar under the pointer
    .chartOverlay { proxy in
      GeometryReader { geometry in
        let origin = proxy.plotFrame.map { geometry[$0].origin } ?? .zero
        hitArea
          .onContinuousHover { phase in
            switch phase {
            case .active(let location):
              selectedKey = proxy.value(atX: location.x - origin.x, as: String.self)
            case .ended:
              selectedKey = nil
            }
          }
          .onTapGesture { location in
            guard let onSelect,
              let key = proxy.value(atX: location.x - origin.x, as: String.self),
              let value = points.first(where: { $0.key == key })?.filterValue
            else { return }
            onSelect(value)
          }
      }
    }
    .chartXAxis {
      if showsLabels {
        AxisMarks { value in
          AxisValueLabel {
            if let key = value.as(String.self) {
              Text(label(of: key))
                .lineLimit(1)
                .truncationMode(.tail)
            }
          }
          .font(.smallest)
          .foregroundStyle(Color.foregroundSubtle)
        }
      }
    }
    .chartYAxis {
      AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
        AxisGridLine()
          .foregroundStyle(Color.border)
        AxisValueLabel(
          format: FloatingPointFormatStyle<Double>.Percent().precision(.fractionLength(0))
        )
        .font(.smallest)
        .foregroundStyle(Color.foregroundSubtle)
      }
    }
    .chartLegend(.hidden)
    .overlay(alignment: .topTrailing) {
      if let point = selectedPoint {
        VStack(alignment: .trailing, spacing: Spacing.xxs) {
          Text("\(point.label)  \(point.percent)")
            .font(.monoSmall)
            .foregroundStyle(Color.foreground)
            .lineLimit(1)
            .truncationMode(.middle)
          if onSelect != nil, point.filterValue == nil {
            Text("Value was cut; too long to filter by")
              .font(.smallest)
              .foregroundStyle(Color.foregroundMuted)
              .lineLimit(1)
          }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xxs)
        .background(Color.cardBackground.opacity(0.92))
        .allowsHitTesting(false)
      }
    }
  }

  /// Clear; the pointing hand when a click filters
  @ViewBuilder
  private var hitArea: some View {
    let area = Rectangle().fill(Color.clear).contentShape(Rectangle())
    if onSelect != nil {
      area.linkPointer()
    } else {
      area
    }
  }

  /// The hovered bar (or every bar, when none is) in full; a value too long to filter by at half
  private func opacity(of point: MongoSchemaFieldRow.ValuePoint) -> Double {
    let emphasis = selectedKey == nil || selectedKey == point.key ? 1.0 : 0.5
    return onSelect != nil && point.filterValue == nil ? emphasis * 0.5 : emphasis
  }

  private var selectedPoint: MongoSchemaFieldRow.ValuePoint? {
    guard let selectedKey else { return nil }
    return points.first { $0.key == selectedKey }
  }

  private func label(of key: String) -> String {
    points.first { $0.key == key }?.label ?? key
  }
}
