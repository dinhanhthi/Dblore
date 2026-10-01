//
//  ResultGridRowView.swift
//  Dblore
//
//  Row view of the result grid: odd displayed rows are filled with the design-system
//  `Color.tableRowAlternate`, as in the old result table; even rows keep the table background.
//  The hovered row is filled with a faint tint of `Color.accent` over the row background.
//  A staged insert or delete tints the row; a staged cell edit tints that cell. Selection
//  keeps the selection color. Selection is drawn by NSTableRowView over the background.
//

import AppKit
import SwiftUI

final class ResultGridRowView: NSTableRowView {
  static let alternateColor = NSColor(Color.tableRowAlternate)
  /// Read on each draw: the accent color can change in settings
  static var hoverColor: NSColor { NSColor(Color.accent.opacity(0.08)) }
  static let insertedColor = NSColor(Color.success.opacity(0.14))
  static let deletedColor = NSColor(Color.destructive.opacity(0.14))
  static let editedCellColor = NSColor(Color.warning.opacity(0.18))

  /// Odd displayed row, set by the coordinator each time the view is (re)used
  var isAlternate = false {
    didSet {
      if isAlternate != oldValue { needsDisplay = true }
    }
  }

  /// Staged row state. A deleted row strikes through its text.
  var stagingState: ResultGridRowState = .normal {
    didSet {
      guard stagingState != oldValue else { return }
      syncStrikethrough()
      needsDisplay = true
    }
  }

  /// Result-column indexes with a staged edit. The "#" gutter is not one of these.
  var editedColumns = IndexSet() {
    didSet {
      if editedColumns != oldValue { needsDisplay = true }
    }
  }

  /// Row tint for a staged insert or delete. Nil when the row is selected or not staged.
  var stagingTint: NSColor? {
    guard !isSelected else { return nil }
    switch stagingState {
    case .inserted: return Self.insertedColor
    case .deleted: return Self.deletedColor
    case .normal, .edited: return nil
    }
  }

  /// Warning tint for one staged cell edit. Nil when the row is selected or the cell is not edited.
  func editedCellTint(column: Int) -> NSColor? {
    guard !isSelected, editedColumns.contains(column) else { return nil }
    return Self.editedCellColor
  }

  /// Row under the mouse, set by the table view
  var isHovered = false {
    didSet {
      if isHovered != oldValue {
        needsDisplay = true
        redrawGutterCells()
      }
    }
  }

  /// Tint the "#" gutter cell shows over its own background so it follows the row state:
  /// the selection color when selected, the hover tint when hovered, nil otherwise
  var gutterOverlayColor: NSColor? {
    if isSelected {
      return isEmphasized
        ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor
    }
    return isHovered ? Self.hoverColor : nil
  }

  override var isSelected: Bool {
    didSet {
      if isSelected != oldValue {
        needsDisplay = true
        redrawGutterCells()
      }
    }
  }

  override var isEmphasized: Bool {
    didSet { if isEmphasized != oldValue { redrawGutterCells() } }
  }

  private func redrawGutterCells() {
    for case let cell as ResultGridRowNumberCell in subviews { cell.needsDisplay = true }
  }

  override func viewWillDraw() {
    super.viewWillDraw()
    syncStrikethrough()
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
    // Selection is painted after the background and must stay the selection color.
    guard !isSelected else { return }
    if let stagingTint {
      stagingTint.setFill()
      dirtyRect.fill()
    }
    drawEditedCellTints(in: dirtyRect)
  }

  private func drawEditedCellTints(in dirtyRect: NSRect) {
    guard !editedColumns.isEmpty, let tableView = superview as? NSTableView else { return }
    let row = tableView.row(for: self)
    guard row >= 0 else { return }
    for (index, column) in tableView.tableColumns.enumerated() {
      guard let resultColumn = Int(column.identifier.rawValue),
        let tint = editedCellTint(column: resultColumn)
      else { continue }
      let frame = convert(tableView.frameOfCell(atColumn: index, row: row), from: tableView)
      let rect = frame.intersection(dirtyRect)
      guard !rect.isNull, !rect.isEmpty else { continue }
      tint.setFill()
      rect.fill()
    }
  }

  /// Strikes through every cell when the row is staged for deletion, and clears that when it is not.
  private func syncStrikethrough() {
    let deleted = stagingState == .deleted
    for case let cell as NSTableCellView in subviews {
      guard let field = cell.textField else { continue }
      let struck = Self.hasStrikethrough(field)
      if deleted {
        if !struck, !field.stringValue.isEmpty {
          field.attributedStringValue = Self.struckThrough(
            field.stringValue, font: field.font, color: field.textColor)
        }
      } else if struck {
        field.stringValue = field.stringValue
      }
    }
  }

  private static func hasStrikethrough(_ field: NSTextField) -> Bool {
    let text = field.attributedStringValue
    guard text.length > 0 else { return false }
    return text.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) != nil
  }

  private static func struckThrough(
    _ text: String, font: NSFont?, color: NSColor?
  ) -> NSAttributedString {
    var attributes: [NSAttributedString.Key: Any] = [
      .strikethroughStyle: NSUnderlineStyle.single.rawValue
    ]
    if let font { attributes[.font] = font }
    if let color { attributes[.foregroundColor] = color }
    return NSAttributedString(string: text, attributes: attributes)
  }
}
