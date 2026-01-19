//
//  EditorModeView.swift
//  SQLNotebook
//

import SwiftUI

/// Editor mode view - Single SQL editor with result panel below
struct EditorModeView: View {
  @Bindable var viewModel: NotebookViewModel
  @State private var textViewRef: SQLTextView?
  @State private var isFocused: Bool = false
  @State private var dividerPosition: CGFloat = 0.5  // 50% initial split

  var body: some View {
    GeometryReader { geometry in
      let totalHeight = geometry.size.height
      let minPanelHeight: CGFloat = 150
      let maxEditorHeight = totalHeight - minPanelHeight

      // Calculate actual heights based on divider position
      let editorHeight = max(minPanelHeight, min(maxEditorHeight, totalHeight * dividerPosition))
      let resultHeight = totalHeight - editorHeight

      VStack(spacing: 0) {
        // Top: SQL Editor (with distinct background like cell editor)
        SQLEditorView(
          content: $viewModel.editorContent,
          isSelected: true,
          isFocused: isFocused,
          onFocus: { isFocused = true },
          textViewRef: $textViewRef,
          autocompleteProvider: viewModel.autocompleteProvider,
          maxHeight: editorHeight - Spacing.sm * 2,  // Account for padding
          isEditorMode: true  // Remove border and focus effects
        )
        .background(Color.inputBackground)
        .frame(width: geometry.size.width, height: editorHeight)

        // Draggable divider
        ResizableDivider(
          position: $dividerPosition,
          totalHeight: totalHeight,
          minTopHeight: minPanelHeight,
          minBottomHeight: minPanelHeight
        )

        // Bottom: Result Panel
        if let result = viewModel.editorResult {
          VStack(alignment: .leading, spacing: 0) {
            resultPanelHeader(result: result)

            // Result table or error
            if let error = result.error {
              errorView(error: error)
            } else {
              ResultTableView(
                result: result,
                viewModel: viewModel,
                cellId: nil,  // No cell ID in editor mode
                showBorderRadius: false  // No border radius in editor mode
              )
            }

            Spacer(minLength: 0)
          }
          .frame(width: geometry.size.width, height: resultHeight)
        } else {
          // Empty state
          VStack {
            Spacer()
            Text("No results yet")
              .font(.system(size: 14))
              .foregroundColor(.foregroundSubtle)
            Text("Run a query to see results")
              .font(.system(size: 12))
              .foregroundColor(.foregroundMuted)
            Spacer()
          }
          .frame(width: geometry.size.width, height: resultHeight)
        }
      }
    }
    .onChange(of: textViewRef) { _, newValue in
      viewModel.editorTextView = newValue
    }
  }

  // MARK: - Result Panel Header

  private func resultPanelHeader(result: CellResult) -> some View {
    HStack {
      // Result info
      HStack(spacing: Spacing.sm) {
        Image(systemName: result.error != nil ? "xmark.circle.fill" : "checkmark.circle.fill")
          .foregroundColor(result.error != nil ? .red : .green)
          .font(.system(size: 12))

        if result.error == nil {
          Text("\(result.rowCount) row\(result.rowCount == 1 ? "" : "s")")
            .font(.system(size: 12))
            .foregroundColor(.foregroundSubtle)

          Text("•")
            .foregroundColor(.foregroundMuted)

          Text(String(format: "%.2fs", result.executionTime))
            .font(.system(size: 12))
            .foregroundColor(.foregroundSubtle)
        }
      }

      Spacer()

      // Clear button
      Button(action: clearResult) {
        Image(systemName: "xmark")
          .font(.system(size: 10))
          .foregroundColor(.foregroundSubtle)
      }
      .buttonStyle(.plain)
      .help("Clear result")
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .background(Color.appBackground)
    .overlay(
      Rectangle()
        .fill(Color.foregroundMuted.opacity(0.1))
        .frame(height: 1),
      alignment: .bottom
    )
  }

  private func errorView(error: String) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        Text("Error")
          .font(.system(size: 13, weight: .semibold))
          .foregroundColor(.red)

        Text(error)
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(Color.foreground)
          .textSelection(.enabled)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(Spacing.md)
    }
    .background(Color.red.opacity(0.05))
  }

  // MARK: - Actions

  private func clearResult() {
    viewModel.editorResult = nil
  }
}

