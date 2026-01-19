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
  @State private var isTextEmpty: Bool = true

  var autocompleteProvider: SQLAutocompleteProvider?
  var cellId: UUID? // For search highlighting
  var maxHeight: CGFloat? // Optional max height for scrollable editors (e.g., in editor mode)
  var isEditorMode: Bool = false // True when used in Editor mode (removes border/focus effects)

  var body: some View {
    editorContent
      .onAppear {
        // Initialize isEmpty state based on content
        isTextEmpty = content.isEmpty
      }
      .onChange(of: content) { _, newValue in
        // Update isEmpty when content changes externally
        isTextEmpty = newValue.isEmpty
      }
  }

  @ViewBuilder
  private var editorContent: some View {
    let baseView = ZStack(alignment: .topLeading) {
      // Placeholder - use isTextEmpty state for immediate reactivity
      if isTextEmpty {
        Text("-- Write your SQL query here...")
          .font(.system(size: 13, design: .monospaced))
          .foregroundColor(.foregroundSubtle)
          .padding(.horizontal, Spacing.sm + 4)
          .padding(.vertical, Spacing.xxs)
          .allowsHitTesting(false) // Allow clicks to pass through to background
      }

      // Text editor with syntax highlighting
      HighlightedTextEditor(
        text: $content,
        onFocus: onFocus,
        textViewRef: $textViewRef,
        isEmpty: $isTextEmpty,
        autocompleteProvider: autocompleteProvider,
        cellId: cellId,
        maxHeight: maxHeight
      )
    }
    .padding(isEditorMode ? .leading : .all, Spacing.sm)
    .padding(isEditorMode ? .vertical : [], Spacing.sm)
    .background(Color.inputBackground)
    .contentShape(Rectangle()) // Make entire area clickable
    .onTapGesture {
      // Focus on text editor when clicking anywhere in the editor area
      if let textView = textViewRef {
        textView.window?.makeFirstResponder(textView)
      }
      onFocus?()
    }

    if isEditorMode {
      // Editor mode: no border, no rounded corners, no right padding for scrollbar
      baseView
    } else {
      // Cell mode: rounded corners + focus border
      baseView
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
        .overlay(
          RoundedRectangle(cornerRadius: CornerRadius.md)
            .stroke(isFocused ? Color.foregroundMuted.opacity(0.4) : Color.clear, lineWidth: 1)
        )
    }
  }
}

// MARK: - Preview

#Preview("SQL Editor") {
  @Previewable @State var content = "SELECT * FROM users WHERE id = 1;"
  @Previewable @State var textViewRef: SQLTextView? = nil

  SQLEditorView(
    content: $content,
    isSelected: true,
    isFocused: true,
    textViewRef: $textViewRef
  )
  .frame(width: 400, height: 120)
  .padding()
}
