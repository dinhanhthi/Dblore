//
//  CellView.swift
//  SQLNotebook
//

import AppKit
import SwiftUI

struct CellView: View {
  @Bindable var viewModel: NotebookViewModel
  @Binding var cell: NotebookCell
  let isSelected: Bool
  let onRun: () -> Void

  @State private var isHovered = false  // For run button visibility
  @State private var isCellHovered = false  // For cell border hover effect
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
            cellSidebar

            // Editor area
            VStack(alignment: .leading, spacing: 0) {
              editorArea
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .padding(.top, Spacing.md)
          .padding(.bottom, Spacing.md)
          .padding(.leading, 0)
          .padding(.trailing, Spacing.md)

          // Result area (if exists)
          if let result = cell.result {
            resultArea(result)
          }
        }
        .cellStyle(isSelected: isSelected, isHovered: !isSelected && isCellHovered)
        .onHover { hovering in
          isHovered = hovering
          isCellHovered = hovering
        }

        // Bottom edge hover zone (invisible, just for hover detection)
        // Extends below the cell to cover the floating panel area
        bottomEdgeHoverZone
          .offset(y: 15)  // Extend zone downward to match panel position

        // Floating action panel (shown on hover near bottom edge)
        if isBottomEdgeHovered {
          floatingActionPanel
            .offset(y: 12)
        }
      }

      // Top-right floating panel (shown when cell is hovered or selected)
      if isHovered || isSelected || isTopRightPanelHovered {
        topRightFloatingPanel.offset(x: -10, y: -15)
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
    .onChange(of: isSelected) { oldValue, newValue in
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

  // MARK: - Cell Sidebar

  @ViewBuilder
  private var cellSidebar: some View {
    VStack(spacing: Spacing.sm) {
      // Run button
      Button(action: onRun) {
        if cell.isRunning {
          ProgressView()
            .scaleEffect(0.7)
            .frame(width: 26, height: 26)
        } else {
          Image(systemName: "play.fill")
            .font(.system(size: 12))
            .foregroundColor(isHovered || isSelected ? .foreground : .foregroundMuted)
            .frame(width: 26, height: 26)
        }
      }
      .buttonStyle(GhostButtonStyle())
      .disabled(cell.isRunning)

      // Execution count
      if let count = cell.executionCount {
        Text("[\(count)]")
          .font(.monoSmall)
          .foregroundColor(.foregroundSubtle)
      }
    }
    .frame(width: ComponentSize.cellSidebarWidth)
    .padding(.top, Spacing.xs)
  }

  // MARK: - Floating Action Panel

  private var floatingActionPanel: some View {
    FloatingPanelButton(
      icon: "plus.square",
      helpText: "Add Code Cell Below",
      action: {
        viewModel.addCell(type: .sql, after: cell.id)
      }
    )
    .onHover { hovering in
      // Keep panel visible when hovering over the button itself
      isBottomEdgeHovered = hovering
    }
  }

  // MARK: - Top-Right Floating Panel

  private var topRightFloatingPanel: some View {
    HStack(spacing: Spacing.sm) {
      if isDeleteConfirming {
        // Confirmation buttons (check and cross)
        FloatingPanelButton(
          icon: "checkmark",
          helpText: "Confirm Delete",
          action: {
            viewModel.deleteCell(id: cell.id)
            isDeleteConfirming = false
          }
        )

        FloatingPanelButton(
          icon: "xmark",
          helpText: "Cancel Delete",
          action: {
            isDeleteConfirming = false
          }
        )
      } else {
        // Normal buttons (delete and copy)
        FloatingPanelButton(
          icon: "trash",
          helpText: "Delete Cell",
          action: {
            isDeleteConfirming = true
          }
        )
      }

      FloatingPanelButton(
        icon: isCopied ? "checkmark" : "doc.on.doc",
        helpText: "Copy Cell Content",
        useSymbolEffect: true,
        action: copyCellContent
      )
    }
    .padding(.top, Spacing.xs)
    .padding(.trailing, Spacing.xs)
    .onHover { hovering in
      // Keep panel visible when hovering over the buttons
      isTopRightPanelHovered = hovering
      // Reset confirmation state when mouse leaves the panel
      if !hovering && isDeleteConfirming {
        isDeleteConfirming = false
      }
    }
  }

  // MARK: - Helper Functions

  private func copyCellContent() {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(cell.content, forType: .string)

    // Show checkmark feedback
    isCopied = true

    // Reset back to copy icon after 500ms
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      isCopied = false
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
  }

  // MARK: - Result Area

  @ViewBuilder
  private func resultArea(_ result: CellResult) -> some View {
    HStack(alignment: .top, spacing: 0) {
      // Fake sidebar to align with cell sidebar
      Color.clear
        .frame(width: ComponentSize.cellSidebarWidth)

      VStack(alignment: .leading, spacing: Spacing.md) {
        if let error = result.error {
          // Error display
          errorView(error)
        } else {
          // Result table
          ResultTableView(result: result, viewModel: viewModel, cellId: cell.id)

          // Result metadata
          resultMetadata(result)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 0)
      .padding(.bottom, 0)
      .padding(.trailing, Spacing.md)
    }
    .padding(.bottom, Spacing.md)
  }

  private func errorView(_ error: String) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: Spacing.sm) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundColor(.destructive)

        Text("Error")
          .font(.system(size: 13, weight: .semibold))
          .foregroundColor(.destructive)
      }
      .padding(.bottom, Spacing.md)

      Text(error)
        .font(.mono)
        .foregroundColor(.destructive)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(Spacing.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.destructive.opacity(0.1))
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
  }

  private func resultMetadata(_ result: CellResult) -> some View {
    HStack(spacing: Spacing.md) {
      Text("Rows: \(result.rowCount)")

      // Show warning if limited (either auto-limited or user LIMIT exceeded)
      if result.wasLimited || result.userLimitExceeded {
        HStack(spacing: Spacing.xs) {
          Text("(")
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundColor(.foregroundSubtle)
          Text("limited to \(AppSettings.shared.maxRowLimit) rows")
            .foregroundColor(.foregroundSubtle)
          Text(")")
        }.font(.caption2)
      }

      Text("|")
        .foregroundColor(.foregroundSubtle)
      Text(String(format: "Execution time: %.3fs", result.executionTime))
      Text("|")
        .foregroundColor(.foregroundSubtle)
      Text(formatTimestamp(result.timestamp))
    }
    .font(.caption)
    .foregroundColor(.foregroundSubtle)
  }

  private func formatTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .medium
    return formatter.string(from: date)
  }

  // MARK: - Context Menu

  @ViewBuilder
  private var cellContextMenu: some View {
    Button(action: onRun) {
      Label("Run", systemImage: "play.fill")
    }

    Divider()

    Button(action: { viewModel.duplicateCell(id: cell.id) }) {
      Label("Duplicate", systemImage: "doc.on.doc")
    }

    Button(action: { viewModel.moveSelectedCellUp() }) {
      Label("Move Up", systemImage: "arrow.up")
    }

    Button(action: { viewModel.moveSelectedCellDown() }) {
      Label("Move Down", systemImage: "arrow.down")
    }

    Divider()

    Button(action: { viewModel.clearCellOutput(id: cell.id) }) {
      Label("Clear Output", systemImage: "trash")
    }
    .disabled(cell.result == nil)

    Button(role: .destructive, action: { viewModel.deleteCell(id: cell.id) }) {
      Label("Delete", systemImage: "trash.fill")
    }
  }
}
