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
          Text("Use :name in SQL to add a parameter.")
            .font(.small)
            .foregroundColor(.foregroundMuted)
        } else {
          ForEach(parameterRows) { row in
            parameterRow(row)
          }
        }

        Text(persistenceNote)
          .font(.small)
          .foregroundColor(.foregroundMuted)
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

  private func parameterRow(_ row: ParameterFormRow) -> some View {
    ParameterInputBlock(
      name: row.name,
      stored: storedParameter(named: row.name),
      // A `.script` tab does not mark the file dirty.
      onStore: { viewModel.updateParameter($0, for: row.name) }
    ) {
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