// MARK: - Resizable Divider

/// A draggable horizontal divider for resizing panels
struct ResizableDivider: View {
  @Binding var position: CGFloat  // Position as ratio (0.0 to 1.0)
  let totalHeight: CGFloat
  let minTopHeight: CGFloat
  let minBottomHeight: CGFloat

  @State private var isDragging = false
  @State private var isHovering = false

  var body: some View {
    Rectangle()
      .fill(Color.border)
      .frame(height: 1)
      .overlay(
        // Invisible hit area for better UX
        Rectangle()
          .fill(Color.clear)
          .frame(height: 8)
          .contentShape(Rectangle())
      )
      .background(
        // Hover indicator
        Rectangle()
          .fill(isDragging ? Color.accent.opacity(0.3) : (isHovering ? Color.accent.opacity(0.1) : Color.clear))
          .frame(height: 8)
      )
      .cursor(NSCursor.resizeUpDown)
      .onHover { hovering in
        isHovering = hovering
      }
      .onTapGesture(count: 2) {
        // Double-click to reset to 50/50
        withAnimation(.easeInOut(duration: 0.2)) {
          position = 0.5
        }
      }
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            isDragging = true
            let newHeight = totalHeight * position + value.translation.height
            let maxTop = totalHeight - minBottomHeight
            let minTop = minTopHeight

            // Clamp the new height
            let clampedHeight = max(minTop, min(maxTop, newHeight))
            position = clampedHeight / totalHeight
          }
          .onEnded { _ in
            isDragging = false
          }
      )
  }
}

// MARK: - Previews

#Preview("Empty State") {
  let viewModel = NotebookViewModel()
  viewModel.viewMode = .editor
  viewModel.editorContent = "SELECT * FROM users\nWHERE status = 'active'\nLIMIT 10;"
  return EditorModeView(viewModel: viewModel)
    .frame(width: 800, height: 600)
    .background(Color.appBackground)
    .preferredColorScheme(.dark)
}

#Preview("With Result") {
  let viewModel = NotebookViewModel()
  viewModel.viewMode = .editor
  viewModel.editorContent = "SELECT id, name, email, status\nFROM users\nLIMIT 4;"
  viewModel.editorResult = CellResult(
    columns: [
      ColumnInfo(name: "id", type: "INTEGER"),
      ColumnInfo(name: "name", type: "VARCHAR"),
      ColumnInfo(name: "email", type: "VARCHAR"),
      ColumnInfo(name: "status", type: "VARCHAR"),
    ],
    rows: [
      [.int(1), .string("Alice"), .string("alice@example.com"), .string("Active")],
      [.int(2), .string("Bob"), .string("bob@example.com"), .string("Inactive")],
      [.int(3), .string("Charlie"), .string("charlie@example.com"), .string("Active")],
      [.int(4), .string("Diana"), .string("diana@example.com"), .string("Active")],
    ],
    executionTime: 0.045,
    rowCount: 4,
    timestamp: Date(),
    sourceQuery: "SELECT id, name, email, status FROM users LIMIT 4"
  )
  return EditorModeView(viewModel: viewModel)
    .frame(width: 800, height: 600)
    .background(Color.appBackground)
    .preferredColorScheme(.dark)
}

#Preview("With Error") {
  let viewModel = NotebookViewModel()
  viewModel.viewMode = .editor
  viewModel.editorContent = "SELECT invalid_column FROM users;"
  viewModel.editorResult = CellResult(
    columns: [],
    rows: [],
    executionTime: 0.003,
    rowCount: 0,
    timestamp: Date(),
    error: "ERROR: column \"invalid_column\" does not exist\nLINE 1: SELECT invalid_column FROM users;\n               ^",
    sourceQuery: "SELECT invalid_column FROM users"
  )
  return EditorModeView(viewModel: viewModel)
    .frame(width: 800, height: 600)
    .background(Color.appBackground)
    .preferredColorScheme(.dark)
}
