// StructureColumnsSection.swift
// Columns of the structure editor: name, type, nullable and default edit in place (staged on
// Return or focus loss), identity / generated / comment / MySQL charset and collation are
// read-only details, and a form adds a column. SQLite only renames and drops loaded columns.

import SwiftUI

struct StructureColumnsSection: View {
  let model: StructureEditorModel
  let databaseType: DatabaseType

  @State private var newName = ""
  @State private var newType = ""
  @State private var newNullable = true
  @State private var newDefault = ""

  fileprivate enum Width {
    static let marker: CGFloat = 8
    static let name: CGFloat = 170
    static let type: CGFloat = 150
    static let nullable: CGFloat = 56
    static let defaultValue: CGFloat = 150
    static let action: CGFloat = 28
  }

  var body: some View {
    SettingsGroupCard(title: "Columns", background: .cardBackground, contentPadding: 0) {
      Text("\(model.workingColumns.count)")
        .font(.small)
        .foregroundColor(.foregroundSubtle)
    } content: {
      VStack(alignment: .leading, spacing: 0) {
        header
        ForEach(Array(model.workingColumns.enumerated()), id: \.element.rowID) { position, row in
          StructureColumnRow(
            model: model, row: row, isReadOnly: model.isReadOnly,
            altersLoadedColumns: databaseType != .sqlite
          )
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
      Text("Type").frame(width: Width.type, alignment: .leading).structureColumnDivider()
      Text("Null").frame(width: Width.nullable, alignment: .leading).structureColumnDivider()
      Text("Default").frame(width: Width.defaultValue, alignment: .leading)
        .structureColumnDivider()
      Text("Details").frame(maxWidth: .infinity, alignment: .leading).structureColumnDivider()
      Color.clear.frame(width: Width.action, height: 0)
    }
    .structureTableHeader()
  }

  private var addForm: some View {
    HStack(spacing: Spacing.sm) {
      Color.clear.frame(width: Width.marker, height: 0)
      TextField("New column", text: $newName)
        .textFieldStyle(.plain)
        .font(.structureField)
        .structureInputStyle()
        .frame(width: Width.name)
      TextField("Type", text: $newType)
        .textFieldStyle(.plain)
        .font(.structureField)
        .structureInputStyle()
        .frame(width: Width.type)
      Toggle("Nullable", isOn: $newNullable)
        .toggleStyle(.checkbox)
        .labelsHidden()
        .help("Nullable")
        .frame(width: Width.nullable, alignment: .leading)
      TextField("Default", text: $newDefault)
        .textFieldStyle(.plain)
        .font(.structureField)
        .structureInputStyle()
        .frame(width: Width.defaultValue)
      Spacer()
      Button("Add Column", action: addColumn)
        .buttonStyle(FilledSecondaryButtonStyle())
        .disabled(newName.trimmed.isEmpty || newType.trimmed.isEmpty)
    }
  }

  private func addColumn() {
    let defaultValue = newDefault.trimmed
    model.addColumn(
      StructureChange.NewColumn(
        name: newName.trimmed, type: newType.trimmed, isNullable: newNullable,
        defaultExpression: defaultValue.isEmpty ? nil : defaultValue))
    newName = ""
    newType = ""
    newNullable = true
    newDefault = ""
  }
}

private struct StructureColumnRow: View {
  let model: StructureEditorModel
  let row: StructureEditorModel.WorkingColumn
  let isReadOnly: Bool
  /// False on SQLite: a loaded column can only be renamed or dropped
  let altersLoadedColumns: Bool

  private typealias Width = StructureColumnsSection.Width

  private var isDropped: Bool { row.state == .dropped }
  private var canEdit: Bool { !isReadOnly && !isDropped }
  private var canAlter: Bool { canEdit && (row.loadedName == nil || altersLoadedColumns) }

  var body: some View {
    HStack(spacing: Spacing.sm) {
      StructureStateMarker(state: row.state)
        .frame(width: Width.marker)
      field(row.column.name, field: .name, editable: canEdit) {
        model.rename(row.id, to: $0)
      }
      .frame(width: Width.name, alignment: .leading)
      field(row.column.dataType, field: .type, editable: canAlter) {
        model.setType($0, for: row.id)
      }
      .frame(width: Width.type, alignment: .leading)
      Toggle(
        "Nullable",
        isOn: Binding(
          get: { row.column.isNullable },
          set: { model.setNullable($0, for: row.id) })
      )
      .toggleStyle(.checkbox)
      .labelsHidden()
      .disabled(!canAlter)
      .help(row.column.isNullable ? "Nullable" : "NOT NULL")
      .frame(width: Width.nullable, alignment: .leading)
      field(row.column.defaultExpression ?? "", field: .defaultValue, editable: canAlter) {
        model.setDefault($0, for: row.id)
      }
      .frame(width: Width.defaultValue, alignment: .leading)
      Text(details)
        .font(.small)
        .foregroundColor(.structureCellMuted)
        .lineLimit(2)
        .help(details)
        .frame(maxWidth: .infinity, alignment: .leading)
      // A ZStack keeps the column when there is no button (read-only)
      ZStack { actionButton }
        .frame(width: Width.action)
    }
    .opacity(isDropped ? 0.6 : 1)
  }

  @ViewBuilder
  private func field(
    _ value: String, field: StructureEditorModel.ColumnField, editable: Bool,
    commit: @escaping (String) -> Void
  ) -> some View {
    let isEdited = row.editedFields.contains(field)
    if editable {
      StructureCommitField(
        value: value, placeholder: field == .defaultValue ? "None" : "",
        isEdited: isEdited, onCommit: commit)
    } else {
      Text(value.isEmpty && field == .defaultValue ? "None" : value)
        .font(.structureField)
        .foregroundColor(
          isEdited ? .warning : (value.isEmpty ? .foregroundSubtle : .structureCellForeground)
        )
        .strikethrough(isDropped)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(value)
    }
  }

  @ViewBuilder
  private var actionButton: some View {
    if !isReadOnly {
      switch row.state {
      case .unchanged:
        StructureRowButton("trash", help: "Drop column") { model.dropColumn(row.id) }
      case .added:
        StructureRowButton("xmark", help: "Remove added column") { model.dropColumn(row.id) }
      case .edited, .dropped:
        StructureRowButton("arrow.uturn.backward", help: "Undo changes to this column") {
          if let name = row.loadedName { model.revertColumn(named: name) }
        }
      }
    }
  }

  /// Identity, generated expression, MySQL extra / charset / collation and the comment
  private var details: String {
    let column = row.column
    var parts: [String] = []
    switch column.identity {
    case .autoIncrement: parts.append("auto increment")
    case .always: parts.append("identity always")
    case .byDefault: parts.append("identity by default")
    case nil: break
    }
    if let generated = column.generated {
      let kind = generated.isStored ? "stored" : "virtual"
      parts.append(generated.expression.map { "generated \(kind): \($0)" } ?? "generated \(kind)")
    }
    if let extra = column.extra, !extra.isEmpty,
      column.identity == nil
        || extra.lowercased() != "auto_increment"
    {
      parts.append(extra)
    }
    if let characterSet = column.characterSet { parts.append(characterSet) }
    if let collation = column.collation { parts.append(collation) }
    if let comment = column.comment, !comment.isEmpty { parts.append("\"\(comment)\"") }
    return parts.joined(separator: " · ")
  }
}

extension String {
  fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
