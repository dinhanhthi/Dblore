// SchemaDiagramEditPromptSheet.swift
// The small sheet of the diagram's Rename Table…, Rename Column… and Add Column… items: a
// name, and for a new column its type and whether it takes NULL. Submitting closes the sheet at
// once and stages the change; the table's structure is read meanwhile (the canvas marks it).

import SwiftUI

/// What a diagram edit asks for, and about which table (loaded names)
enum SchemaDiagramEditPrompt: Identifiable {
  case renameTable(SchemaDiagramEditModel.TableKey)
  case renameColumn(SchemaDiagramEditModel.TableKey, column: String)
  case addColumn(SchemaDiagramEditModel.TableKey)

  var id: String {
    switch self {
    case .renameTable(let table): "rename-table \(table.qualifiedName)"
    case .renameColumn(let table, let column): "rename-column \(table.qualifiedName) \(column)"
    case .addColumn(let table): "add-column \(table.qualifiedName)"
    }
  }

  var table: SchemaDiagramEditModel.TableKey {
    switch self {
    case .renameTable(let table), .renameColumn(let table, _), .addColumn(let table): table
    }
  }
}

struct SchemaDiagramEditPromptSheet: View {
  let prompt: SchemaDiagramEditPrompt
  /// Gets the trimmed name, and for a new column its type and whether it takes NULL
  let onSubmit: (_ name: String, _ type: String, _ isNullable: Bool) -> Void
  let onClose: () -> Void

  @State private var name: String
  @State private var type = ""
  @State private var isNullable = true
  @FocusState private var isNameFocused: Bool

  init(
    prompt: SchemaDiagramEditPrompt,
    onSubmit: @escaping (_ name: String, _ type: String, _ isNullable: Bool) -> Void,
    onClose: @escaping () -> Void
  ) {
    self.prompt = prompt
    self.onSubmit = onSubmit
    self.onClose = onClose
    switch prompt {
    case .renameTable(let table): _name = State(initialValue: table.table)
    case .renameColumn(_, let column): _name = State(initialValue: column)
    case .addColumn: _name = State(initialValue: "")
    }
  }

  private var title: String {
    switch prompt {
    case .renameTable: "Rename Table"
    case .renameColumn: "Rename Column"
    case .addColumn: "Add Column"
    }
  }

  private var isAddColumn: Bool {
    if case .addColumn = prompt { return true }
    return false
  }

  private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var trimmedType: String { type.trimmingCharacters(in: .whitespacesAndNewlines) }

  private var canSubmit: Bool {
    guard !trimmedName.isEmpty else { return false }
    switch prompt {
    case .renameTable(let table): return trimmedName != table.table
    case .renameColumn(_, let column): return trimmedName != column
    case .addColumn: return !trimmedType.isEmpty
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      GenericModalHeader(
        title: title, titleIcon: "tablecells", titleIconColor: .accent,
        titleBadge: prompt.table.qualifiedName, onClose: onClose)
      VStack(alignment: .leading, spacing: Spacing.md) {
        field(isAddColumn ? "Column name" : "New name", text: $name)
          .focused($isNameFocused)
        if isAddColumn {
          field("Type", text: $type, placeholder: "varchar(255)")
          Toggle("Nullable", isOn: $isNullable)
            .toggleStyle(.checkbox)
            .font(.small)
        }
      }
      .padding(Spacing.md)
      .frame(maxWidth: .infinity, alignment: .leading)
      GenericModalFooter {
        Spacer()
        Button("Cancel", action: onClose)
          .buttonStyle(FilledSecondaryButtonStyle())
          .keyboardShortcut(.cancelAction)
        Button(isAddColumn ? "Add" : "Rename", action: submit)
          .buttonStyle(PrimaryButtonStyle())
          .disabled(!canSubmit)
      }
    }
    .frame(width: 380)
    .background(Color.cardBackground)
    .onAppear {
      // Deferred: focus set during the first layout pass of a sheet is dropped
      DispatchQueue.main.async { isNameFocused = true }
    }
  }

  private func field(
    _ label: String, text: Binding<String>, placeholder: String? = nil
  ) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(label)
        .font(.small)
        .foregroundColor(.foregroundMuted)
      TextField(placeholder ?? label, text: text)
        .textFieldStyle(.plain)
        .font(.structureField)
        .autocorrectionDisabled()
        .inputCapsuleStyle()
        .onSubmit(submit)
    }
  }

  private func submit() {
    guard canSubmit else { return }
    onSubmit(trimmedName, trimmedType, isNullable)
  }
}
