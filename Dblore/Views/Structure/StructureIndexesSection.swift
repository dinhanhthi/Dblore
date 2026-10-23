// StructureIndexesSection.swift
// Indexes of the structure editor: name, key columns, unique, method and partial predicate, with
// drop / undo per row and a form that creates one on the working columns.

import SwiftUI

struct StructureIndexesSection: View {
  let model: StructureEditorModel
  let databaseType: DatabaseType

  @State private var newName = ""
  @State private var newColumns: [String] = []
  @State private var newUnique = false
  @State private var newMethod = ""

  fileprivate enum Width {
    static let marker: CGFloat = 8
    static let name: CGFloat = 200
    static let details: CGFloat = 240
    static let action: CGFloat = 28
  }

  var body: some View {
    SettingsGroupCard(title: "Indexes", background: .cardBackground, contentPadding: 0) {
      Text("\(model.workingIndexes.count)")
        .font(.small)
        .foregroundColor(.foregroundSubtle)
    } content: {
      VStack(alignment: .leading, spacing: 0) {
        if model.workingIndexes.isEmpty {
          Text("No indexes")
            .font(.small)
            .foregroundColor(.foregroundMuted)
            .structureTableRow(isFirst: true)
        } else {
          header
        }
        ForEach(Array(model.workingIndexes.enumerated()), id: \.element.id) { position, item in
          StructureIndexRow(model: model, item: item, isReadOnly: model.isReadOnly)
            .structureTableRow(isFirst: position == 0)
        }
        if !model.isReadOnly {
          addForm.structureTableFooter()
        }
      }
    }
  }

  private var header: some View {
    HStack(spacing: Spacing.sm) {
      Color.clear.frame(width: Width.marker, height: 0)
      Text("Name").frame(width: Width.name, alignment: .leading)
      Text("Columns").frame(maxWidth: .infinity, alignment: .leading).structureColumnDivider()
      Text("Details").frame(width: Width.details, alignment: .leading).structureColumnDivider()
      Color.clear.frame(width: Width.action, height: 0)
    }
    .structureTableHeader()
  }

  private var addForm: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack(spacing: Spacing.sm) {
        TextField("New index name", text: $newName)
          .textFieldStyle(.plain)
          .font(.structureField)
          .structureInputStyle()
          .frame(width: 220)
        Toggle("Unique", isOn: $newUnique)
          .toggleStyle(.checkbox)
          .font(.small)
        if databaseType != .sqlite {
          TextField("Method (optional)", text: $newMethod)
            .textFieldStyle(.plain)
            .font(.structureField)
            .structureInputStyle()
            .frame(width: 150)
        }
        Spacer()
        Button("Add Index", action: addIndex)
          .buttonStyle(FilledSecondaryButtonStyle())
          .disabled(
            newName.trimmingCharacters(in: .whitespaces).isEmpty || newColumns.isEmpty)
      }
      StructureColumnPicker(
        options: StructureColumnPicker.options(model.workingColumns), selection: $newColumns)
    }
  }

  private func addIndex() {
    let method = newMethod.trimmingCharacters(in: .whitespaces)
    model.addIndex(
      StructureChange.NewIndex(
        name: newName.trimmingCharacters(in: .whitespaces), columns: newColumns,
        isUnique: newUnique, method: method.isEmpty ? nil : method))
    newName = ""
    newColumns = []
    newUnique = false
    newMethod = ""
  }
}

private struct StructureIndexRow: View {
  let model: StructureEditorModel
  let item: StructureEditorModel.WorkingIndex
  let isReadOnly: Bool

  private typealias Width = StructureIndexesSection.Width

  private var index: TableStructure.Index { item.index }

  var body: some View {
    HStack(spacing: Spacing.sm) {
      StructureStateMarker(state: item.state)
        .frame(width: Width.marker)
      Text(index.name)
        .font(.structureField)
        .foregroundColor(.structureCellForeground)
        .strikethrough(item.state == .dropped)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(index.name)
        .frame(width: Width.name, alignment: .leading)
      Text(keys)
        .font(.structureField)
        .foregroundColor(.structureCellMuted)
        .lineLimit(1)
        .truncationMode(.tail)
        .help(keys)
        .frame(maxWidth: .infinity, alignment: .leading)
      Text(details)
        .font(.small)
        .foregroundColor(.structureCellMuted)
        .lineLimit(2)
        .help(details)
        .frame(width: Width.details, alignment: .leading)
      // A ZStack keeps the column when there is no button (primary key, read-only)
      ZStack { actionButton }
        .frame(width: Width.action)
    }
    .opacity(item.state == .dropped ? 0.6 : 1)
  }

  private var keys: String {
    index.keys.map { key in
      switch key {
      case .column(let name): name
      case .expression(let expression): expression ?? "(expression)"
      }
    }
    .joined(separator: ", ")
  }

  private var details: String {
    var parts: [String] = []
    if index.isPrimary {
      parts.append("primary key")
    } else if index.isUnique {
      parts.append("unique")
    }
    if let method = index.method { parts.append(method) }
    if index.isPartial { parts.append(index.predicate.map { "WHERE \($0)" } ?? "partial") }
    return parts.joined(separator: " · ")
  }

  @ViewBuilder
  private var actionButton: some View {
    if !isReadOnly {
      switch item.state {
      case .unchanged:
        // A primary key's index goes with the constraint
        if !index.isPrimary {
          StructureRowButton("trash", help: "Drop index") { model.dropIndex(named: index.name) }
        }
      case .added:
        StructureRowButton("xmark", help: "Remove added index") {
          model.dropIndex(named: index.name)
        }
      case .dropped:
        StructureRowButton("arrow.uturn.backward", help: "Keep this index") {
          if let position = model.changes.firstIndex(of: .dropIndex(name: index.name)) {
            model.undoChange(at: position)
          }
        }
      case .edited:
        EmptyView()
      }
    }
  }
}

/// Icon button at the end of a structure row (drop, remove, undo)
struct StructureRowButton: View {
  let systemImage: String
  let help: String
  let action: () -> Void

  init(_ systemImage: String, help: String, action: @escaping () -> Void) {
    self.systemImage = systemImage
    self.help = help
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 11))
    }
    .buttonStyle(GhostButtonStyle(iconOnly: true))
    .help(help)
    .accessibilityLabel(help)
  }
}

/// Checkboxes over the working columns; the selection keeps the order the boxes were ticked in
struct StructureColumnPicker: View {
  let options: [String]
  @Binding var selection: [String]

  /// Names a staged index or constraint uses: loaded names (renames run last) and added names,
  /// without dropped columns
  static func options(_ columns: [StructureEditorModel.WorkingColumn]) -> [String] {
    columns.filter { $0.state != .dropped }.map { $0.loadedName ?? $0.column.name }
  }

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: Spacing.md) {
        Text("Columns:")
          .font(.small)
          .foregroundColor(.foregroundSubtle)
        ForEach(options, id: \.self) { name in
          Toggle(
            name,
            isOn: Binding(
              get: { selection.contains(name) },
              set: { isOn in
                if isOn {
                  if !selection.contains(name) { selection.append(name) }
                } else {
                  selection.removeAll { $0 == name }
                }
              })
          )
          .toggleStyle(.checkbox)
          .font(.monoSmall)
        }
      }
    }
    .onChange(of: options) { _, names in
      selection.removeAll { !names.contains($0) }
    }
  }
}
