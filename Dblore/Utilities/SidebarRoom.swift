//
//  SidebarRoom.swift
//  Dblore
//

import CoreGraphics

/// Widths of the workspace sidebars at a window width, and whether the tab content between them
/// keeps its minimum width.
enum SidebarRoom {
  /// Narrowest the tab content gets before its header and footer toolbars push the right
  /// sidebar out of the window (about 576 in the data viewer)
  static let minContentWidth: CGFloat = 580
  /// Widest a left sidebar or the AI panel gets, as a share of the window width
  static let maxWidthFraction: CGFloat = 0.35

  /// Left sidebar as laid out: the stored width, at most 35% of the window
  static func leftWidth(_ stored: CGFloat, windowWidth: CGFloat) -> CGFloat {
    min(stored, windowWidth * maxWidthFraction)
  }

  /// Widest the AI panel gets: 35% of the window, never below the sidebar width
  static func aiMaxWidth(windowWidth: CGFloat) -> CGFloat {
    max(ComponentSize.sidebarWidth, windowWidth * maxWidthFraction)
  }

  /// AI panel as laid out: the stored width, between the sidebar width and `aiMaxWidth`
  static func aiWidth(_ stored: CGFloat, windowWidth: CGFloat) -> CGFloat {
    min(max(stored, ComponentSize.sidebarWidth), aiMaxWidth(windowWidth: windowWidth))
  }

  /// Whether the tab content keeps `minContentWidth` beside both sidebars
  static func leftSidebarFits(
    windowWidth: CGFloat, leftWidth: CGFloat, rightWidth: CGFloat
  )
    -> Bool
  {
    windowWidth - leftWidth - rightWidth >= minContentWidth
  }
}
