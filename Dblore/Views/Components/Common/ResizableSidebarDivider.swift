//
//  ResizableSidebarDivider.swift
//  Dblore
//

import SwiftUI

/// A draggable divider that allows resizing sidebars
struct ResizableSidebarDivider: View {
  @Binding var sidebarWidth: CGFloat
  let minWidth: CGFloat
  let maxWidth: CGFloat
  let side: Side

  @State private var isDragging = false
  @State private var startWidth: CGFloat = 0

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
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
          .onChanged { value in
            if !isDragging {
              isDragging = true
              startWidth = sidebarWidth
            }

            // Calculate new width based on drag direction and sidebar side
            let delta = side == .left ? value.translation.width : -value.translation.width
            let newWidth = startWidth + delta

            // Clamp to min/max and update without animation
            let clampedWidth = min(max(newWidth, minWidth), maxWidth)
            withTransaction(Transaction(animation: nil)) {
              sidebarWidth = clampedWidth
            }
          }
          .onEnded { _ in
            isDragging = false
          }
      )
  }
}
