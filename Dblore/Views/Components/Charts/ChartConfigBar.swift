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

/// Grid / Chart control. Same capsule as the sidebar, sized to the Explain menu:
/// 11pt label plus `Spacing.xs` vertical padding measures 22pt. Notebook query-bar
/// icon buttons use this height so the slider and those buttons match.
struct ResultDisplayPicker: View {
  @Binding var mode: ResultDisplayMode

  static let height: CGFloat = 22
  private static let width: CGFloat = 132

  var body: some View {
    CapsuleTabPicker(
      selection: $mode,
      tabs: [ResultDisplayMode.grid, .chart],
      height: Self.height,
      inset: 2,
      verticalInset: 2
    ) { tab in
      let isSelected = mode == tab
      Text(tab == .grid ? "Grid" : "Chart")
        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
        .foregroundColor(isSelected ? .onAccent : .foreground)
        .lineLimit(1)
    }
    .frame(width: Self.width)
    .fixedSize()
    .accessibilityLabel("Grid or chart")
  }
}

/// Edits a `ChartSpec`: mark, x column, up to five y columns, and an optional series.
struct ChartConfigBar: View {
  let columns: [ColumnInfo]
  @Binding var spec: ChartSpec
  let onExport: () -> Void

  private static let maxYColumns = 5

  var body: some View {
    HStack(spacing: Spacing.sm) {
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
      Spacer(minLength: Spacing.sm)
      Button(action: onExport) {
        Image(systemName: "square.and.arrow.up")
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .controlSize(.small)
      .help("Export chart as PNG")
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
      .overlay(Capsule().stroke(Color.border, lineWidth: 1))
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
    Button(action: action) {
      if selected {
        Label(title, systemImage: "checkmark")
      } else {
        Text(title)
      }
    }
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
      content()
    }
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
