// CreateTableSheet.swift
// The Create Table sheet (New Table... on the sidebar's Tables header): target schema (a picker
// when the connection lists 2+), name and comment (PostgreSQL and MySQL), columns with type, NOT
// NULL, default and primary key, unique and foreign key constraints, and the exact SQL Create
// sends (`SQLCodeWell`). The Safe Mode step sits inside the sheet, as in the structure editor.
// A connection that cannot create tables shows why and keeps Create disabled. Created (or
// pending until Commit) closes the sheet; a failure keeps the draft and shows the error.

import SwiftUI

struct CreateTableSheet: View {
  @Bindable var model: CreateTableModel
  /// Tables a foreign key can reference
  let tables: [DatabaseTable]
  /// For the Safe Mode "Forgot Password?" fallback
  let databasePassword: String?
  let isConnected: Bool
  /// False once the sheet was closed or replaced (a late Touch ID answer then sends nothing)
  let isShown: () -> Bool
  let onClose: () -> Void

  private enum Width {
    static let name: CGFloat = 170
    static let type: CGFloat = 150
    static let flag: CGFloat = 64
    static let defaultValue: CGFloat = 170
    static let action: CGFloat = 28
  }

  var body: some View {
    VStack(spacing: 0) {
      GenericModalHeader(
        title: "New Table", titleIcon: "tablecells", titleIconColor: .accent,
        titleBadge: model.databaseType.rawValue, onClose: onClose
      ) {
        EmptyView()
      }
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.lg) {
          banners
          tableSection
          columnsSection
          CreateTableConstraintsSection(model: model, tables: tables)
          previewSection
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(model.isCreating || model.disabledReason != nil)
      }
      .frame(maxHeight: .infinity)
      if let statements = model.pendingConfirmation {
        SafeModeConfirmationPanel(
          requiresPassword: model.confirmationRequiresPassword, confirmTitle: "Create Table",
          biometricReason: "Authorize creating the table in Safe Mode",
          databasePassword: databasePassword, isConnected: isConnected,
          isPending: { [model] in model.pendingConfirmation != nil && isShown() },
          onCancel: { [model] in model.cancelConfirmation() },
          onConfirm: { [model] in await model.confirmCreate() }
        ) {
          SafeModeStatementList(statements: statements)
        }
      }
      footer
    }
    .frame(width: 840, height: 660)
    .background(Color.cardBackground)
    .interactiveDismissDisabled(model.isCreating)
    .onChange(of: model.isFinished) { _, finished in
      if finished { onClose() }
    }
  }

  // MARK: - Sections

  @ViewBuilder
  private var banners: some View {
    if model.isLoading {
      HStack(spacing: Spacing.sm) {
        ProgressView().controlSize(.small)
        Text("Reading the connection...")
          .font(.small)
          .foregroundColor(.foregroundMuted)
      }
    } else if let reason = model.disabledReason {
      StructureBanner(text: reason, systemImage: "lock", color: .warning)
    }
    if let error = model.applyError {
      StructureBanner(text: error, systemImage: "exclamationmark.triangle", color: .destructive)
    }
  }

  private var tableSection: some View {
    SettingsGroupCard(title: "Table") {
      HStack(alignment: .top, spacing: Spacing.md) {
        if model.schemas.count > 1 {
          labeled("Schema") {
            CapsulePickerMenu(title: model.schema, width: 180) {
              Picker("Schema", selection: $model.schema) {
                ForEach(model.schemas, id: \.self) { Text($0).tag($0) }
              }
              .pickerStyle(.inline)
              .labelsHidden()
            }
            .accessibilityLabel("Schema")
          }
        }
        labeled("Name") {
          textField("e.g. orders", text: $model.tableName)
            .frame(width: 240)
        }
        if model.supportsComment {
          labeled("Comment") {
            textField("None", text: $model.comment)
          }
        }
      }
    }
  }

  private var columnsSection: some View {
    SettingsGroupCard(title: "Columns", background: .cardBackground, contentPadding: 0) {
      Text("\(model.columns.count)")
        .font(.small)
        .foregroundColor(.foregroundSubtle)
    } content: {
      VStack(alignment: .leading, spacing: 0) {
        columnsHeader
        ForEach(Array($model.columns.enumerated()), id: \.element.id) { position, $row in
          columnRow($row)
            .structureTableRow(isFirst: position == 0)
        }
        HStack {
          Button("Add Column") { model.addColumn() }
            .buttonStyle(FilledSecondaryButtonStyle())
          Spacer()
        }
        .structureTableFooter()
      }
    }
  }

  private var columnsHeader: some View {
    HStack(spacing: Spacing.sm) {
      Text("Name").frame(width: Width.name, alignment: .leading)
      Text("Type").frame(width: Width.type, alignment: .leading).structureColumnDivider()
      Text("Null").frame(width: Width.flag, alignment: .leading).structureColumnDivider()
      Text("Primary").frame(width: Width.flag, alignment: .leading).structureColumnDivider()
      Text("Default").frame(maxWidth: .infinity, alignment: .leading).structureColumnDivider()
      Color.clear.frame(width: Width.action, height: 0)
    }
    .structureTableHeader()
  }

  private func columnRow(_ row: Binding<CreateTableModel.ColumnRow>) -> some View {
    HStack(spacing: Spacing.sm) {
      textField("Column", text: row.name)
        .frame(width: Width.name)
      textField("Type, e.g. integer", text: row.type)
        .frame(width: Width.type)
      Toggle("Nullable", isOn: row.isNullable)
        .toggleStyle(.checkbox)
        .labelsHidden()
        // A primary key column is always NOT NULL
        .disabled(row.wrappedValue.isPrimaryKey)
        .help(row.wrappedValue.isPrimaryKey ? "Primary key columns are NOT NULL" : "Nullable")
        .frame(width: Width.flag, alignment: .leading)
      Toggle("Primary key", isOn: row.isPrimaryKey)
        .toggleStyle(.checkbox)
        .labelsHidden()
        .help("Part of the primary key")
        .frame(width: Width.flag, alignment: .leading)
      textField("None", text: row.defaultExpression)
        .help("A SQL expression, e.g. 0, 'text' or now()")
      Button {
        model.removeColumn(row.wrappedValue.id)
      } label: {
        Image(systemName: "minus.circle")
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .disabled(model.columns.count == 1)
      .help("Remove the column")
      .frame(width: Width.action)
    }
  }

  private var previewSection: some View {
    SettingsGroupCard(title: "SQL Preview") {
      Text(
        model.runsInPendingTransaction
          ? "Create sends exactly this SQL; it is kept only after Commit"
          : "Create sends exactly this SQL"
      )
      .font(.small)
      .foregroundColor(.foregroundSubtle)
    } content: {
      // A builder error leaves no statements: it takes the placeholder's place in the well
      SQLCodeWell(
        sql: model.previewStatements.map { $0 + ";" }.joined(separator: "\n"),
        placeholder: model.previewError == nil ? "Nothing to create yet" : nil,
        dialect: model.databaseType.dialect
      )
      .overlay(alignment: .topLeading) {
        if let error = model.previewError {
          Label(error, systemImage: "exclamationmark.triangle")
            .font(.small)
            .foregroundColor(.destructive)
            .textSelection(.enabled)
            .padding(Spacing.md)
        }
      }
      .frame(height: 180)
    }
  }

  private var footer: some View {
    GenericModalFooter {
      Spacer()
      Button("Cancel", action: onClose)
        .buttonStyle(FilledSecondaryButtonStyle())
        .disabled(model.isCreating)
        .keyboardShortcut(.cancelAction)
      Button(model.isCreating ? "Creating..." : "Create") {
        Task { await model.create() }
      }
      .buttonStyle(PrimaryButtonStyle())
      .disabled(!model.canCreate || model.pendingConfirmation != nil)
    }
  }

  // MARK: - Pieces

  private func labeled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(title)
        .font(.small)
        .foregroundColor(.foregroundMuted)
      content()
    }
  }

  private func textField(_ placeholder: String, text: Binding<String>) -> some View {
    TextField(placeholder, text: text)
      .textFieldStyle(.plain)
      .font(.structureField)
      .autocorrectionDisabled()
      .structureInputStyle()
  }
}

