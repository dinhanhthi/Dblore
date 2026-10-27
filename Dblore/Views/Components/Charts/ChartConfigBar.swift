//
//  ChartConfigBar.swift
//  Dblore
//
//  Kind, axes, split, and PNG export for a result chart.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

nonisolated enum ResultDisplayMode: Hashable, Sendable {
  case grid
  /// MongoDB results only: the document cards.
  case documents
  /// MongoDB data viewer only: the page as Extended JSON text.
  case json
  case chart

  /// The mode a result shows. `stored` was picked for the result of timestamp `stamp`: Chart
  /// belongs to that result (a new one reads as Grid), Documents and JSON stay for later results.
  static func shown(
    stored: ResultDisplayMode, stamp: Date?, resultTimestamp: Date
  ) -> ResultDisplayMode {
    stamp == resultTimestamp || stored == .documents || stored == .json ? stored : .grid
  }

  /// Picker tabs: Documents for MongoDB results, JSON where the caller asks for it, Chart when a
  /// chart can be suggested. A single tab means no picker.
  static func tabs(chartable: Bool, documents: Bool, json: Bool = false) -> [ResultDisplayMode] {
    [.grid] + (documents ? [.documents] : []) + (json ? [.json] : []) + (chartable ? [.chart] : [])
  }

  /// `tabs`, nil when they make no picker. Put it last in an `if` condition list: `chartable`
  /// (`ChartSpec.suggested`) scans the whole result, so only evaluate it when a picker can show.
  static func pickerTabs(chartable: Bool, documents: Bool) -> [ResultDisplayMode]? {
    let tabs = tabs(chartable: chartable, documents: documents)
    return tabs.count > 1 ? tabs : nil
  }
}

/// Grid / Documents / JSON / Chart control. Same capsule as the sidebar, sized to the Explain menu:
/// 11pt label plus `Spacing.xs` vertical padding measures 22pt. Notebook query-bar
/// icon buttons use this height so the slider and those buttons match.
struct ResultDisplayPicker: View {
  @Binding var mode: ResultDisplayMode
  var tabs: [ResultDisplayMode] = [.grid, .chart]
  /// Data viewer footer: the size of the collection section tabs in the header, 26pt tall with
  /// a 12pt label.
  var large = false

  static let height: CGFloat = 22
  private static let largeHeight: CGFloat = 26
  /// Grid / Chart width; a picker with Documents or JSON gives every tab the wider share.
  private static let width: CGFloat = 132
  private static let documentsTabWidth: CGFloat = 76
  private static let largeWidth: CGFloat = 144
  private static let largeDocumentsTabWidth: CGFloat = 84

  var body: some View {
    CapsuleTabPicker(
      selection: $mode,
      tabs: tabs,
      height: large ? Self.largeHeight : Self.height,
      inset: 2,
      verticalInset: 2
    ) { tab in
      let isSelected = mode == tab
      Text(Self.title(tab))
        .font(.system(size: large ? 12 : 11, weight: isSelected ? .semibold : .regular))
        .foregroundColor(isSelected ? .onAccentFill : .foreground)
        .lineLimit(1)
    }
    .frame(
      width: hasMongoTabs
        ? (large ? Self.largeDocumentsTabWidth : Self.documentsTabWidth) * CGFloat(tabs.count)
        : (large ? Self.largeWidth : Self.width)
    )
    .fixedSize()
    .accessibilityLabel(hasMongoTabs ? "Result view" : "Grid or chart")
  }

  private var hasMongoTabs: Bool {
    tabs.contains(.documents) || tabs.contains(.json)
  }

  private static func title(_ mode: ResultDisplayMode) -> String {
    switch mode {
    case .grid: "Grid"
    case .documents: "Documents"
    case .json: "JSON"
    case .chart: "Chart"
    }
  }
}

/// Edits a `ChartSpec`: mark, x column, up to five y columns, an optional series, and an
/// optional split into small charts.
struct ChartConfigBar: View {
  let columns: [ColumnInfo]
  @Binding var spec: ChartSpec
  /// Off while the facets of a split chart load
  var exportEnabled = true
  let onExport: () -> Void

  private static let maxYColumns = 5

