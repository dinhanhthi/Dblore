// StructureConstraintsSection.swift
// Constraints of the structure editor: primary key, unique, foreign key and check with their
// details, drop / undo per row, and a form that adds a unique, check or foreign key constraint.
// SQLite changes no constraint (the table would have to be rebuilt): the list is read-only.

import SwiftUI

struct StructureConstraintsSection: View {
  let model: StructureEditorModel
  let databaseType: DatabaseType

  private enum NewKind: String, CaseIterable, Identifiable {
    case unique = "Unique"
    case check = "Check"
    case foreignKey = "Foreign Key"
    var id: String { rawValue }
  }

  @State private var newKind = NewKind.unique
  @State private var newName = ""
  @State private var newColumns: [String] = []
  @State private var newCheck = ""
  @State private var targetSchema = ""
  @State private var targetTable = ""
  @State private var targetColumns = ""
  @State private var onUpdate = ForeignKeyAction.noAction
  @State private var onDelete = ForeignKeyAction.noAction

  private var isEditable: Bool { !model.isReadOnly && databaseType != .sqlite }

  fileprivate enum Width {
    static let marker: CGFloat = 8
    static let kind: CGFloat = 90
    static let name: CGFloat = 200
    static let action: CGFloat = 28
  }

  var body: some View {
    SettingsGroupCard(title: "Constraints", background: .cardBackground, contentPadding: 0) {
      Text("\(model.workingConstraints.count)")
        .font(.small)
        .foregroundColor(.foregroundSubtle)
    } content: {
      VStack(alignment: .leading, spacing: 0) {
        if model.workingConstraints.isEmpty {
          Text("No constraints")
            .font(.small)
            .foregroundColor(.foregroundMuted)
            .structureTableRow(isFirst: true)
        } else {
          header
        }
        ForEach(Array(model.workingConstraints.enumerated()), id: \.offset) { position, item in
          StructureConstraintRow(model: model, item: item, isEditable: isEditable)
            .structureTableRow(isFirst: position == 0)
        }
        if isEditable {
          addForm.structureTableFooter()
        }
      }
    }
  }

  private var header: some View {
    HStack(spacing: Spacing.sm) {
      Color.clear.frame(width: Width.marker, height: 0)
      Text("Kind").frame(width: Width.kind, alignment: .leading)
      Text("Name").frame(width: Width.name, alignment: .leading).structureColumnDivider()
      Text("Details").frame(maxWidth: .infinity, alignment: .leading).structureColumnDivider()
      Color.clear.frame(width: Width.action, height: 0)
    }
    .structureTableHeader()
  }