// MARK: - Constraints

/// The new table's unique and foreign key constraints, and a form that adds one
private struct CreateTableConstraintsSection: View {
  let model: CreateTableModel
  let tables: [DatabaseTable]

  private enum Kind: String, CaseIterable, Identifiable {
    case unique = "Unique"
    case foreignKey = "Foreign Key"
    var id: String { rawValue }
  }

  @State private var kind = Kind.unique
  @State private var name = ""
  @State private var columns: [String] = []
  /// `tables` index of the referenced table
  @State private var target: Int?
  @State private var targetColumns = ""
  @State private var onUpdate = ForeignKeyAction.noAction
  @State private var onDelete = ForeignKeyAction.noAction

  var body: some View {
    SettingsGroupCard(title: "Constraints", background: .cardBackground, contentPadding: 0) {
      Text("\(model.constraints.count)")
        .font(.small)
        .foregroundColor(.foregroundSubtle)
    } content: {
      VStack(alignment: .leading, spacing: 0) {
        if model.constraints.isEmpty {
          Text("No unique or foreign key constraints")
            .font(.small)
            .foregroundColor(.foregroundMuted)
            .structureTableRow(isFirst: true)
        }
        ForEach(Array(model.constraints.enumerated()), id: \.offset) { position, constraint in
          row(constraint, at: position)
            .structureTableRow(isFirst: position == 0)
        }
        addForm.structureTableFooter()
      }
    }
  }