  /// Whole controls wrap to the next line when the bar is narrow (side-by-side layout)
  var body: some View {
    HStack(alignment: .top, spacing: Spacing.sm) {
      AIFlowLayout(spacing: Spacing.sm) {
        controls
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Button(action: onExport) {
        Image(systemName: "square.and.arrow.up")
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .controlSize(.small)
      .disabled(!exportEnabled)
      .help("Export chart as PNG")
    }
  }

  @ViewBuilder
  private var controls: some View {
    labeled("Kind") {
      capsuleMenu(kindTitle(spec.kind)) {
        ForEach([ChartKind.bar, .line, .area, .point], id: \.rawValue) { kind in
          menuChoice(kindTitle(kind), selected: spec.kind == kind) {
            spec.kind = kind
          }
        }
      }
    }
    labeled("X") {
      capsuleMenu(spec.xColumn ?? "Row") {
        menuChoice("Row", selected: spec.xColumn == nil) {
          spec.xColumn = nil
        }
        ForEach(xNames, id: \.self) { name in
          menuChoice(name, selected: spec.xColumn == name) {
            spec.xColumn = name
          }
        }
      }
    }
    labeled("Y") {
      capsuleMenu(ySummary, help: "Y columns, up to \(Self.maxYColumns)") {
        ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
          yToggle(column.name)
        }
      }
    }
    labeled("Series") {
      capsuleMenu(spec.seriesColumn ?? "None") {
        menuChoice("None", selected: spec.seriesColumn == nil) {
          spec.seriesColumn = nil
        }
        ForEach(seriesNames, id: \.self) { name in
          menuChoice(name, selected: spec.seriesColumn == name) {
            spec.seriesColumn = name
          }
        }
      }
    }
    labeled("Split by") {
      capsuleMenu(spec.facetColumn ?? "None", help: "One small chart per value, up to 12") {
        menuChoice("None", selected: spec.facetColumn == nil) {
          spec.facetColumn = nil
        }
        ForEach(facetNames, id: \.self) { name in
          menuChoice(name, selected: spec.facetColumn == name) {
            spec.facetColumn = name
          }
        }
      }
    }
  }

  /// Same capsule as the Explain menu, so the menu opens under the button.
  private func capsuleMenu<Content: View>(
    _ title: String, help: String? = nil, @ViewBuilder content: () -> Content
  ) -> some View {
    Menu {
      content()
    } label: {
      HStack(spacing: Spacing.xs) {
        Text(title)
          .font(.system(size: 11))
          .foregroundStyle(Color.foreground)
          .lineLimit(1)
        Image(systemName: "chevron.down")
          .font(.system(size: 9))
          .foregroundStyle(Color.foregroundMuted)
      }
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xs)
      .background(Capsule().fill(Color.inputBackground))
      .overlay(HairlineBorder(shape: Capsule()))
    }
    .buttonStyle(.plain)
    .linkPointer()
    .fixedSize()
    .help(help ?? title)
  }

  private func menuChoice(
    _ title: String, selected: Bool, action: @escaping () -> Void
  )
    -> some View
  {
    // Toggle renders the native menu checkmark on the selected choice
    Toggle(title, isOn: Binding(get: { selected }, set: { _ in action() }))
  }

  private func kindTitle(_ kind: ChartKind) -> String {
    kind.rawValue.prefix(1).uppercased() + kind.rawValue.dropFirst()
  }

  private func labeled<Content: View>(
    _ title: String, @ViewBuilder content: () -> Content
  ) -> some View {
    HStack(spacing: Spacing.xs) {
      Text(title)
        .font(.small)
        .foregroundStyle(Color.foreground)
        .lineLimit(1)
        .fixedSize()
      content()
    }
    .fixedSize()
  }

  private var xNames: [String] {
    names(including: spec.xColumn)
  }

  private var seriesNames: [String] {
    names(including: spec.seriesColumn)
  }

  private var facetNames: [String] {
    names(including: spec.facetColumn)
  }

  private func names(including extra: String?) -> [String] {
    var names = columns.map(\.name)
    if let extra, !names.contains(extra) {
      names.append(extra)
    }
    return names
  }

  private var ySummary: String {
    if spec.yColumns.isEmpty { return "None" }
    if spec.yColumns.count == 1, let name = spec.yColumns.first { return name }
    return "\(spec.yColumns.count) columns"
  }

  @ViewBuilder
  private func yToggle(_ name: String) -> some View {
    let on = spec.yColumns.contains(name)
    Toggle(name, isOn: Binding(get: { on }, set: { _ in toggleY(name) }))
      .disabled(!on && spec.yColumns.count >= Self.maxYColumns)
  }

  private func toggleY(_ name: String) {
    if let index = spec.yColumns.firstIndex(of: name) {
      guard spec.yColumns.count > 1 else { return }
      spec.yColumns.remove(at: index)
      return
    }
    guard spec.yColumns.count < Self.maxYColumns else { return }
    spec.yColumns.append(name)
  }
}

/// Renders the chart to PNG and asks where to save it. The panel is non-blocking.
enum ChartPNGExporter {
  /// `facets` are the loaded facets of a faceted spec; nothing is exported until they load.
  /// The grid is laid out in full and the image is as tall as it needs.
  @MainActor
  static func export(result: CellResult, spec: ChartSpec, facets: ChartFacets? = nil) {
    let faceted = ResultChartView.isFaceted(spec, columns: result.columns)
    guard !faceted || facets != nil else { return }
    let content = ResultChartView(
      result: result, spec: spec, facets: facets, scrollsFacets: false
    )
    .frame(width: 960, height: faceted ? nil : 540)
    .padding(Spacing.lg)
    .background(Color.appBackground)
    let renderer = ImageRenderer(content: content)
    renderer.scale = 2
    guard let image = renderer.nsImage,
      let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
    else {
      presentError("Could not render the chart.")
      return
    }
    save(png)
  }

  private static func save(_ data: Data) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "chart.png"
    panel.allowedContentTypes = [.png]
    panel.canCreateDirectories = true
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      do {
        try data.write(to: url)
      } catch {
        let message = error.localizedDescription
        DispatchQueue.main.async {
          presentError("Could not save file: \(message)")
        }
      }
    }
  }

  @MainActor
  private static func presentError(_ message: String) {
    let alert = NSAlert()
    alert.messageText = "Export Failed"
    alert.informativeText = message
    alert.alertStyle = .critical
    alert.runModal()
  }
}
