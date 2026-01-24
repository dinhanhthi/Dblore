//
//  ResizableSidebarDivider.swift
//  SQLNotebook
//

import SwiftUI

/// A draggable divider that allows resizing sidebars
struct ResizableSidebarDivider: View {
  @Binding var sidebarWidth: CGFloat
  let minWidth: CGFloat
  let maxWidth: CGFloat
  let side: Side

  @State private var isDragging = false
  @State private var dragOffset: CGFloat = 0

  enum Side {
    case left
    case right
  }

  var body: some View {
    Rectangle()
      .fill(isDragging ? Color.accent.opacity(0.3) : Color.clear)
      .frame(width: 8)
      .contentShape(Rectangle())
      .overlay {
        if isDragging {
          Rectangle()
            .fill(Color.accent)
            .frame(width: 2)
        }
      }
      .onHover { hovering in
        if hovering {
          NSCursor.resizeLeftRight.push()
        } else {
          NSCursor.pop()
        }
      }
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            if !isDragging {
              isDragging = true
            }

            // Calculate new width based on drag direction and sidebar side
            let delta = side == .left ? value.translation.width : -value.translation.width
            let newWidth = sidebarWidth + delta - dragOffset

            // Clamp to min/max
            let clampedWidth = min(max(newWidth, minWidth), maxWidth)

            // Update width
            sidebarWidth = clampedWidth

            // Track offset for smooth dragging
            dragOffset = delta
          }
          .onEnded { _ in
            isDragging = false
            dragOffset = 0
          }
      )
  }
}
