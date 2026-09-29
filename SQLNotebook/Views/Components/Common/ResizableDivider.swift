//
//  ResizableDivider.swift
//  SQLNotebook
//
//  A draggable horizontal divider for resizing split-view panels
//

import SwiftUI

// MARK: - Resizable Divider

/// A draggable horizontal divider for resizing split-view panels.
///
/// Features:
/// - Drag to resize panels with smooth animation
/// - Double-click to reset to 50/50 split
/// - Hover indicator for visual feedback
/// - Optimized hit area (8pt) to avoid overlapping with adjacent UI elements
///
/// The hit area extends **upward** (-3.5pt offset) to prevent interference with
/// the result panel header positioned below the divider.
///
/// Example:
/// ```swift
/// ResizableDivider(
///   position: $dividerPosition,
///   totalHeight: geometry.height,
///   minTopHeight: 250,
///   minBottomHeight: 250
/// )
/// ```
struct ResizableDivider: View {
  /// Position of divider as ratio (0.0 = top, 1.0 = bottom)
  @Binding var position: CGFloat

  /// Direction the panels are laid out in: `.vertical` = top/bottom (horizontal divider line),
  /// `.horizontal` = left/right (vertical divider line; the "height" values below are then widths)
  var axis: Axis = .vertical

  /// Total height of the container
  let totalHeight: CGFloat

  /// Minimum height for top panel (prevents collapse)
  let minTopHeight: CGFloat

  /// Minimum height for bottom panel (prevents collapse)
  let minBottomHeight: CGFloat

  @State private var isDragging = false
  @State private var isHovering = false

  private var isSideBySide: Bool { axis == .horizontal }

  var body: some View {
    Rectangle()
      .fill(Color.border)
      .frame(width: isSideBySide ? 1 : nil, height: isSideBySide ? nil : 1)
      .background(
        // Invisible hit area for better UX - extends up/left only to avoid blocking result header
        Rectangle()
          .fill(Color.clear)
          .frame(width: isSideBySide ? 8 : nil, height: isSideBySide ? nil : 8)
          .offset(x: isSideBySide ? -3.5 : 0, y: isSideBySide ? 0 : -3.5)
          .contentShape(Rectangle())
      )
      .background(
        // Hover indicator
        Rectangle()
          .fill(
            isDragging
              ? Color.accent.opacity(0.3) : (isHovering ? Color.accent.opacity(0.1) : Color.clear)
          )
          .frame(width: isSideBySide ? 8 : nil, height: isSideBySide ? nil : 8)
          // Match hit area position
          .offset(x: isSideBySide ? -3.5 : 0, y: isSideBySide ? 0 : -3.5)
      )
      .cursor(isSideBySide ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown)
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
            let delta = isSideBySide ? value.translation.width : value.translation.height
            let newHeight = totalHeight * position + delta
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
