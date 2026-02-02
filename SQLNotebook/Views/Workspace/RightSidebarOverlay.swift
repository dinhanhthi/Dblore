//
//  RightSidebarOverlay.swift
//  SQLNotebook
//

import SwiftUI

/// Right sidebar that overlays the main content instead of pushing it
struct RightSidebarOverlay: View {
  @Bindable var workspaceManager: WorkspaceManager
  @State private var width: CGFloat = 380

  private let minWidth: CGFloat = 320
  private let maxWidth: CGFloat = 600

  var body: some View {
    VStack(spacing: 0) {
      // Header with close button
      RightSidebarOverlayHeader(
        title: headerTitle,
        onClose: { workspaceManager.hideRightSidebar() }
      )

      // Content
      Group {
        if let content = workspaceManager.rightSidebarContent {
          rightSidebarContent(for: content)
        } else {
          EmptyView()
        }
      }
    }
    .frame(width: width)
    .background(Color.cardBackground)
    .overlay(alignment: .leading) {
      // Left edge border
      Rectangle()
        .fill(Color.border)
        .frame(width: 1)
    }
    .shadow(color: .black.opacity(0.15), radius: 12, x: -4, y: 0)
    .overlay(alignment: .leading) {
      // Resize handle
      ResizeHandle(
        width: $width,
        minWidth: minWidth,
        maxWidth: maxWidth
      )
    }
  }

  private var headerTitle: String {
    guard let content = workspaceManager.rightSidebarContent else { return "" }
    switch content {
    case .jsonViewer: return "JSON Viewer"
    case .cellInfo: return "Cell Info"
    case .executedQuery: return "Executed Query"
    }
  }

  @ViewBuilder
  private func rightSidebarContent(for content: SidebarContent) -> some View {
    switch content {
    case .jsonViewer(let json, let path):
      JSONViewerContent(json: json, path: path, onSave: nil)

    case .cellInfo(
      let columnName, let columnType, let value, _, _, _,
      _, _):
      CellInfoContent(
        columnName: columnName,
        columnType: columnType,
        value: value,
        onSave: nil,
        isReadOnly: true
      )

    case .executedQuery(let query, let cellId, let limitWasCapped, let actualLimit):
      ExecutedQuerySidebarContent(
        query: query,
        cellId: cellId,
        limitWasCapped: limitWasCapped,
        actualLimit: actualLimit
      )
    }
  }
}

// MARK: - Header

struct RightSidebarOverlayHeader: View {
  let title: String
  let onClose: () -> Void

  var body: some View {
    HStack {
      Text(title)
        .font(.headline)
        .foregroundColor(.foreground)

      Spacer()

      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.system(size: 12, weight: .medium))
          .foregroundColor(.foregroundMuted)
      }
      .buttonStyle(.plain)
      .keyboardShortcut(.escape, modifiers: [])
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .background(Color.cardBackground)
    .overlay(alignment: .bottom) {
      Divider()
    }
  }
}

// MARK: - Resize Handle

struct ResizeHandle: View {
  @Binding var width: CGFloat
  let minWidth: CGFloat
  let maxWidth: CGFloat

  @State private var isDragging = false

  var body: some View {
    Rectangle()
      .fill(Color.clear)
      .frame(width: 8)
      .contentShape(Rectangle())
      .cursor(.resizeLeftRight)
      .gesture(
        DragGesture(minimumDistance: 1)
          .onChanged { value in
            isDragging = true
            // Dragging left = increase width, dragging right = decrease width
            let newWidth = width - value.translation.width
            width = min(max(newWidth, minWidth), maxWidth)
          }
          .onEnded { _ in
            isDragging = false
          }
      )
      .overlay {
        if isDragging {
          Rectangle()
            .fill(Color.accent.opacity(0.3))
            .frame(width: 2)
        }
      }
  }
}
