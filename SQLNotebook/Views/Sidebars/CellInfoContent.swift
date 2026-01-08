//
//  CellInfoContent.swift
//  SQLNotebook
//

import SwiftUI

// MARK: - Cell Info Content

struct CellInfoContent: View {
  let columnName: String
  let columnType: String
  let value: CellValue
  let onSave: ((String) -> Void)?
  let isReadOnly: Bool

  @State private var isCopied = false
  @State private var isEditing = false
  @State private var editedValue: String = ""
  @State private var editedBoolValue: Bool = false
  @State private var originalBoolValue: Bool = false
  @State private var validationError: String?
  @FocusState private var isTextEditorFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Fixed header section
      VStack(alignment: .leading, spacing: Spacing.md) {
        // Column info
        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text("Column")
            .font(.caption)
            .foregroundColor(.foregroundSubtle)

          Text("\(columnName) (\(columnType))")
            .font(.mono)
            .foregroundColor(.foreground)
        }

        Divider()

        // Value type
        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text("Type")
            .font(.caption)
            .foregroundColor(.foregroundSubtle)

          Text(valueTypeName)
            .font(.mono)
            .foregroundColor(.foregroundMuted)
        }

        Divider()

        // Value header with action buttons
        HStack {
          Text("Value")
            .font(.caption)
            .foregroundColor(.foregroundSubtle)

          Spacer()

          if isEditing {
            // Cancel and Save icon buttons (for non-boolean types)
            FloatingPanelButton(
              icon: "xmark",
              helpText: "Cancel",
              useSymbolEffect: false,
              action: cancelEdit
            )

            FloatingPanelButton(
              icon: "checkmark",
              helpText: "Save",
              useSymbolEffect: false,
              action: saveEdit
            )
            .disabled(validationError != nil)
          } else if isBooleanValue {
            // For boolean: only show Save button if value changed (and not in read-only mode)
            if hasBooleanValueChanged && !isReadOnly {
              FloatingPanelButton(
                icon: "checkmark",
                helpText: "Save",
                useSymbolEffect: false,
                action: saveBooleanEdit
              )
            }

            FloatingPanelButton(
              icon: isCopied ? "checkmark" : "doc.on.doc",
              helpText: "Copy Value",
              useSymbolEffect: true,
              action: copyToClipboard
            )
          } else {
            // Edit and Copy buttons (for non-boolean types)
            if !isReadOnly {
              FloatingPanelButton(
                icon: "pencil",
                helpText: "Edit Value",
                useSymbolEffect: false,
                action: startEdit
              )
            }

            FloatingPanelButton(
              icon: isCopied ? "checkmark" : "doc.on.doc",
              helpText: "Copy Value",
              useSymbolEffect: true,
              action: copyToClipboard
            )
          }
        }
      }
      .padding(.bottom, Spacing.md)

      // Scrollable value content - spans remaining vertical space
      if isBooleanValue {
        // Boolean toggle UI - always visible, no edit mode needed
        HStack(spacing: Spacing.sm) {
          Toggle("", isOn: $editedBoolValue)
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(.accent)
            .scaleEffect(0.8)
            .disabled(isReadOnly)
            .onChange(of: editedBoolValue) { _, _ in
              // Trigger UI update when toggle changes
            }

          Text(editedBoolValue ? "true" : "false")
            .font(.mono)
            .foregroundColor(.foreground)
        }
        .padding(Spacing.sm)
        .background(Color.inputBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
      } else if isEditing {
        // Text editor for other types (only in edit mode)
        VStack(alignment: .leading, spacing: Spacing.xs) {
          TextEditor(text: $editedValue)
            .font(.mono)
            .foregroundColor(.foreground)
            .scrollContentBackground(.hidden)
            .padding(.vertical, Spacing.sm)
            .padding(.leading, Spacing.xs)
            .padding(.trailing, 0)
            .background(Color.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
            .overlay(
              RoundedRectangle(cornerRadius: CornerRadius.md)
                .stroke(validationError != nil ? Color.destructive : Color.border, lineWidth: 1)
            )
            .frame(maxHeight: .infinity)
            .focused($isTextEditorFocused)
            .focusedValue(\.isCellValueEditing, isEditing)
            .onChange(of: editedValue) { _, newValue in
              validateInput(newValue)
            }

          // Validation error message
          if let error = validationError {
            HStack(spacing: Spacing.xs) {
              Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundColor(.destructive)

              Text(error)
                .font(.caption)
                .foregroundColor(.destructive)
            }
            .padding(.top, Spacing.sm)
            .padding(.horizontal, Spacing.xs)
          }
        }
      } else {
        // Read-only view for non-boolean types
        ScrollView {
          Text(value.fullString)
            .font(.mono)
            .foregroundColor(value.isNull ? .foregroundSubtle : .foreground)
            .italic(value.isNull)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.sm)
        }
        .background(Color.tableHeaderBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
        .frame(maxHeight: .infinity)
      }
    }
    .onAppear {
      // Initialize boolean values when view appears
      if case .bool(let boolValue) = value {
        editedBoolValue = boolValue
        originalBoolValue = boolValue
      }
    }
    .onChange(of: value) { _, newValue in
      // Update boolean values when value changes
      if case .bool(let boolValue) = newValue {
        editedBoolValue = boolValue
        originalBoolValue = boolValue
      }
    }
  }

  private var valueTypeName: String {
    switch value {
    case .string: return "String"
    case .int: return "Integer"
    case .double: return "Double"
    case .bool: return "Boolean"
    case .null: return "NULL"
    case .json: return "JSON"
    case .date: return "Date"
    case .data: return "Binary Data"
    }
  }

  private var isBooleanValue: Bool {
    if case .bool = value {
      return true
    }
    return false
  }

  private var hasBooleanValueChanged: Bool {
    editedBoolValue != originalBoolValue
  }

  private func startEdit() {
    editedValue = value.fullString
    isEditing = true
    isTextEditorFocused = true
    validationError = nil  // Reset validation error

    // Validate the initial value to catch any issues
    validateInput(editedValue)

    NotificationCenter.default.post(name: .cellValueEditingStarted, object: nil)
  }

  private func saveBooleanEdit() {
    let valueToSave = String(editedBoolValue)
    onSave?(valueToSave)
    // Update original value after save
    originalBoolValue = editedBoolValue
  }

  private func cancelEdit() {
    isEditing = false
    isTextEditorFocused = false
    editedValue = ""
    validationError = nil
    NotificationCenter.default.post(name: .cellValueEditingEnded, object: nil)
  }

  private func saveEdit() {
    // Don't save if validation fails
    guard validationError == nil else { return }

    // For boolean values, convert toggle state to string
    let valueToSave = isBooleanValue ? String(editedBoolValue) : editedValue

    onSave?(valueToSave)
    isEditing = false
    isTextEditorFocused = false
    editedValue = ""
    validationError = nil
    NotificationCenter.default.post(name: .cellValueEditingEnded, object: nil)
  }

  private func copyToClipboard() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value.fullString, forType: .string)

    // Show checkmark feedback
    isCopied = true

    // Reset back to copy icon after 500ms
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      isCopied = false
    }
  }

  // MARK: - Validation

  private func validateInput(_ input: String) {
    // Use CellValueValidator helper
    let result = CellValueValidator.validate(input, for: value)
    validationError = result.errorMessage
  }
}

