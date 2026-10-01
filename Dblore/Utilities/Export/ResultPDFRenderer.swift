// ResultPDFRenderer.swift
// Paginated PDF of a query result already held in memory. Rows are not re-queried.

import CoreGraphics
import CoreText
import Foundation

/// Draws `result.rows` into a multi-page PDF. Core Graphics paginates; SwiftUI `ImageRenderer` does not.
nonisolated enum ResultPDFRenderer {
  /// A4 landscape, in points (72 per inch).
  static let a4Landscape = CGSize(width: 841.89, height: 595.28)

  private static let margin: CGFloat = 36
  private static let headerHeight: CGFloat = 20
  private static let rowHeight: CGFloat = 16
  private static let queryLineHeight: CGFloat = 11
  private static let queryGap: CGFloat = 8
  private static let cellPadding: CGFloat = 4
  private static let columnCap: CGFloat = 200
  private static let sampleRowLimit = 200
  private static let maxQueryLines = 12
  private static let ellipsis = "…"

  /// One PDF page stream. `query` nil or empty skips the monospaced block on the first page.
  /// `wrapText` keeps every character of a cell, breaking lines inside the column. A wrapped
  /// row continues on the next page when it is taller than the body. Off cuts the cell with "…".
  nonisolated static func render(
    result: QueryResult, title: String, query: String?,
    wrapText: Bool = false,
    pageSize: CGSize = ResultPDFRenderer.a4Landscape
  ) -> Data {
    if wrapText {
      return renderWrapped(result: result, title: title, query: query, pageSize: pageSize)
    }
    let contentWidth = max(pageSize.width - margin * 2, 1)
    let headerFont = font(named: "Helvetica-Bold", size: 9)
    let cellFont = font(named: "Helvetica", size: 9)
    let footerFont = font(named: "Helvetica", size: 8)
    let queryFont = font(named: "Courier", size: 8)
    let widths = columnWidths(
      result: result, contentWidth: contentWidth, headerFont: headerFont, cellFont: cellFont)
    let lines = queryLines(query, width: max(contentWidth - cellPadding * 2, 1), font: queryFont)
    let ranges = pageRanges(
      rowCount: result.rows.count, queryLineCount: lines.count, pageSize: pageSize)
    let exportedAt = exportStamp(Date())

    let storage = NSMutableData()
    var mediaBox = CGRect(origin: .zero, size: pageSize)
    guard let consumer = CGDataConsumer(data: storage as CFMutableData),
      let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
    else {
      return Data()
    }

    for (index, range) in ranges.enumerated() {
      context.beginPDFPage(nil)
      drawPage(
        context: context,
        result: result,
        title: title,
        queryLines: index == 0 ? lines : [],
        rows: range,
        pageNumber: index + 1,
        pageCount: ranges.count,
        exportedAt: exportedAt,
        widths: widths,
        pageSize: pageSize,
        headerFont: headerFont,
        cellFont: cellFont,
        footerFont: footerFont,
        queryFont: queryFont)
      context.endPDFPage()
    }
    context.closePDF()
    return storage as Data
  }

  // MARK: - Layout

  /// Header and the first 200 rows, capped, then scaled so the table fills the content width.
  private static func columnWidths(
    result: QueryResult, contentWidth: CGFloat, headerFont: CTFont, cellFont: CTFont
  ) -> [CGFloat] {
    let count = result.columns.count
    guard count > 0 else { return [] }

    var natural = [CGFloat](repeating: 0, count: count)
    for index in 0..<count {
      var widest = textWidth(result.columns[index].name, font: headerFont)
      for row in result.rows.prefix(sampleRowLimit) {
        guard index < row.count else { continue }
        widest = max(widest, textWidth(cellText(row[index]), font: cellFont))
      }
      let padded = widest + cellPadding * 2
      natural[index] = min(max(padded, 12), columnCap)
    }

    let sum = natural.reduce(0, +)
    guard sum > 0 else {
      return Array(repeating: contentWidth / CGFloat(count), count: count)
    }
    let scale = contentWidth / sum
    var scaled = natural.map { $0 * scale }
    scaled[count - 1] += contentWidth - scaled.reduce(0, +)
    if scaled[count - 1] < 0 {
      scaled[count - 1] = 0
    }
    return scaled
  }

  /// Average Helvetica 9-point advance. Size checks use it. Drawing measures real glyphs.
  static let estimatedCharWidth: CGFloat = 5

  /// How many pages `visualLineCount` table lines need. One empty page when there are no lines.
  static func pageCount(visualLineCount: Int, query: String?) -> Int {
    pageRanges(
      rowCount: max(visualLineCount, 0),
      queryLineCount: cappedQueryLineCount(query),
      pageSize: a4Landscape
    ).count
  }

  /// Column widths from character counts, capped and scaled like `columnWidths(result:...)`.
  static func columnWidths(forCharCounts counts: [Int]) -> [CGFloat] {
    let count = counts.count
    let contentWidth = max(a4Landscape.width - margin * 2, 1)
    guard count > 0 else { return [] }
    let natural = counts.map { chars -> CGFloat in
      let padded = CGFloat(chars) * estimatedCharWidth + cellPadding * 2
      return min(max(padded, 12), columnCap)
    }
    let sum = natural.reduce(0, +)
    guard sum > 0 else {
      return Array(repeating: contentWidth / CGFloat(count), count: count)
    }
    let scale = contentWidth / sum
    var scaled = natural.map { $0 * scale }
    scaled[count - 1] += contentWidth - scaled.reduce(0, +)
    if scaled[count - 1] < 0 {
      scaled[count - 1] = 0
    }
    return scaled
  }

  static func charsPerLine(columnWidth: CGFloat) -> Int {
    let usable = columnWidth - cellPadding * 2
    return max(Int((usable / estimatedCharWidth).rounded(.down)), 1)
  }

  /// Lines a wrapped cell would occupy. Spaces and glyph widths are ignored.
  static func estimatedWrappedLines(_ text: String, charsPerLine: Int) -> Int {
    let per = max(charsPerLine, 1)
    if text.isEmpty {
      return 1
    }
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    var lines = 0
    for paragraph in normalized.components(separatedBy: "\n") {
      if paragraph.isEmpty {
        lines += 1
      } else {
        lines += (paragraph.count + per - 1) / per
      }
    }
    return max(lines, 1)
  }

  private static func cappedQueryLineCount(_ query: String?) -> Int {
    guard let query, !query.isEmpty else { return 0 }
    return min(query.components(separatedBy: "\n").count, maxQueryLines)
  }

  private static func pageRanges(
    rowCount: Int, queryLineCount: Int, pageSize: CGSize
  ) -> [Range<Int>] {
    if rowCount == 0 {
      return [0..<0]
    }
    var ranges: [Range<Int>] = []
    var start = 0
    var firstPage = true
    while start < rowCount {
      let lines = firstPage ? queryLineCount : 0
      let capacity = max(rowCapacity(pageSize: pageSize, queryLineCount: lines), 1)
      let end = min(start + capacity, rowCount)
      ranges.append(start..<end)
      start = end
      firstPage = false
    }
    return ranges
  }

  private static func rowCapacity(pageSize: CGSize, queryLineCount: Int) -> Int {
    var available = pageSize.height - margin * 2 - headerHeight
    if queryLineCount > 0 {
      available -= CGFloat(queryLineCount) * queryLineHeight + queryGap
    }
    guard available > 0 else { return 0 }
    return Int(available / rowHeight)
  }

  private static func queryLines(_ query: String?, width: CGFloat, font: CTFont) -> [String] {
    guard let query, !query.isEmpty else { return [] }
    return query.components(separatedBy: "\n").prefix(maxQueryLines).map { line in
      fitting(line, font: font, width: width)
    }
  }

  // MARK: - Drawing

  private static func drawPage(
    context: CGContext,
    result: QueryResult,
    title: String,
    queryLines: [String],
    rows: Range<Int>,
    pageNumber: Int,
    pageCount: Int,
    exportedAt: String,
    widths: [CGFloat],
    pageSize: CGSize,
    headerFont: CTFont,
    cellFont: CTFont,
    footerFont: CTFont,
    queryFont: CTFont
  ) {
    let contentWidth = max(pageSize.width - margin * 2, 1)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(origin: .zero, size: pageSize))

    var top = pageSize.height - margin
    if !queryLines.isEmpty {
      top -= drawQuery(queryLines, top: top, width: contentWidth, font: queryFont, context: context)
    }
    if !widths.isEmpty {
      drawTable(
        context: context, result: result, rows: rows, widths: widths, top: top,
        headerFont: headerFont,
        cellFont: cellFont)
    }
    drawFooter(
      title: title, pageNumber: pageNumber, pageCount: pageCount, exportedAt: exportedAt,
      width: contentWidth, font: footerFont, context: context)
  }

  private static func drawQuery(
    _ lines: [String], top: CGFloat, width: CGFloat, font: CTFont, context: CGContext
  ) -> CGFloat {
    let height = CGFloat(lines.count) * queryLineHeight
    context.setFillColor(CGColor(gray: 0.96, alpha: 1))
    context.fill(CGRect(x: margin, y: top - height, width: width, height: height))
    var lineTop = top
    let color = CGColor(gray: 0.12, alpha: 1)
    for line in lines {
      let rect = CGRect(
        x: margin, y: lineTop - queryLineHeight, width: width, height: queryLineHeight)
      draw(line, in: rect, font: font, color: color, context: context)
      lineTop -= queryLineHeight
    }
    return height + queryGap
  }

  private static func drawTable(
    context: CGContext,
    result: QueryResult,
    rows: Range<Int>,
    widths: [CGFloat],
    top: CGFloat,
    headerFont: CTFont,
    cellFont: CTFont
  ) {
    let tableWidth = widths.reduce(0, +)
    let left = margin
    let headerRect = CGRect(x: left, y: top - headerHeight, width: tableWidth, height: headerHeight)
    context.setFillColor(CGColor(gray: 0.93, alpha: 1))
    context.fill(headerRect)

    var x = left
    for (index, width) in widths.enumerated() {
      let rect = CGRect(x: x, y: headerRect.minY, width: width, height: headerHeight)
      let name = index < result.columns.count ? result.columns[index].name : ""
      draw(
        fitting(name, font: headerFont, width: max(width - cellPadding * 2, 0)),
        in: rect, font: headerFont, color: CGColor(gray: 0, alpha: 1), context: context)
      x += width
    }

    var rowTop = headerRect.minY
    let textColor = CGColor(gray: 0.05, alpha: 1)
    for rowIndex in rows {
      let row = result.rows[rowIndex]
      let rectY = rowTop - rowHeight
      x = left
      for (index, width) in widths.enumerated() {
        let rect = CGRect(x: x, y: rectY, width: width, height: rowHeight)
        let raw = index < row.count ? cellText(row[index]) : ""
        draw(
          fitting(raw, font: cellFont, width: max(width - cellPadding * 2, 0)),
          in: rect, font: cellFont, color: textColor, context: context)
        x += width
      }
      rowTop = rectY
    }

    strokeGrid(
      context: context, left: left, top: top, bottom: rowTop, width: tableWidth, widths: widths,
      rowCount: rows.count)
  }

  private static func strokeGrid(
    context: CGContext, left: CGFloat, top: CGFloat, bottom: CGFloat, width: CGFloat,
    widths: [CGFloat],
    rowCount: Int
  ) {
    context.setStrokeColor(CGColor(gray: 0.72, alpha: 1))
    context.setLineWidth(0.4)
    let right = left + width
    func horizontal(_ y: CGFloat) {
      context.move(to: CGPoint(x: left, y: y))
      context.addLine(to: CGPoint(x: right, y: y))
    }
    horizontal(top)
    var y = top - headerHeight
    horizontal(y)
    for _ in 0..<rowCount {
      y -= rowHeight
      horizontal(y)
    }
    func vertical(_ x: CGFloat) {
      context.move(to: CGPoint(x: x, y: bottom))
      context.addLine(to: CGPoint(x: x, y: top))
    }
    var x = left
    vertical(x)
    for column in widths {
      x += column
      vertical(x)
    }
    context.strokePath()
  }

  private static func drawFooter(
    title: String, pageNumber: Int, pageCount: Int, exportedAt: String, width: CGFloat,
    font: CTFont,
    context: CGContext
  ) {
    let label = "\(title)    \(pageNumber) / \(pageCount)    \(exportedAt)"
    let rect = CGRect(x: margin, y: 14, width: width, height: 14)
    draw(
      fitting(label, font: font, width: max(width - cellPadding * 2, 0)),
      in: rect, font: font, color: CGColor(gray: 0.28, alpha: 1), context: context)
  }

  private static func draw(
    _ text: String, in rect: CGRect, font: CTFont, color: CGColor, context: CGContext
  ) {
    guard !text.isEmpty else { return }
    let line = textLine(text, font: font, color: color)
    let ascent = CTFontGetAscent(font)
    let descent = CTFontGetDescent(font)
    let baseline = rect.minY + (rect.height - ascent - descent) / 2 + descent
    context.saveGState()
    context.clip(to: rect)
    context.textMatrix = .identity
    context.translateBy(x: rect.minX + cellPadding, y: baseline)
    CTLineDraw(line, context)
    context.restoreGState()
  }

  // MARK: - Text measurement

  /// Same cases as `CellValue.fullString`. That property is MainActor-isolated, so the PDF path
  /// reads the value here and stays callable off the main actor.
  private static func cellText(_ value: CellValue) -> String {
    switch value {
    case .string(let text):
      return text
    case .int(let number):
      return String(number)
    case .double(let number):
      return String(number)
    case .bool(let flag):
      return flag ? "true" : "false"
    case .null:
      return "NULL"
    case .json(let text):
      return text
    case .date(let date):
      return ISO8601DateFormatter().string(from: date)
    case .data(let data):
      return data.base64EncodedString()
    }
  }

  /// Single-line width from a `CTLine`, widened to the `CTFramesetter` suggestion when that is larger.
  private static func textWidth(_ text: String, font: CTFont) -> CGFloat {
    let flat = singleLine(text)
    guard !flat.isEmpty else { return 0 }
    let value = attributed(flat, font: font, color: CGColor(gray: 0, alpha: 1))
    let line = CTLineCreateWithAttributedString(value)
    let measured = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    let setter = CTFramesetterCreateWithAttributedString(value)
    var fit = CFRange()
    let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
      setter,
      CFRange(location: 0, length: 0),
      nil,
      CGSize(width: 100_000, height: 400),
      &fit)
    return max(measured, suggested.width)
  }

  /// Cell text flattened to one line, cut with an ellipsis so the glyphs stay inside `width`.
  private static func fitting(_ text: String, font: CTFont, width: CGFloat) -> String {
    let flat = singleLine(text)
    if flat.isEmpty || width <= 0 {
      return ""
    }
    if textWidth(flat, font: font) <= width {
      return flat
    }
    if textWidth(ellipsis, font: font) > width {
      return ""
    }
    let characters = Array(flat)
    var low = 0
    var high = characters.count
    while low < high {
      let mid = (low + high + 1) / 2
      let candidate = String(characters.prefix(mid)) + ellipsis
      if textWidth(candidate, font: font) <= width {
        low = mid
      } else {
        high = mid - 1
      }
    }
    return String(characters.prefix(low)) + ellipsis
  }

  private static func singleLine(_ text: String) -> String {
    guard text.contains(where: \.isNewline) else { return text }
    return text.replacingOccurrences(of: "\r\n", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
  }

  private static func textLine(_ text: String, font: CTFont, color: CGColor) -> CTLine {
    CTLineCreateWithAttributedString(attributed(text, font: font, color: color))
  }

  private static func attributed(_ text: String, font: CTFont, color: CGColor) -> CFAttributedString
  {
    let attributes =
      [
        kCTFontAttributeName: font,
        kCTForegroundColorAttributeName: color,
      ] as CFDictionary
    return CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attributes)!
  }

  private static func font(named name: String, size: CGFloat) -> CTFont {
    CTFontCreateWithName(name as CFString, size, nil)
  }

  private static func exportStamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }

  // MARK: - Wrapped rows

  /// Lines of `text` that fit in `width`. Exposed for tests. A space at a break is not kept.
  static func wrappedLines(_ text: String, width: CGFloat) -> [String] {
    wrapLines(text, font: font(named: "Helvetica", size: 9), width: width)
  }

  private struct VisualLine {
    var row: Int
    var line: Int
    var closesRow: Bool
  }

  private static func renderWrapped(
    result: QueryResult, title: String, query: String?, pageSize: CGSize
  ) -> Data {
    let contentWidth = max(pageSize.width - margin * 2, 1)
    let headerFont = font(named: "Helvetica-Bold", size: 9)
    let cellFont = font(named: "Helvetica", size: 9)
    let footerFont = font(named: "Helvetica", size: 8)
    let queryFont = font(named: "Courier", size: 8)
    let widths = columnWidths(
      result: result, contentWidth: contentWidth, headerFont: headerFont, cellFont: cellFont)
    let queryBlock = queryLines(
      query, width: max(contentWidth - cellPadding * 2, 1), font: queryFont)
    let matrix = wrappedMatrix(result: result, widths: widths, font: cellFont)
    let visual = visualLines(matrix)
    let ranges = pageRanges(
      rowCount: visual.count, queryLineCount: queryBlock.count, pageSize: pageSize)
    let exportedAt = exportStamp(Date())

    let storage = NSMutableData()
    var mediaBox = CGRect(origin: .zero, size: pageSize)
    guard let consumer = CGDataConsumer(data: storage as CFMutableData),
      let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
    else {
      return Data()
    }

    for (index, range) in ranges.enumerated() {
      context.beginPDFPage(nil)
      drawWrappedPage(
        context: context,
        result: result,
        title: title,
        queryLines: index == 0 ? queryBlock : [],
        matrix: matrix,
        visual: Array(visual[range]),
        pageNumber: index + 1,
        pageCount: ranges.count,
        exportedAt: exportedAt,
        widths: widths,
        pageSize: pageSize,
        headerFont: headerFont,
        cellFont: cellFont,
        footerFont: footerFont,
        queryFont: queryFont)
      context.endPDFPage()
    }
    context.closePDF()
    return storage as Data
  }

  private static func wrappedMatrix(
    result: QueryResult, widths: [CGFloat], font: CTFont
  ) -> [[[String]]] {
    result.rows.map { row in
      widths.indices.map { index in
        let raw = index < row.count ? cellText(row[index]) : ""
        let width = max(widths[index] - cellPadding * 2, 0)
        return wrapLines(raw, font: font, width: width)
      }
    }
  }

  private static func visualLines(_ matrix: [[[String]]]) -> [VisualLine] {
    var lines: [VisualLine] = []
    for (row, cells) in matrix.enumerated() {
      let count = max(cells.map(\.count).max() ?? 1, 1)
      for line in 0..<count {
        lines.append(VisualLine(row: row, line: line, closesRow: line == count - 1))
      }
    }
    return lines
  }

  private static func drawWrappedPage(
    context: CGContext,
    result: QueryResult,
    title: String,
    queryLines: [String],
    matrix: [[[String]]],
    visual: [VisualLine],
    pageNumber: Int,
    pageCount: Int,
    exportedAt: String,
    widths: [CGFloat],
    pageSize: CGSize,
    headerFont: CTFont,
    cellFont: CTFont,
    footerFont: CTFont,
    queryFont: CTFont
  ) {
    let contentWidth = max(pageSize.width - margin * 2, 1)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(origin: .zero, size: pageSize))

    var top = pageSize.height - margin
    if !queryLines.isEmpty {
      top -= drawQuery(
        queryLines, top: top, width: contentWidth, font: queryFont, context: context)
    }
    if !widths.isEmpty {
      drawWrappedTable(
        context: context, result: result, matrix: matrix, visual: visual, widths: widths,
        top: top, headerFont: headerFont, cellFont: cellFont)
    }
    drawFooter(
      title: title, pageNumber: pageNumber, pageCount: pageCount, exportedAt: exportedAt,
      width: contentWidth, font: footerFont, context: context)
  }

  private static func drawWrappedTable(
    context: CGContext,
    result: QueryResult,
    matrix: [[[String]]],
    visual: [VisualLine],
    widths: [CGFloat],
    top: CGFloat,
    headerFont: CTFont,
    cellFont: CTFont
  ) {
    let tableWidth = widths.reduce(0, +)
    let left = margin
    let headerRect = CGRect(x: left, y: top - headerHeight, width: tableWidth, height: headerHeight)
    context.setFillColor(CGColor(gray: 0.93, alpha: 1))
    context.fill(headerRect)

    var x = left
    for (index, width) in widths.enumerated() {
      let rect = CGRect(x: x, y: headerRect.minY, width: width, height: headerHeight)
      let name = index < result.columns.count ? result.columns[index].name : ""
      draw(
        fitting(name, font: headerFont, width: max(width - cellPadding * 2, 0)),
        in: rect, font: headerFont, color: CGColor(gray: 0, alpha: 1), context: context)
      x += width
    }

    var rowTop = headerRect.minY
    var rules = [top, headerRect.minY]
    let textColor = CGColor(gray: 0.05, alpha: 1)
    for (offset, item) in visual.enumerated() {
      let rectY = rowTop - rowHeight
      x = left
      let cells = item.row < matrix.count ? matrix[item.row] : []
      for (index, width) in widths.enumerated() {
        let rect = CGRect(x: x, y: rectY, width: width, height: rowHeight)
        let text: String
        if index < cells.count, item.line < cells[index].count {
          text = cells[index][item.line]
        } else {
          text = ""
        }
        draw(text, in: rect, font: cellFont, color: textColor, context: context)
        x += width
      }
      rowTop = rectY
      if item.closesRow || offset == visual.count - 1, rules.last != rowTop {
        rules.append(rowTop)
      }
    }
    strokeWrappedGrid(context: context, left: left, rules: rules, widths: widths)
  }

  private static func strokeWrappedGrid(
    context: CGContext, left: CGFloat, rules: [CGFloat], widths: [CGFloat]
  ) {
    guard let bottom = rules.min(), let top = rules.max() else { return }
    context.setStrokeColor(CGColor(gray: 0.72, alpha: 1))
    context.setLineWidth(0.4)
    let tableWidth = widths.reduce(0, +)
    let right = left + tableWidth
    for y in rules {
      context.move(to: CGPoint(x: left, y: y))
      context.addLine(to: CGPoint(x: right, y: y))
    }
    var x = left
    context.move(to: CGPoint(x: x, y: bottom))
    context.addLine(to: CGPoint(x: x, y: top))
    for column in widths {
      x += column
      context.move(to: CGPoint(x: x, y: bottom))
      context.addLine(to: CGPoint(x: x, y: top))
    }
    context.strokePath()
  }

  private static func wrapLines(_ text: String, font: CTFont, width: CGFloat) -> [String] {
    if width <= 0 {
      return [text]
    }
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    var lines: [String] = []
    for paragraph in normalized.components(separatedBy: "\n") {
      if paragraph.isEmpty {
        lines.append("")
        continue
      }
      lines.append(contentsOf: wrapParagraph(paragraph, font: font, width: width))
    }
    return lines.isEmpty ? [""] : lines
  }

  private static func wrapParagraph(_ text: String, font: CTFont, width: CGFloat) -> [String] {
    var lines: [String] = []
    var current = ""
    for token in tokensOf(text) {
      for piece in hardBreak(token, font: font, width: width) {
        if current.isEmpty {
          let start = piece.trimmingCharacters(in: .whitespaces)
          if !start.isEmpty {
            current = start
          }
          continue
        }
        if textWidth(current + piece, font: font) <= width {
          current += piece
        } else {
          lines.append(trimTrailingSpaces(current))
          current = piece.trimmingCharacters(in: .whitespaces)
        }
      }
    }
    if !current.isEmpty {
      lines.append(trimTrailingSpaces(current))
    }
    return lines.isEmpty ? [""] : lines
  }

  /// Words with the space that followed them. A space is the wrap opportunity.
  private static func tokensOf(_ text: String) -> [String] {
    var tokens: [String] = []
    var current = ""
    for character in text {
      current.append(character)
      if character.isWhitespace {
        tokens.append(current)
        current = ""
      }
    }
    if !current.isEmpty {
      tokens.append(current)
    }
    return tokens
  }

  /// Splits a token that is wider than the column so no character is dropped.
  private static func hardBreak(_ token: String, font: CTFont, width: CGFloat) -> [String] {
    if token.isEmpty {
      return []
    }
    if textWidth(token, font: font) <= width {
      return [token]
    }
    let chars = Array(token)
    var parts: [String] = []
    var index = 0
    while index < chars.count {
      var low = 1
      var high = chars.count - index
      while low < high {
        let mid = (low + high + 1) / 2
        let slice = String(chars[index..<(index + mid)])
        if textWidth(slice, font: font) <= width {
          low = mid
        } else {
          high = mid - 1
        }
      }
      if low < 1 {
        low = 1
      }
      parts.append(String(chars[index..<(index + low)]))
      index += low
    }
    return parts
  }

  private static func trimTrailingSpaces(_ text: String) -> String {
    var end = text.endIndex
    while end > text.startIndex {
      let previous = text.index(before: end)
      if !text[previous].isWhitespace {
        break
      }
      end = previous
    }
    return String(text[..<end])
  }
}
