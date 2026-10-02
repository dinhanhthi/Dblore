//
//  ResultGridHeaderCell.swift
//  Dblore
//
//  Two-line header cell of the result grid, as in the old result table: the column name
//  (yellow key before it for a primary-key column, search highlight on a column-name match)
//  over the column type in a smaller muted font. The coordinator decides the content
//  (ResultGridHeaderContent); the cell only draws it, plus the sort indicator and the
//  filter icon on the type line.
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
  /// Header of the "#" row number column: muted title, right-aligned
  var isRowNumber = false
  /// A category filter is hiding at least one value of this column
  var isFiltered = false
}

final class ResultGridHeaderCell: NSTableHeaderCell {
  static let titleFont = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
  /// Smaller than `Font.small` (subheadline, 11pt)
  static let typeFont = NSFont.systemFont(ofSize: 10)
  static let typeColor = NSColor(Color.foregroundSubtle)
  static let keyColor = NSColor(Color.warning)
  /// Side of the filter icon's hit target, on the type line under the sort indicator
  static let filterButtonSide: CGFloat = 16

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
    if content.isRowNumber {
      let bounds = controlView.bounds
      ResultGridRowNumberCell.drawGutter(
        in: NSRect(x: cellFrame.minX, y: bounds.minY, width: cellFrame.width, height: bounds.height)
      )
    }
    let indicator = sortIndicatorRect(forBounds: cellFrame)
    let filterButton = filterButtonRect(columnRect: cellFrame, headerBounds: controlView.bounds)
    let span = textSpan(columnRect: cellFrame, headerBounds: controlView.bounds)
    let titleHeight = Self.titleFont.ascender - Self.titleFont.descender
    let typeHeight = Self.typeFont.ascender - Self.typeFont.descender
    // Lines centered over the full header height (cellFrame is a one-line strip)
    let top = Self.linesTop(in: controlView.bounds, hasType: content.type != nil)
    if let tableView = (controlView as? NSTableHeaderView)?.tableView,
      let column = tableView.tableColumns.first(where: { $0.headerCell === self }),
      let ascending = Self.sortAscending(for: column, in: tableView)
    {
      drawSortArrow(ascending: ascending, centerX: indicator.midX, centerY: top + titleHeight / 2)
    }
    if let filterButton {
      drawFilterIcon(in: filterButton, active: content.isFiltered)
    }
    var titleX = span.minX
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
      in: NSRect(x: titleX, y: top, width: max(0, span.maxX - titleX), height: titleHeight))
    if let type = content.type {
      draw(
        NSAttributedString(
          string: type, attributes: [.font: Self.typeFont, .foregroundColor: Self.typeColor]),
        in: NSRect(
          x: span.minX, y: top + titleHeight + Spacing.xxs,
          width: max(0, span.maxX - span.minX), height: typeHeight))
    }
  }

  /// Width of the name and type text inside a header of `columnWidth`, before the key icon
  func lineSpanWidth(columnWidth: CGFloat) -> CGFloat {
    let rect = NSRect(x: 0, y: 0, width: columnWidth, height: 44)
    let span = textSpan(columnRect: rect, headerBounds: rect)
    return max(0, span.maxX - span.minX)
  }

  /// Width of the name line inside a header of `columnWidth`, after the key icon
  func nameLineWidth(columnWidth: CGFloat) -> CGFloat {
    var width = lineSpanWidth(columnWidth: columnWidth)
    if content.isPrimaryKey, let key = Self.keyImage() {
      width = max(0, width - key.size.width - Spacing.xs)
    }
    return width
  }

  /// Width that shows the name (with the key icon) and the type untruncated, with room for the
  /// sort indicator and the filter icon so neither truncates the name
  func fittingWidth() -> CGFloat {
    // The reserved trailing column does not depend on the header width, so measure it once
    // on a wide sample and add the text.
    let sampleWidth: CGFloat = 200
    let sample = NSRect(x: 0, y: 0, width: sampleWidth, height: 44)
    let sampleSpan = textSpan(columnRect: sample, headerBounds: sample)
    let chrome = sampleWidth - max(0, sampleSpan.maxX - sampleSpan.minX)
    var nameWidth = (content.title as NSString).size(withAttributes: [.font: Self.titleFont])
      .width
    if content.isPrimaryKey, let key = Self.keyImage() {
      nameWidth += key.size.width + Spacing.xs
    }
    let typeWidth =
      content.type.map {
        ($0 as NSString).size(withAttributes: [.font: Self.typeFont]).width
      } ?? 0
    // One extra point: a line that measures equal to its rect still tail-truncates
    return ceil(chrome + max(nameWidth, typeWidth)) + 1
  }

  /// Horizontal limits of the name and type text. The filter icon sits on the type line,
  /// centered on the sort indicator, so it extends past that indicator and the name line
  /// stops at the icon, not at the indicator.
  private func textSpan(columnRect: NSRect, headerBounds: NSRect) -> (minX: CGFloat, maxX: CGFloat)
  {
    let minX = columnRect.minX + Spacing.xsm
    guard !content.isRowNumber else { return (minX, columnRect.maxX - Spacing.xsm) }
    let indicator = sortIndicatorRect(forBounds: columnRect)
    let filterMinX = filterButtonRect(columnRect: columnRect, headerBounds: headerBounds)?.minX
    let reserved = min(indicator.minX, filterMinX ?? indicator.minX)
    return (minX, max(minX, reserved - Spacing.xs))
  }

  /// Hit target of the filter icon, in the header view's coordinates. On the type line, under
  /// the sort arrow. Nil for the row-number gutter. Without a type line it sits just left of
  /// the sort indicator so the two don't overlap in the short header.
  func filterButtonRect(columnRect: NSRect, headerBounds: NSRect) -> NSRect? {
    guard !content.isRowNumber else { return nil }
    let indicator = sortIndicatorRect(forBounds: columnRect)
    guard indicator.width > 1 else { return nil }
    let side = Self.filterButtonSide
    let centerX: CGFloat
    let centerY: CGFloat
    if content.type != nil {
      centerX = indicator.midX
      let top = Self.linesTop(in: headerBounds, hasType: true)
      let titleHeight = Self.titleFont.ascender - Self.titleFont.descender
      let typeHeight = Self.typeFont.ascender - Self.typeFont.descender
      centerY = top + titleHeight + Spacing.xxs + typeHeight / 2
    } else {
      centerX = indicator.minX - Spacing.xs - side / 2
      centerY = headerBounds.midY
    }
    return NSRect(x: centerX - side / 2, y: centerY - side / 2, width: side, height: side)
  }

  // MARK: - Private

  private func title() -> NSAttributedString {
    if content.isRowNumber {
      let paragraph = NSMutableParagraphStyle()
      paragraph.alignment = .right
      return NSAttributedString(
        string: content.title,
        attributes: [
          .font: ResultGridCoordinator.rowNumberFont,
          .foregroundColor: ResultGridRowNumberCell.textColor, .paragraphStyle: paragraph,
        ])
    }
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
    guard rect.width > 0, text.length > 0 else { return }
    let string = NSMutableAttributedString(attributedString: text)
    let paragraph =
      (text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?
      .mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    string.addAttribute(
      .paragraphStyle, value: paragraph, range: NSRange(location: 0, length: string.length))
    string.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
  }

  /// Filter icon in the indicator column. Accent when this column is hiding values.
  private func drawFilterIcon(in rect: NSRect, active: Bool) {
    let color = active ? NSColor(Color.accent) : Self.typeColor
    guard
      let image = NSImage(
        systemSymbolName: "line.3.horizontal.decrease",
        accessibilityDescription: active ? "Column filtered" : "Filter column")?
        .withSymbolConfiguration(
          NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color])))
    else { return }
    let size = image.size
    image.draw(
      in: NSRect(
        x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width,
        height: size.height),
      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
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
