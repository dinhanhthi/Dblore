//
//  CellInfoContent.swift
//  Dblore
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
  @State private var isBeautified = false
  @State private var beautifiedJSON: String = ""
  @State private var isWordWrapEnabled = true
  @FocusState private var isTextEditorFocused: Bool

  @Environment(NotebookViewModel.self) private var viewModel

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
            // Word Wrap, Beautify, Edit and Copy buttons (for non-boolean types)

            // Word Wrap button (only for string type)
            if isStringValue {
              FloatingPanelToggleButton(
                icon: "text.alignleft",
                helpText: "Word Wrap",
                isActive: isWordWrapEnabled,
                action: { isWordWrapEnabled.toggle() }
              )
            }

            // Beautify button (only for string type)
            if isStringValue {
              FloatingPanelToggleButton(
                icon: "curlybraces",
                helpText: isBeautified ? "Show Original" : "Beautify JSON",
                isActive: isBeautified,
                action: isBeautified ? showOriginal : { beautifyJSON() }
              )
            }

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
        }.padding(.leading, -5)
      } else if isEditing {
        // Text editor for other types (only in edit mode)
        VStack(alignment: .leading, spacing: Spacing.xs) {
          PlainTextEditor(text: $editedValue)
            .background(Color.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
            .overlay(
              RoundedRectangle(cornerRadius: CornerRadius.md)
                .stroke(validationError != nil ? Color.destructive : Color.border, lineWidth: 1)
            )
            .frame(maxHeight: .infinity)
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
        if isBeautified {
          // Nested ScrollViews for both axes to avoid centering issue
          // Horizontal outside so scrollbar is always visible at bottom
          if isWordWrapEnabled {
            // With word wrap: only vertical scroll
            ScrollView(.vertical, showsIndicators: true) {
              HighlightedJSONText(json: beautifiedJSON)
                .padding(Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color.tableHeaderBackground)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
          } else {
            // Without word wrap: both horizontal and vertical scroll
            ScrollView(.horizontal, showsIndicators: true) {
              ScrollView(.vertical, showsIndicators: true) {
                HighlightedJSONText(json: beautifiedJSON)
                  .padding(Spacing.sm)
              }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color.tableHeaderBackground)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
          }
        } else {
          if isWordWrapEnabled {
            // With word wrap: only vertical scroll
            ScrollView(.vertical, showsIndicators: true) {
              Text(value.fullString)
                .font(.mono)
                .foregroundColor(value.isNull ? .foregroundSubtle : .foreground)
                .italic(value.isNull)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(Spacing.sm)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color.tableHeaderBackground)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
          } else {
            // Without word wrap: both horizontal and vertical scroll
            // Nested ScrollViews for both axes to avoid centering issue
            // Horizontal outside so scrollbar is always visible at bottom
            ScrollView(.horizontal, showsIndicators: true) {
              ScrollView(.vertical, showsIndicators: true) {
                Text(value.fullString)
                  .font(.mono)
                  .foregroundColor(value.isNull ? .foregroundSubtle : .foreground)
                  .italic(value.isNull)
                  .textSelection(.enabled)
                  .fixedSize(horizontal: true, vertical: true)
                  .padding(Spacing.sm)
              }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color.tableHeaderBackground)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
          }
        }
      }
    }
    .onAppear {
      // Initialize boolean values when view appears
      if case .bool(let boolValue) = value {
        editedBoolValue = boolValue
        originalBoolValue = boolValue
      }
      beautifyJSON(silent: true)
    }
    .onChange(of: value) { _, newValue in
      // Reset beautified state when value changes
      isBeautified = false
      beautifiedJSON = ""

      // Update boolean values when value changes
      if case .bool(let boolValue) = newValue {
        editedBoolValue = boolValue
        originalBoolValue = boolValue
      }
      beautifyJSON(silent: true)
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

  private var isStringValue: Bool {
    if case .string = value {
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

  // MARK: - JSON Beautification

  /// `silent` is used for automatic beautification: no toasts, and only for JSON objects/arrays.
  private func beautifyJSON(silent: Bool = false) {
    guard case .string(let stringValue) = value else { return }

    if silent {
      let first = stringValue.first(where: { !$0.isWhitespace })
      guard first == "{" || first == "[" else { return }
    }

    // Try to parse the string as JSON
    guard let data = stringValue.data(using: .utf8) else {
      if !silent { viewModel.showToast("Cannot convert string to data.", type: .error) }
      return
    }

    // Try to parse and validate that entire string is consumed
    let parsedObject: Any

    do {
      parsedObject = try JSONSerialization.jsonObject(
        with: data,
        options: .allowFragments
      )

      // Check if entire data was consumed by trying to parse again from start
      // If there's trailing data, JSONSerialization will only parse the first valid object
      let serializedData = try JSONSerialization.data(withJSONObject: parsedObject, options: [])

      // Compare original data length with serialized length
      // If original is significantly longer, there's likely trailing invalid JSON
      if data.count > Int(Double(serializedData.count) * 1.5) {
        if silent { return }
        viewModel.showToast(
          "Warning: Only the first valid JSON object was beautified. The input contains multiple objects or invalid trailing data.",
          type: .warning
        )
      }

      // Generate pretty printed version
      let prettyData = try JSONSerialization.data(
        withJSONObject: parsedObject,
        options: .prettyPrinted
      )

      guard let prettyString = String(data: prettyData, encoding: .utf8) else {
        if !silent {
          viewModel.showToast("Cannot convert beautified data to string.", type: .error)
        }
        return
      }

      // Set beautified state
      beautifiedJSON = prettyString
      isBeautified = true

    } catch {
      // Show error toast if not valid JSON
      if !silent { viewModel.showToast("Invalid JSON format. Cannot beautify.", type: .error) }
      return
    }
  }

  private func showOriginal() {
    isBeautified = false
    beautifiedJSON = ""
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

#Preview("JSON String Value") {
  @Previewable @State var viewModel = NotebookViewModel()
  let jsonString = """
    {"user":{"id":123,"name":"John Doe","email":"john@example.com","profile":{"bio":"Software developer","location":"San Francisco"},"tags":["developer","swift","ios"]}}
    """

  viewModel.rightSidebarContent = .cellInfo(
    columnName: "metadata",
    columnType: "varchar",
    value: .string(jsonString),
    tableName: "users",
    rowData: ["user_id": .int(1), "metadata": .string(jsonString)],
    primaryKeyColumns: ["user_id"],
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
