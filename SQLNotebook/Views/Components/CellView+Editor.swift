//
//  CellView+Editor.swift
//  SQLNotebook
//

import SwiftUI

// MARK: - SQL Editor View

struct SQLEditorView: View {
  @Binding var content: String
  let isSelected: Bool
  let isFocused: Bool
  var onFocus: (() -> Void)?
  @Binding var textViewRef: SQLTextView?

  var body: some View {
    ZStack(alignment: .topLeading) {
      // Placeholder
      if content.isEmpty {
        Text("-- Write your SQL query here...")
          .font(.system(size: 13, design: .monospaced))
          .foregroundColor(.foregroundSubtle)
          .padding(.horizontal, Spacing.sm + 4)
          .padding(.vertical, Spacing.xxs)
      }

      // Text editor with syntax highlighting
      HighlightedTextEditor(text: $content, onFocus: onFocus, textViewRef: $textViewRef)
    }
    .padding(Spacing.sm)
    .background(Color.inputBackground)
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
    .overlay(
      RoundedRectangle(cornerRadius: CornerRadius.md)
        .stroke(isFocused ? Color.foregroundMuted.opacity(0.4) : Color.clear, lineWidth: 1)
    )
  }
}
