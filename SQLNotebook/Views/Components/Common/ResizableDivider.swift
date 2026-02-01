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

  /// Total height of the container
  let totalHeight: CGFloat

  /// Minimum height for top panel (prevents collapse)
  let minTopHeight: CGFloat

  /// Minimum height for bottom panel (prevents collapse)
  let minBottomHeight: CGFloat

  @State private var isDragging = false
  @State private var isHovering = false

  var body: some View {
    Rectangle()
      .fill(Color.border)
      .frame(height: 1)
      .background(
        // Invisible hit area for better UX - extends upward only to avoid blocking result header
        Rectangle()
          .fill(Color.clear)
          .frame(height: 8)
          .offset(y: -3.5)  // Shift up so hit area doesn't overlap with result header below
          .contentShape(Rectangle())
      )
      .background(
        // Hover indicator
        Rectangle()
          .fill(
            isDragging
              ? Color.accent.opacity(0.3) : (isHovering ? Color.accent.opacity(0.1) : Color.clear)
          )
          .frame(height: 8)
          .offset(y: -3.5)  // Match hit area position
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