// MARK: - Previews

#Preview("Boolean Value - True") {
  @Previewable @State var viewModel = NotebookViewModel()
  viewModel.rightSidebarContent = .cellInfo(
    columnName: "is_active",
    columnType: "boolean",
    value: .bool(true),
    tableName: "users",
    rowData: ["user_id": .int(1), "is_active": .bool(true)],
    primaryKeyColumns: ["user_id"],
    rowIdentifier: .int(1),
    cellId: nil
  )

  return HStack {
    Spacer()
    RightSidebarView(viewModel: viewModel)
  }
  .frame(height: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}

#Preview("Boolean Value - False") {
  @Previewable @State var viewModel = NotebookViewModel()
  viewModel.rightSidebarContent = .cellInfo(
    columnName: "is_deleted",
    columnType: "boolean",
    value: .bool(false),
    tableName: "posts",
    rowData: ["post_id": .int(1), "is_deleted": .bool(false)],
    primaryKeyColumns: ["post_id"],
    rowIdentifier: .int(1),
    cellId: nil
  )

  return HStack {
    Spacer()
    RightSidebarView(viewModel: viewModel)
  }
  .frame(height: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}

#Preview("String Value") {
  @Previewable @State var viewModel = NotebookViewModel()
  viewModel.rightSidebarContent = .cellInfo(
    columnName: "email",
    columnType: "varchar(255)",
    value: .string("user@example.com"),
    tableName: "users",
    rowData: ["user_id": .int(1), "email": .string("user@example.com")],
    primaryKeyColumns: ["user_id"],
    rowIdentifier: .int(1),
    cellId: nil
  )

  return HStack {
    Spacer()
    RightSidebarView(viewModel: viewModel)
  }
  .frame(height: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}