  private var addForm: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack(spacing: Spacing.sm) {
        kindMenu
        TextField("Name (optional)", text: $newName)
          .textFieldStyle(.plain)
          .font(.structureField)
          .structureInputStyle()
          .frame(width: 200)
        if newKind == .check {
          TextField("Check expression, e.g. price > 0", text: $newCheck)
            .textFieldStyle(.plain)
            .font(.structureField)
            .structureInputStyle()
        } else {
          Spacer()
        }
        Button("Add Constraint", action: addConstraint)
          .buttonStyle(FilledSecondaryButtonStyle())
          .disabled(!canAdd)
      }
      if newKind != .check {
        StructureColumnPicker(
          options: StructureColumnPicker.options(model.workingColumns), selection: $newColumns)
      }
      if newKind == .foreignKey {
        HStack(spacing: Spacing.sm) {
          Text("References")
            .font(.small)
            .foregroundColor(.foregroundSubtle)
          textField("Schema", text: $targetSchema, width: 120)
          textField("Table", text: $targetTable, width: 160)
          textField("Columns, comma separated", text: $targetColumns, width: nil)
        }
        HStack(spacing: Spacing.sm) {
          actionPicker("On update", selection: $onUpdate)
          actionPicker("On delete", selection: $onDelete)
          Spacer()
        }
      }
    }
    .onAppear {
      if targetSchema.isEmpty { targetSchema = model.structure?.schema ?? model.schema }
    }
  }

  /// Capsule menu as tall as the input capsules beside it (a menu `Picker` draws its own
  /// AppKit control)
  private var kindMenu: some View {
    Menu {
      ForEach(NewKind.allCases) { kind in
        Button {
          newKind = kind
        } label: {
          if kind == newKind {
            Label(kind.rawValue, systemImage: "checkmark")
          } else {
            Text(kind.rawValue)
          }
        }
      }
    } label: {
      HStack(spacing: Spacing.xs) {
        Text(newKind.rawValue)
          .lineLimit(1)
        Spacer(minLength: Spacing.xs)
        Image(systemName: "chevron.down")
          .font(.system(size: 9, weight: .semibold))
          .foregroundColor(.foregroundMuted)
      }
      .font(.small)
      .foregroundColor(.structureCellForeground)
      .structureInputStyle()
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .linkPointer()
    .frame(width: 130)
    .accessibilityLabel("Kind")
  }

  private func textField(_ title: String, text: Binding<String>, width: CGFloat?) -> some View {
    TextField(title, text: text)
      .textFieldStyle(.plain)
      .font(.structureField)
      .structureInputStyle()
      .frame(width: width)
  }

  private func actionPicker(_ title: String, selection: Binding<ForeignKeyAction>) -> some View {
    HStack(spacing: Spacing.xs) {
      Text(title)
        .font(.small)
        .foregroundColor(.foregroundSubtle)
      Picker(title, selection: selection) {
        ForEach(ForeignKeyAction.allCases, id: \.self) { Text($0.displayName).tag($0) }
      }
      .labelsHidden()
      .frame(width: 130)
    }
  }

  private var referencedColumns: [String] {
    targetColumns.split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  private var canAdd: Bool {
    switch newKind {
    case .unique: !newColumns.isEmpty
    case .check: !newCheck.trimmingCharacters(in: .whitespaces).isEmpty
    case .foreignKey:
      !newColumns.isEmpty && !targetTable.trimmingCharacters(in: .whitespaces).isEmpty
        && referencedColumns.count == newColumns.count
    }
  }

  private func addConstraint() {
    let name = newName.trimmingCharacters(in: .whitespaces)
    let kind: TableStructure.Constraint.Kind
    switch newKind {
    case .unique:
      kind = .unique
    case .check:
      kind = .check(newCheck.trimmingCharacters(in: .whitespaces))
    case .foreignKey:
      kind = .foreignKey(
        TableStructure.ForeignKeyReference(
          schema: targetSchema.trimmingCharacters(in: .whitespaces),
          table: targetTable.trimmingCharacters(in: .whitespaces),
          columns: referencedColumns, onUpdate: onUpdate, onDelete: onDelete))
    }
    model.addConstraint(
      TableStructure.Constraint(
        name: name.isEmpty ? nil : name, kind: kind,
        columns: newKind == .check ? [] : newColumns))
    newName = ""
    newColumns = []
    newCheck = ""
    targetTable = ""
    targetColumns = ""
    onUpdate = .noAction
    onDelete = .noAction
  }
}

private struct StructureConstraintRow: View {
  let model: StructureEditorModel
  let item: StructureEditorModel.WorkingConstraint
  let isEditable: Bool

  private typealias Width = StructureConstraintsSection.Width

  private var constraint: TableStructure.Constraint { item.constraint }

  var body: some View {
    HStack(spacing: Spacing.sm) {
      StructureStateMarker(state: item.state)
        .frame(width: Width.marker)
      Text(kindLabel)
        .font(.small)
        .foregroundColor(.structureCellMuted)
        .frame(width: Width.kind, alignment: .leading)
      Text(constraint.name ?? "(unnamed)")
        .font(.structureField)
        .foregroundColor(constraint.name == nil ? .foregroundSubtle : .structureCellForeground)
        .strikethrough(item.state == .dropped)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(constraint.name ?? "")
        .frame(width: Width.name, alignment: .leading)
      Text(details)
        .font(.structureField)
        .foregroundColor(.structureCellMuted)
        .lineLimit(2)
        .help(details)
        .frame(maxWidth: .infinity, alignment: .leading)
      // A ZStack keeps the column when there is no button (unnamed, SQLite, read-only)
      ZStack { actionButton }
        .frame(width: Width.action)
    }
    .opacity(item.state == .dropped ? 0.6 : 1)
  }

  private var kindLabel: String {
    switch constraint.kind {
    case .primaryKey: "PRIMARY KEY"
    case .unique: "UNIQUE"
    case .foreignKey: "FOREIGN KEY"
    case .check: "CHECK"
    }
  }

  private var details: String {
    let columns = "(\(constraint.columns.joined(separator: ", ")))"
    switch constraint.kind {
    case .primaryKey, .unique:
      return columns
    case .check(let expression):
      return expression
    case .foreignKey(let reference):
      var text =
        "\(columns) → \(reference.schema).\(reference.table)"
        + "(\(reference.columns.joined(separator: ", ")))"
      if reference.onUpdate != .noAction { text += " ON UPDATE \(reference.onUpdate.displayName)" }
      if reference.onDelete != .noAction { text += " ON DELETE \(reference.onDelete.displayName)" }
      return text
    }
  }

  @ViewBuilder
  private var actionButton: some View {
    if isEditable {
      switch item.state {
      case .unchanged:
        if constraint.name != nil {
          StructureRowButton("trash", help: "Drop constraint") {
            model.dropConstraint(constraint)
          }
        }
      case .added:
        StructureRowButton("xmark", help: "Remove added constraint") {
          model.dropConstraint(constraint)
        }
      case .dropped:
        StructureRowButton("arrow.uturn.backward", help: "Keep this constraint") {
          if let position = model.changes.firstIndex(where: {
            if case .dropConstraint(let name, _) = $0 { name == constraint.name } else { false }
          }) {
            model.undoChange(at: position)
          }
        }
      case .edited:
        EmptyView()
      }
    }
  }
}
