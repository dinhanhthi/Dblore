//
//  ResultGridRowView.swift
//  SQLNotebook
//
//  Row view of the result grid: odd displayed rows are filled with the design-system
//  `Color.tableRowAlternate`, as in the old result table; even rows keep the table background.
//  Selection is drawn by NSTableRowView over the background.
//

import AppKit
import SwiftUI

final class ResultGridRowView: NSTableRowView {
  static let alternateColor = NSColor(Color.tableRowAlternate)

  /// Odd displayed row, set by the coordinator each time the view is (re)used
  var isAlternate = false {
    didSet {
      if isAlternate != oldValue { needsDisplay = true }
    }
  }

  override func drawBackground(in dirtyRect: NSRect) {
    guard isAlternate else {
      super.drawBackground(in: dirtyRect)
      return
    }
    Self.alternateColor.setFill()
    dirtyRect.fill()
  }
}
