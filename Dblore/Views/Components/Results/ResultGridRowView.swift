//
//  ResultGridRowView.swift
//  Dblore
//
//  Row view of the result grid: odd displayed rows are filled with the design-system
//  `Color.tableRowAlternate`, as in the old result table; even rows keep the table background.
//  The hovered row is filled with a faint tint of `Color.accent` over the row background.
//  Selection is drawn by NSTableRowView over the background.
//

import AppKit
import SwiftUI

final class ResultGridRowView: NSTableRowView {
  static let alternateColor = NSColor(Color.tableRowAlternate)
  /// Read on each draw: the accent color can change in settings
  static var hoverColor: NSColor { NSColor(Color.accent.opacity(0.08)) }

  /// Odd displayed row, set by the coordinator each time the view is (re)used
  var isAlternate = false {
    didSet {
      if isAlternate != oldValue { needsDisplay = true }
    }
  }

  /// Row under the mouse, set by the table view
  var isHovered = false {
    didSet {
      if isHovered != oldValue { needsDisplay = true }
    }
  }

  override func drawBackground(in dirtyRect: NSRect) {
    if isAlternate {
      Self.alternateColor.setFill()
      dirtyRect.fill()
    } else {
      super.drawBackground(in: dirtyRect)
    }
    if isHovered {
      Self.hoverColor.setFill()
      dirtyRect.fill()
    }
  }
}
