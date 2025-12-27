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

  var body: some View {
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

      // Full value
      VStack(alignment: .leading, spacing: Spacing.xs) {
        HStack {
          Text("Value")
            .font(.caption)
            .foregroundColor(.foregroundSubtle)

          Spacer()

          Button(action: copyToClipboard) {
            Label("Copy", systemImage: "doc.on.doc")
          }
          .buttonStyle(GhostButtonStyle())
        }

        ScrollView {
          Text(value.fullString)
            .font(.mono)
            .foregroundColor(value.isNull ? .foregroundSubtle : .foreground)
            .italic(value.isNull)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 200)
        .padding(Spacing.sm)
        .background(Color.cellBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
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

  private func copyToClipboard() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value.fullString, forType: .string)
  }
}
