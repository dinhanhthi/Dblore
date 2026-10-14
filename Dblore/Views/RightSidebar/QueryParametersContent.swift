//
//  QueryParametersContent.swift
//  Dblore
//
//  Named :name values in the right sidebar. A detected name stays out of the document
//  until the user types or toggles NULL. The first stored name wins.
//

import SwiftUI

struct QueryParametersContent: View {
  @Bindable var viewModel: NotebookViewModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.md) {
        if parameterRows.isEmpty {
          emptyNote
            .font(.small)
            .foregroundColor(.foregroundMuted)
        } else {
          ForEach(parameterRows) { row in
            parameterRow(row)
          }

          Text(persistenceNote)
            .font(.small)
            .foregroundColor(.foregroundMuted)
        }
      }
      .padding(Spacing.md)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
  }

  private var parameterRows: [ParameterFormRow] {
    let detected = viewModel.detectedParameterNames()
    var seen = Set(detected)
    var rows = detected.map { ParameterFormRow(name: $0, isUnused: false) }
    for parameter in viewModel.editorParameters where seen.insert(parameter.name).inserted {
      rows.append(ParameterFormRow(name: parameter.name, isUnused: true))
    }
    return rows
  }

  private var persistenceNote: String {
    "Values stay until this tab closes."
  }

  @ViewBuilder
  private var emptyNote: some View {
    let note = Text("Use \(inlineCode(":name")) in SQL to add a parameter. \(persistenceNote)")
    if #available(macOS 15, *) {
      note.textRenderer(InlineCodeRenderer())
    } else {
      note
    }
  }

  /// Mono run with its own fill, like inline code in Markdown. macOS 14 cannot round the fill.
  private func inlineCode(_ code: String) -> Text {
    let padded = "\u{2009}\(code)\u{2009}"
    if #available(macOS 15, *) {
      return Text(padded).font(.monoSmall).customAttribute(InlineCodeAttribute())
    }
    var run = AttributedString(padded)
    run.font = .monoSmall
    run.backgroundColor = .hoverFill
    return Text(run)
  }

  private func parameterRow(_ row: ParameterFormRow) -> some View {
    ParameterInputBlock(
      name: row.name,
      stored: storedParameter(named: row.name),
      // A `.script` tab does not mark the file dirty.
      onStore: { viewModel.updateParameter($0, for: row.name) },
      trailingAccessory: {
        if row.isUnused {
          Text("Unused")
            .font(.caption)
            .foregroundColor(.foregroundMuted)
            .fixedSize()
          Button(action: { viewModel.removeUnusedParameter(named: row.name) }) {
            Image(systemName: "trash")
          }
          .buttonStyle(GhostButtonStyle(iconOnly: true))
          .help("Remove parameter")
        }
      }
    )
  }

  private func storedParameter(named name: String) -> QueryParameter? {
    viewModel.editorParameters.first { $0.name == name }
  }
}

/// One sidebar row. Detected names come first; a stored name that SQL no longer uses is unused.
private struct ParameterFormRow: Identifiable {
  let name: String
  let isUnused: Bool

  var id: String { name }
}

@available(macOS 15, *)
private struct InlineCodeAttribute: TextAttribute {}

/// Draws a rounded fill behind runs tagged with `InlineCodeAttribute`.
@available(macOS 15, *)
private struct InlineCodeRenderer: TextRenderer {
  func draw(layout: Text.Layout, in context: inout GraphicsContext) {
    for line in layout {
      // A tagged span can split into several runs; fill their union once so it has no seams.
      var span: CGRect?
      for run in line {
        if run[InlineCodeAttribute.self] != nil {
          let rect = run.typographicBounds.rect
          span = span?.union(rect) ?? rect
        } else if let rect = span {
          fill(rect, in: &context)
          span = nil
        }
      }
      if let rect = span { fill(rect, in: &context) }
      for run in line { context.draw(run) }
    }
  }

  private func fill(_ rect: CGRect, in context: inout GraphicsContext) {
    context.fill(
      RoundedRectangle(cornerRadius: CornerRadius.sm).path(in: rect.insetBy(dx: 0, dy: -1)),
      with: .color(.hoverFill))
  }
}
