//
//  CellView.swift
//  SQLNotebook
//
//  Main cell view component. Split into multiple files to maintain 400-line limit:
//  - CellView.swift (this file) — Main view struct, body, and all previews
//  - CellComponents.swift — Extracted subview components
//  - CellResultViews.swift — Result display views
//  - CellView+ContextMenu.swift — Context menu extension
//

import AppKit
import SwiftUI

struct CellView: View {
  @Bindable var viewModel: NotebookViewModel
  @Binding var cell: NotebookCell
  let isSelected: Bool
  let onRun: () -> Void

  @State private var isHovered = false  // Combined hover state for all hover zones
  @State private var isBottomEdgeHovered = false  // For floating action panel
  @State private var isTopRightPanelHovered = false  // For top-right panel hover
  @State private var isCopied = false  // For copy button feedback
  @State private var isDeleteConfirming = false  // For delete confirmation state
  @FocusState private var isEditorFocused: Bool
  @State private var textViewRef: SQLTextView?  // Reference to text view for text insertion

  var body: some View {
    ZStack(alignment: .topTrailing) {
      ZStack(alignment: .bottom) {
        VStack(spacing: 0) {
          // Main cell content
          HStack(alignment: .top, spacing: 0) {
            // Left sidebar with controls
            CellSidebarView(
              cell: cell,
              isHovered: isHovered,
              isSelected: isSelected,
              viewModel: viewModel,
              onRun: onRun
            )

            // Editor area
            editorArea
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .padding(.top, Spacing.md)
          .padding(.bottom, Spacing.md)
          .padding(.leading, 0)
          .padding(.trailing, Spacing.md)

          // Result area (if exists)
          if let result = cell.result {
            if cell.isResultVisible {
              ResultAreaView(result: result, viewModel: viewModel, cellId: cell.id)
            } else {
              HiddenResultPlaceholderView()
            }
          }
        }
        .cellStyle(isSelected: isSelected, isHovered: !isSelected && isHovered)
        .onHover { hovering in
          isHovered = hovering
        }

        // Bottom edge hover zone (invisible, just for hover detection)
        // Extends below the cell to cover the floating panel area
        bottomEdgeHoverZone
          .offset(y: 15)  // Extend zone downward to match panel position

        // Floating action panel (shown on hover near bottom edge)
        if isBottomEdgeHovered {
          FloatingActionPanelView(
            viewModel: viewModel,
            cellId: cell.id,
            isBottomEdgeHovered: $isBottomEdgeHovered
          )
          .offset(y: 12)
        }
      }

      // Top-right floating panel (shown when cell is hovered or selected)
      if isHovered || isSelected || isTopRightPanelHovered {
        TopRightFloatingPanelView(
          cell: cell,
          viewModel: viewModel,
          isDeleteConfirming: $isDeleteConfirming,
          isTopRightPanelHovered: $isTopRightPanelHovered,
          isCopied: $isCopied
        )
        .offset(x: -10, y: -15)
      }
    }
    .onTapGesture {
      viewModel.selectedCellId = cell.id
      // Clear editor focus when clicking outside editor
      isEditorFocused = false
    }
    .contextMenu {
      cellContextMenu
    }
    .onChange(of: isSelected) { _, newValue in
      // Clear focus when cell becomes unselected
      if !newValue {
        isEditorFocused = false
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .focusEditor)) { _ in
      // Only focus if this cell is selected
      if isSelected {
        isEditorFocused = true
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .unfocusEditor)) { _ in
      // Unfocus from editor but keep cell selected
      isEditorFocused = false
    }
    .onReceive(NotificationCenter.default.publisher(for: .insertTextIntoCell)) { notification in
      // Only insert if this cell is selected
      guard isSelected,
        let userInfo = notification.userInfo,
        let text = userInfo["text"] as? String,
        let textView = textViewRef
      else { return }

      // Insert text at current cursor position
      let selectedRange = textView.selectedRange()
      textView.insertText(text, replacementRange: selectedRange)

      // Focus the editor after inserting text
      isEditorFocused = true
    }
  }

  // MARK: - Bottom Edge Hover Zone

  /// Invisible hover zone at the bottom edge of the cell (Jupyter-style)
  /// This zone is offset downward to align with the floating panel position
  private var bottomEdgeHoverZone: some View {
    Color.clear
      .frame(height: 50)  // Height of the hover-sensitive area
      .contentShape(Rectangle())
      .onHover { hovering in
        isBottomEdgeHovered = hovering
      }
  }

  // MARK: - Editor Area

  @ViewBuilder
  private var editorArea: some View {
    SQLEditorView(
      content: $cell.content,
      isSelected: isSelected,
      isFocused: isEditorFocused,
      onFocus: { viewModel.selectedCellId = cell.id },
      textViewRef: $textViewRef
    )
    .focused($isEditorFocused)
    .id(cell.id)  // Force recreate view when cell ID changes to prevent content leakage
  }
}

// MARK: - Previews (CRITICAL: Must be in same file as CellView implementation)

#Preview("Empty") {
  CellView(
    viewModel: NotebookViewModel(),
    cell: .constant(NotebookCell(cellType: .sql, content: "")),
    isSelected: false,
    onRun: {}
  )
  .padding()
  .frame(width: 700, height: 150)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}

