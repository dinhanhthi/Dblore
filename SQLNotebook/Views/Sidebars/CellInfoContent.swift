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

  @State private var isCopied = false
  @State private var isEditing = false
  @State private var editedValue: String = ""
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
            // Cancel and Save icon buttons
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
          } else {
            // Edit and Copy buttons
            FloatingPanelButton(
              icon: "pencil",
              helpText: "Edit Value",
              useSymbolEffect: false,
              action: startEdit
            )

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
      if isEditing {
        TextEditor(text: $editedValue)
          .font(.mono)
          .foregroundColor(.foreground)
          .scrollContentBackground(.hidden)
          .padding(Spacing.sm)
          .background(Color.cellBackground)
          .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
          .frame(maxHeight: .infinity)
          .focused($isTextEditorFocused)
          .focusedValue(\.isCellValueEditing, isEditing)
      } else {
        ScrollView {
          Text(value.fullString)
            .font(.mono)
            .foregroundColor(value.isNull ? .foregroundSubtle : .foreground)
            .italic(value.isNull)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.sm)
        }
        .background(Color.cellBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
        .frame(maxHeight: .infinity)
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

  private func startEdit() {
    editedValue = value.fullString
    isEditing = true
    isTextEditorFocused = true
    NotificationCenter.default.post(name: .cellValueEditingStarted, object: nil)
  }

  private func cancelEdit() {
    isEditing = false
    isTextEditorFocused = false
    editedValue = ""
    NotificationCenter.default.post(name: .cellValueEditingEnded, object: nil)
  }

  private func saveEdit() {
    onSave?(editedValue)
    isEditing = false
    isTextEditorFocused = false
    editedValue = ""
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
}