  private func row(_ constraint: TableStructure.Constraint, at position: Int) -> some View {
    HStack(spacing: Spacing.sm) {
      Text(
        (try? StructureDDLBuilder.constraintDefinition(
          constraint, dialect: model.databaseType.dialect, renamed: [:],
          qualifiesReference: model.databaseType.dialect != .sqlite)) ?? ""
      )
      .font(.structureField)
      .foregroundColor(.structureCellForeground)
      .lineLimit(1)
      .truncationMode(.middle)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      Button {
        model.constraints.remove(at: position)
      } label: {
        Image(systemName: "minus.circle")
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .help("Remove the constraint")
    }
  }

  private var addForm: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack(spacing: Spacing.sm) {
        CapsulePickerMenu(title: kind.rawValue, width: 130) {
          Picker("Kind", selection: $kind) {
            ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
          }
          .pickerStyle(.inline)
          .labelsHidden()
        }
        .accessibilityLabel("Kind")
        TextField("Name (optional)", text: $name)
          .textFieldStyle(.plain)
          .font(.structureField)
          .structureInputStyle()
          .frame(width: 200)
        Spacer()
        Button("Add Constraint", action: add)
          .buttonStyle(FilledSecondaryButtonStyle())
          .disabled(!canAdd)
      }
      StructureColumnPicker(options: model.columnNames, selection: $columns)
      if kind == .foreignKey {
        HStack(spacing: Spacing.sm) {
          Text("References")
            .font(.small)
            .foregroundColor(.foregroundSubtle)
          CapsulePickerMenu(
            title: target.flatMap { tables.indices.contains($0) ? tables[$0] : nil }
              .map { "\($0.schema).\($0.name)" } ?? "Choose a table",
            width: 240
          ) {
            Picker("Table", selection: $target) {
              Text("Choose a table").tag(Int?.none)
              ForEach(tables.indices, id: \.self) { index in
                Text("\(tables[index].schema).\(tables[index].name)").tag(Optional(index))
              }
            }
            .pickerStyle(.inline)
            .labelsHidden()
          }
          .accessibilityLabel("Table")
          TextField("Columns, comma separated", text: $targetColumns)
            .textFieldStyle(.plain)
            .font(.structureField)
            .structureInputStyle()
        }
        HStack(spacing: Spacing.sm) {
          actionPicker("On update", selection: $onUpdate)
          actionPicker("On delete", selection: $onDelete)
          Spacer()
        }
      }
    }
  }

  private func actionPicker(_ title: String, selection: Binding<ForeignKeyAction>) -> some View {
    HStack(spacing: Spacing.xs) {
      Text(title)
        .font(.small)
        .foregroundColor(.foregroundSubtle)
      CapsulePickerMenu(title: selection.wrappedValue.displayName, width: 130) {
        Picker(title, selection: selection) {
          ForEach(ForeignKeyAction.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
        .pickerStyle(.inline)
        .labelsHidden()
      }
      .accessibilityLabel(title)
    }
  }

  private var referencedColumns: [String] {
    targetColumns.split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  private var targetTable: DatabaseTable? {
    target.flatMap { tables.indices.contains($0) ? tables[$0] : nil }
  }

  private var canAdd: Bool {
    switch kind {
    case .unique: !columns.isEmpty
    case .foreignKey:
      !columns.isEmpty && targetTable != nil && referencedColumns.count == columns.count
    }
  }

  private func add() {
    let trimmedName = name.trimmingCharacters(in: .whitespaces)
    let constraintKind: TableStructure.Constraint.Kind
    switch kind {
    case .unique:
      constraintKind = .unique
    case .foreignKey:
      guard let table = targetTable else { return }
      constraintKind = .foreignKey(
        TableStructure.ForeignKeyReference(
          schema: table.schema, table: table.name, columns: referencedColumns,
          onUpdate: onUpdate, onDelete: onDelete))
    }
    model.constraints.append(
      TableStructure.Constraint(
        name: trimmedName.isEmpty ? nil : trimmedName, kind: constraintKind, columns: columns))
    name = ""
    columns = []
    target = nil
    targetColumns = ""
    onUpdate = .noAction
    onDelete = .noAction
  }
}