#Preview("With Result") {
  @Previewable @State var cell = PreviewData.cellWithShortResult
  CellView(viewModel: NotebookViewModel(), cell: $cell, isSelected: true, onRun: {})
    .padding()
    .frame(width: 600, height: 400)
    .background(Color.appBackground)
    .preferredColorScheme(.dark)
}

#Preview("Error State") {
  @Previewable @State var cell = PreviewData.cellWithError
  CellView(viewModel: NotebookViewModel(), cell: $cell, isSelected: false, onRun: {})
    .padding()
    .frame(width: 600)
    .background(Color.appBackground)
    .preferredColorScheme(.dark)
}

#Preview("Hidden Result") {
  @Previewable @State var cell = PreviewData.cellWithHiddenResult
  CellView(viewModel: NotebookViewModel(), cell: $cell, isSelected: true, onRun: {})
    .padding()
    .frame(width: 600, height: 300)
    .background(Color.appBackground)
    .preferredColorScheme(.dark)
}

// MARK: - Preview Data (kept in same file to maintain preview/implementation co-location)

private enum PreviewData {
  static var cellWithShortResult: NotebookCell {
    var cell = NotebookCell(cellType: .sql, content: "SELECT id, name, status\nFROM users\nLIMIT 4;")
    cell.result = CellResult(
      columns: [
        ColumnInfo(name: "id", type: "INTEGER"),
        ColumnInfo(name: "name", type: "VARCHAR"),
        ColumnInfo(name: "status", type: "VARCHAR"),
      ],
      rows: [
        [.int(1), .string("Alice"), .string("Active")],
        [.int(2), .string("Bob"), .string("Inactive")],
        [.int(3), .string("Charlie"), .string("Active")],
        [.int(4), .string("Diana"), .string("Active")],
      ],
      executionTime: 0.012,
      rowCount: 4,
      timestamp: Date(),
      sourceQuery: "SELECT id, name, status FROM users LIMIT 4"
    )
    cell.executionCount = 1
    return cell
  }

  static var cellWithError: NotebookCell {
    var cell = NotebookCell(cellType: .sql, content: "SELECT invalid_column FROM users;")
    cell.result = CellResult(
      columns: [], rows: [], executionTime: 0.003, rowCount: 0, timestamp: Date(),
      error:
        "ERROR: column \"invalid_column\" does not exist\nLINE 1: SELECT invalid_column FROM users;\n               ^",
      sourceQuery: "SELECT invalid_column FROM users"
    )
    cell.executionCount = 5
    return cell
  }

  static var cellWithHiddenResult: NotebookCell {
    var cell = NotebookCell(
      cellType: .sql, content: "SELECT id, name, email\nFROM users\nLIMIT 3;",
      isResultVisible: false)
    cell.result = CellResult(
      columns: [
        ColumnInfo(name: "id", type: "INTEGER"),
        ColumnInfo(name: "name", type: "VARCHAR"),
        ColumnInfo(name: "email", type: "VARCHAR"),
      ],
      rows: [
        [.int(1), .string("Alice Johnson"), .string("alice@example.com")],
        [.int(2), .string("Bob Williams"), .string("bob@example.com")],
        [.int(3), .string("Charlie Brown"), .string("charlie@example.com")],
      ],
      executionTime: 0.045, rowCount: 3, timestamp: Date(),
      sourceQuery: "SELECT id, name, email FROM users LIMIT 3"
    )
    cell.executionCount = 2
    return cell
  }
}
