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
    VStack(alignment: .leading, spacing: Spacing.xs) {
      HStack(spacing: Spacing.xs) {
        Text(row.name)
          .font(.small)
          .foregroundColor(.foreground)
          .lineLimit(1)
        if row.isUnused {
          Text("Unused")
            .font(.caption)
            .foregroundColor(.foregroundMuted)
            .fixedSize()
        }
        Spacer(minLength: Spacing.xs)
        Toggle("NULL", isOn: nullBinding(for: row.name))
          .font(.small)
          .foregroundColor(.foreground)
          .controlSize(.small)
          .fixedSize()
        if row.isUnused {
          Button(action: { viewModel.removeUnusedParameter(named: row.name) }) {
            Image(systemName: "trash")
          }
          .buttonStyle(GhostButtonStyle(iconOnly: true))
          .help("Remove parameter")
        }
      }

      TextField("", text: textBinding(for: row.name))
        .textFieldStyle(.plain)
        .inputCapsuleStyle()
        .disabled(isStoredNull(row.name))
    }
  }

  private func storedParameter(named name: String) -> QueryParameter? {
    viewModel.editorParameters.first { $0.name == name }
  }

  private func isStoredNull(_ name: String) -> Bool {
    guard let parameter = storedParameter(named: name) else { return false }
    return parameter.value == nil
  }

  private func textBinding(for name: String) -> Binding<String> {
    Binding(
      get: { storedParameter(named: name)?.value ?? "" },
      set: { newValue in
        // Missing until the user types. A disabled NULL field must not write the name back.
        guard let stored = storedParameter(named: name) else {
          guard !newValue.isEmpty else { return }
          store(newValue, for: name)
          return
        }
        guard stored.value != nil else { return }
        store(newValue, for: name)
      }
    )
  }

  private func nullBinding(for name: String) -> Binding<Bool> {
    Binding(
      get: { isStoredNull(name) },
      set: { isNull in
        // Off on a name that was never stored is not a user edit.
        if storedParameter(named: name) == nil && !isNull { return }
        store(isNull ? nil : "", for: name)
      }
    )
  }

  /// Replaces the stored value. A `.script` tab does not mark the file dirty.
  private func store(_ value: String?, for name: String) {
    viewModel.updateParameter(value, for: name)
  }
}

/// One sidebar row. Detected names come first; a stored name that SQL no longer uses is unused.
private struct ParameterFormRow: Identifiable {
  let name: String
  let isUnused: Bool

  var id: String { name }
}
