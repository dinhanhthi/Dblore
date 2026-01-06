//
//  CellComponents.swift
//  SQLNotebook
//
//  Extracted subview components for CellView to maintain 400-line limit per file.
//

import SwiftUI

// MARK: - Cell Sidebar Component

struct CellSidebarView: View {
  let cell: NotebookCell
  let isHovered: Bool
  let isSelected: Bool
  let viewModel: NotebookViewModel
  let onRun: () -> Void

  var body: some View {
    VStack(spacing: Spacing.sm) {
      // Run button
      Button(action: onRun) {
        if cell.isRunning {
          ProgressView()
            .controlSize(.small)
            .tint(.accent)
            .frame(width: 26, height: 26)
        } else if let position = viewModel.executionQueue.queuePosition(for: cell.id) {
          // Show queue position
          Text("\(position)")
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.accentColor)
            .frame(width: 26, height: 26)
        } else {
          Image(systemName: "play.fill")
            .font(.system(size: 12))
            .foregroundColor(isHovered || isSelected ? .foreground : .foregroundMuted)
            .frame(width: 26, height: 26)
        }
      }
      .buttonStyle(GhostButtonStyle())
      .disabled(cell.isRunning || viewModel.executionQueue.isInQueue(cellId: cell.id))

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
}

// MARK: - Floating Panel Button Component

struct FloatingPanelButton: View {
  let icon: String
  let helpText: String
  var useSymbolEffect: Bool = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: 12))
        .if(useSymbolEffect) { view in
          view.contentTransition(.symbolEffect(.replace))
        }
    }
    .buttonStyle(FloatingPanelButtonStyle())
    .help(helpText)
  }
}

// MARK: - Floating Action Panel (Bottom)

struct FloatingActionPanelView: View {
  let viewModel: NotebookViewModel
  let cellId: UUID
  @Binding var isBottomEdgeHovered: Bool

  var body: some View {
    FloatingPanelButton(
      icon: "plus.square",
      helpText: "Add Code Cell Below",
      action: {
        viewModel.addCell(type: .sql, after: cellId)
      }
    )
    .onHover { hovering in
      // Keep panel visible when hovering over the button itself
      isBottomEdgeHovered = hovering
    }
  }
}

// MARK: - Top-Right Floating Panel

struct TopRightFloatingPanelView: View {
  let cell: NotebookCell
  let viewModel: NotebookViewModel
  @Binding var isDeleteConfirming: Bool
  @Binding var isTopRightPanelHovered: Bool
  @Binding var isCopied: Bool

  var body: some View {
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
        // Normal buttons (toggle visibility, delete, copy, and cancel)

        // Cancel button (only show if cell is executing or in queue)
        if cell.isRunning || viewModel.executionQueue.isInQueue(cellId: cell.id) {
          FloatingPanelButton(
            icon: "stop.fill",
            helpText: "Cancel Execution",
            action: {
              viewModel.cancelCell(id: cell.id)
            }
          )
        }

        // Toggle visibility button (only show if cell has result)
        if cell.result != nil {
          FloatingPanelButton(
            icon: cell.isResultVisible ? "eye.slash" : "eye",
            helpText: cell.isResultVisible ? "Hide Result" : "Show Result",
            action: {
              viewModel.toggleResultVisibility(cellId: cell.id)
            }
          )
        }

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
        action: {
          copyCellContent()
        }
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
}

// MARK: - Executed Query Display

struct ExecutedQueryDisplayView: View {
  let query: String

  var body: some View {
    HStack(spacing: Spacing.xs) {
      Image(systemName: "arrow.right.circle.fill")
        .font(.system(size: 10))
        .foregroundColor(.foregroundSubtle)

      Text(query)
        .font(.system(size: 11))
        .foregroundColor(.foregroundSubtle)
        .lineLimit(3)
        .textSelection(.enabled)
    }
    .padding(.top, Spacing.xs)
    .padding(.bottom, Spacing.xs)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

// MARK: - Hidden Result Placeholder

struct HiddenResultPlaceholderView: View {
  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      // Fake sidebar to align with cell sidebar
      Color.clear
        .frame(width: ComponentSize.cellSidebarWidth)

      HStack(spacing: Spacing.sm) {
        Image(systemName: "eye.slash")
          .foregroundColor(.foregroundSubtle)
        Text("Result is hidden")
          .foregroundColor(.foregroundSubtle)
      }
      .font(.system(size: 13))
      .frame(maxWidth: .infinity)
      .padding(.top, 0)
      .padding(.bottom, Spacing.xs)
      .padding(.horizontal, Spacing.md)
      .background(Color.cellBackground.opacity(0.5))
      .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
      .padding(.trailing, Spacing.md)
    }
    .padding(.bottom, Spacing.md)
  }
}
