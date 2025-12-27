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
  @State private var isCopied = false

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

        // Value header with copy button
        HStack {
          Text("Value")
            .font(.caption)
            .foregroundColor(.foregroundSubtle)

          Spacer()

          FloatingPanelButton(
            icon: isCopied ? "checkmark" : "doc.on.doc",
            helpText: "Copy Value",
            useSymbolEffect: true,
            action: copyToClipboard
          )
        }
      }
      .padding(.bottom, Spacing.md)

      // Scrollable value content - spans remaining vertical space
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