#Preview("Integer Value") {
  @Previewable @State var viewModel = NotebookViewModel()
  viewModel.rightSidebarContent = .cellInfo(
    columnName: "user_id",
    columnType: "integer",
    value: .int(42),
    tableName: "users",
    rowData: ["user_id": .int(42), "email": .string("user@example.com")],
    primaryKeyColumns: ["user_id"],
    rowIdentifier: .int(42),
    cellId: nil
  )

  return HStack {
    Spacer()
    RightSidebarView(viewModel: viewModel)
  }
  .frame(height: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}

#Preview("Double Value") {
  @Previewable @State var viewModel = NotebookViewModel()
  viewModel.rightSidebarContent = .cellInfo(
    columnName: "price",
    columnType: "numeric(10,2)",
    value: .double(199.99),
    tableName: "products",
    rowData: ["product_id": .int(1), "price": .double(199.99)],
    primaryKeyColumns: ["product_id"],
    rowIdentifier: .int(1),
    cellId: nil
  )

  return HStack {
    Spacer()
    RightSidebarView(viewModel: viewModel)
  }
  .frame(height: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}

#Preview("NULL Value") {
  @Previewable @State var viewModel = NotebookViewModel()
  viewModel.rightSidebarContent = .cellInfo(
    columnName: "deleted_at",
    columnType: "timestamp",
    value: .null,
    tableName: "users",
    rowData: ["user_id": .int(1), "deleted_at": .null],
    primaryKeyColumns: ["user_id"],
    rowIdentifier: .int(1),
    cellId: nil
  )

  return HStack {
    Spacer()
    RightSidebarView(viewModel: viewModel)
  }
  .frame(height: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}

#Preview("Date Value") {
  @Previewable @State var viewModel = NotebookViewModel()
  let dateFormatter = ISO8601DateFormatter()
  let date = dateFormatter.date(from: "2024-01-15T10:30:00Z") ?? Date()

  viewModel.rightSidebarContent = .cellInfo(
    columnName: "created_at",
    columnType: "timestamp",
    value: .date(date),
    tableName: "posts",
    rowData: ["post_id": .int(1), "created_at": .date(date)],
    primaryKeyColumns: ["post_id"],
    rowIdentifier: .int(1),
    cellId: nil
  )

  return HStack {
    Spacer()
    RightSidebarView(viewModel: viewModel)
  }
  .frame(height: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}

#Preview("Long Text Value") {
  @Previewable @State var viewModel = NotebookViewModel()
  let longText = """
    Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat.

    Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.
    """

  viewModel.rightSidebarContent = .cellInfo(
    columnName: "description",
    columnType: "text",
    value: .string(longText),
    tableName: "articles",
    rowData: ["article_id": .int(1), "description": .string(longText)],
    primaryKeyColumns: ["article_id"],
    rowIdentifier: .int(1),
    cellId: nil
  )

  return HStack {
    Spacer()
    RightSidebarView(viewModel: viewModel)
  }
  .frame(height: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}
