//
//  ResultGridHeaderCell.swift
//  SQLNotebook
//
//  Two-line header cell of the result grid, as in the old result table: the column name
//  (yellow key before it for a primary-key column, search highlight on a column-name match)
//  over the column type in a smaller muted font. The coordinator decides the content
//  (ResultGridHeaderContent); the cell only draws it, plus the table's sort indicator.
//

import AppKit
import SwiftUI

/// What a header cell shows for one column, built by `ResultGridCoordinator.headerContent`
struct ResultGridHeaderContent: Equatable {
  var title = ""
  /// Column type (line 2); nil when column types are hidden
  var type: String?
  /// Primary-key column of a result with a live edit target (key icon)
  var isPrimaryKey = false
  /// The column name contains the search query
  var isHighlighted = false
  /// The current search match is this column's name
  var isCurrentMatch = false
  var searchQuery = ""
  var caseSensitive = false
}

final class ResultGridHeaderCell: NSTableHeaderCell {
  static let titleFont = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
  /// Same size as `Font.small` (subheadline)
  static let typeFont = NSFont.preferredFont(forTextStyle: .subheadline)
  static let typeColor = NSColor(Color.foregroundSubtle)
  static let keyColor = NSColor(Color.warning)

  var content = ResultGridHeaderContent()

  /// NSCell copies with NSCopyObject: Swift stored properties come back unretained, so the
  /// copy's `content` is initialized in place (no release of the bitwise-copied value)
  override func copy(with zone: NSZone? = nil) -> Any {
    let copy = super.copy(with: zone)
    if let cell = copy as? ResultGridHeaderCell {
      withUnsafeMutablePointer(to: &cell.content) { $0.initialize(to: content) }
    }
    return copy
  }

  /// Direction of the table's sort on `column` (the first sort descriptor), nil when the
  /// table isn't sorted by it
  static func sortAscending(for column: NSTableColumn, in tableView: NSTableView) -> Bool? {
    guard let sort = tableView.sortDescriptors.first, let key = sort.key,
      key == column.sortDescriptorPrototype?.key
    else { return nil }
    return sort.ascending
  }

  /// Draws the interior only: the header view draws the background, and super would add a
  /// separator line at a fixed height, right under the type line of the taller header
  override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
    drawInterior(withFrame: cellFrame, in: controlView)
  }

  /// Top of the first line so the ink (cap top of the name to the baseline of the last line) is
  /// centered in `bounds`: the same gap above and below
  static func linesTop(in bounds: NSRect, hasType: Bool) -> CGFloat {
    let titleHeight = titleFont.ascender - titleFont.descender
    let typeHeight = typeFont.ascender - typeFont.descender
    let totalHeight = titleHeight + (hasType ? Spacing.xxs + typeHeight : 0)
    let aboveInk = titleFont.ascender - titleFont.capHeight
    let belowInk = -(hasType ? typeFont.descender : titleFont.descender)
    let inkHeight = totalHeight - aboveInk - belowInk
    return bounds.minY + (bounds.height - inkHeight) / 2 - aboveInk
  }

  /// Draws the name and type lines over the full header height and the sort indicator; super
  /// (not called) would draw a one-line title.
  override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
    // AppKit draws the filler after the last column with a copy that has no title
    guard !stringValue.isEmpty else { return }
    var textFrame = cellFrame.insetBy(dx: Spacing.xsm, dy: 0)
    var sortArrow: (ascending: Bool, rect: NSRect)?
    if let tableView = (controlView as? NSTableHeaderView)?.tableView,
      let column = tableView.tableColumns.first(where: { $0.headerCell === self }),
      let ascending = Self.sortAscending(for: column, in: tableView)
    {
      sortArrow = (ascending, sortIndicatorRect(forBounds: cellFrame))
      textFrame.size.width =
        sortIndicatorRect(forBounds: cellFrame).minX - Spacing.xs - textFrame.minX
    }
    let titleHeight = Self.titleFont.ascender - Self.titleFont.descender
    let typeHeight = Self.typeFont.ascender - Self.typeFont.descender
    // Lines centered over the full header height (cellFrame is a one-line strip)
    let top = Self.linesTop(in: controlView.bounds, hasType: content.type != nil)
    if let (ascending, rect) = sortArrow {
      drawSortArrow(ascending: ascending, centerX: rect.midX, centerY: top + titleHeight / 2)
    }
    var titleX = textFrame.minX
    if content.isPrimaryKey, let key = Self.keyImage() {
      let size = key.size
      key.draw(
        in: NSRect(
          x: titleX, y: top + (titleHeight - size.height) / 2, width: size.width,
          height: size.height),
        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
      titleX += size.width + Spacing.xs
    }
    draw(
      title(),
      in: NSRect(x: titleX, y: top, width: textFrame.maxX - titleX, height: titleHeight))
    if let type = content.type {
      draw(
        NSAttributedString(
          string: type, attributes: [.font: Self.typeFont, .foregroundColor: Self.typeColor]),
        in: NSRect(
          x: textFrame.minX, y: top + titleHeight + Spacing.xxs, width: textFrame.width,
          height: typeHeight))
    }
  }

  // MARK: - Private

  private func title() -> NSAttributedString {
    guard content.isHighlighted else {
      return NSAttributedString(
        string: content.title,
        attributes: [.font: Self.titleFont, .foregroundColor: ResultGridCoordinator.textColor])
    }
    return ResultGridCoordinator.highlighted(
      content.title, query: content.searchQuery, caseSensitive: content.caseSensitive,
      font: Self.titleFont, textColor: ResultGridCoordinator.textColor,
      isCurrentMatch: content.isCurrentMatch)
  }

  /// One line, truncated at the tail
  private func draw(_ text: NSAttributedString, in rect: NSRect) {
    guard rect.width > 0 else { return }
    let string = NSMutableAttributedString(attributedString: text)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    string.addAttribute(
      .paragraphStyle, value: paragraph, range: NSRange(location: 0, length: string.length))
    string.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
  }

  /// Sort chevron in the app accent color, centered on the name line
  private func drawSortArrow(ascending: Bool, centerX: CGFloat, centerY: CGFloat) {
    guard
      let image = NSImage(
        systemSymbolName: ascending ? "chevron.up" : "chevron.down",
        accessibilityDescription: ascending ? "Sorted ascending" : "Sorted descending")?
        .withSymbolConfiguration(
          NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(Color.accent)])))
    else { return }
    let size = image.size
    image.draw(
      in: NSRect(
        x: centerX - size.width / 2, y: centerY - size.height / 2, width: size.width,
        height: size.height),
      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
  }

  private static func keyImage() -> NSImage? {
    NSImage(systemSymbolName: "key.fill", accessibilityDescription: "Primary key")?
      .withSymbolConfiguration(
        NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
          .applying(NSImage.SymbolConfiguration(paletteColors: [keyColor])))
  }
}
