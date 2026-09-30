//
//  ChartConfigBar.swift
//  Dblore
//
//  Kind, axes, and PNG export for a result chart.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ResultDisplayMode: Hashable {
  case grid
  case chart
}

/// Segmented Grid / Chart control. Shown only when a result can be charted.
struct ResultDisplayPicker: View {
  @Binding var mode: ResultDisplayMode

  var body: some View {
    Picker("Result", selection: $mode) {
      Text("Grid").tag(ResultDisplayMode.grid)
      Text("Chart").tag(ResultDisplayMode.chart)
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .font(.small)
    .frame(width: 160)
    .accessibilityLabel("Grid or chart")
  }
}

/// Edits a `ChartSpec`: mark, x column, up to five y columns, and an optional series.
struct ChartConfigBar: View {
  let columns: [ColumnInfo]
  @Binding var spec: ChartSpec
  let onExport: () -> Void

  private static let maxYColumns = 5

  private enum ColumnChoice: Hashable {
    case none
    case column(String)
  }

  var body: some View {
    HStack(spacing: Spacing.sm) {
      labeled("Kind") {
        Picker("Kind", selection: $spec.kind) {
          Text("Bar").tag(ChartKind.bar)
          Text("Line").tag(ChartKind.line)
          Text("Area").tag(ChartKind.area)
          Text("Point").tag(ChartKind.point)
        }
        .pickerStyle(.menu)
        .fixedSize()
      }
      labeled("X") {
        Picker("X", selection: xChoice) {
          Text("Row").tag(ColumnChoice.none)
          ForEach(xNames, id: \.self) { name in
            Text(name)
              .font(.monoSmall)
              .tag(ColumnChoice.column(name))
          }
        }
        .pickerStyle(.menu)
        .fixedSize()
      }
      labeled("Y") {
        Menu {
          ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
            yToggle(column.name)
          }
        } label: {
          Text(ySummary)
            .font(.monoSmall)
            .foregroundStyle(Color.foreground)
            .lineLimit(1)
        }
        .fixedSize()
        .help("Y columns, up to \(Self.maxYColumns)")
      }
      labeled("Series") {
        Picker("Series", selection: seriesChoice) {
          Text("None").tag(ColumnChoice.none)
          ForEach(seriesNames, id: \.self) { name in
            Text(name)
              .font(.monoSmall)
              .tag(ColumnChoice.column(name))
          }
        }
        .pickerStyle(.menu)
        .fixedSize()
      }
      Spacer(minLength: Spacing.sm)
      Button(action: onExport) {
        Image(systemName: "square.and.arrow.up")
          .font(.small)
          .foregroundStyle(Color.foreground)
      }
      .buttonStyle(.plain)
      .help("Export chart as PNG")
    }
    .font(.small)
    .foregroundStyle(Color.foreground)
  }

  private func labeled<Content: View>(
    _ title: String, @ViewBuilder content: () -> Content
  ) -> some View {
    HStack(spacing: Spacing.xs) {
      Text(title)
        .font(.small)
        .foregroundStyle(Color.foreground)
      content()
    }
  }

  private var xChoice: Binding<ColumnChoice> {
    Binding(
      get: {
        if let name = spec.xColumn { return .column(name) }
        return .none
      },
      set: { choice in
        switch choice {
        case .none:
          spec.xColumn = nil
        case .column(let name):
          spec.xColumn = name
        }
      }
    )
  }

  private var seriesChoice: Binding<ColumnChoice> {
    Binding(
      get: {
        if let name = spec.seriesColumn { return .column(name) }
        return .none
      },
      set: { choice in
        switch choice {
        case .none:
          spec.seriesColumn = nil
        case .column(let name):
          spec.seriesColumn = name
        }
      }
    )
  }

  private var xNames: [String] {
    names(including: spec.xColumn)
  }

  private var seriesNames: [String] {
    names(including: spec.seriesColumn)
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
    Button {
      toggleY(name)
    } label: {
      if on {
        Label(name, systemImage: "checkmark")
      } else {
        Text(name)
      }
    }
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
  @MainActor
  static func export(result: CellResult, spec: ChartSpec) {
    let content = ResultChartView(result: result, spec: spec)
      .frame(width: 960, height: 540)
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
