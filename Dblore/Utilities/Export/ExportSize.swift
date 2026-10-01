// ExportSize.swift
// Approximate download size before the file is built. PDF word wrap is counted in
// pages, because a wrapped cell keeps every character and can run to many pages.

import Foundation

struct ExportSizeEstimate: Equatable, Sendable {
  /// Soft limit. Past this, the sheet asks before building the file.
  static let largeByteCount = 20 * 1024 * 1024
  /// A landscape page holds about 30 table lines. Fifty pages is already slow to open.
  static let largePageCount = 50

  var bytes: Int
  /// Set for PDF. Nil for text and Excel.
  var pageCount: Int?
  /// PDF word wrap is what pushed the page count over the limit.
  var warnsAboutWrap: Bool

  var isLarge: Bool {
    bytes >= Self.largeByteCount || (pageCount ?? 0) >= Self.largePageCount
  }

  var summary: String {
    let size = ByteCountFormatter.string(fromByteCount: Int64(max(bytes, 0)), countStyle: .file)
    guard let pageCount else { return "About \(size)" }
    let noun = pageCount == 1 ? "page" : "pages"
    return "About \(size) · \(pageCount.formatted()) \(noun)"
  }

  var warning: String? {
    guard isLarge else { return nil }
    if warnsAboutWrap {
      return
        "Word wrap keeps the full text of every cell, so this PDF can take a long time to build and open."
    }
    return "This file is large enough that saving and opening it may take a while."
  }

  var confirmMessage: String {
    guard let warning else { return summary + "." }
    return summary + ". " + warning
  }
}

enum ExportSize {
  static func estimate(result: CellResult, options: ExportOptions) -> ExportSizeEstimate {
    switch options.format {
    case .pdf:
      return pdf(result: result, options: options)
    case .csv, .excel, .json, .markdown, .sqlInsert:
      let bytes = textBytes(result: result, options: options)
      return ExportSizeEstimate(bytes: bytes, pageCount: nil, warnsAboutWrap: false)
    }
  }

  private static func pdf(result: CellResult, options: ExportOptions) -> ExportSizeEstimate {
    let texts = exportedTexts(result: result, options: options)
    let pages: Int
    let bytes: Int
    if options.wrapText {
      let widths = ResultPDFRenderer.columnWidths(forCharCounts: maxChars(texts))
      var lines = 0
      var textBytes = 0
      for row in texts {
        var rowLines = 1
        for (index, text) in row.enumerated() {
          textBytes += text.utf8.count
          let per =
            index < widths.count
            ? ResultPDFRenderer.charsPerLine(columnWidth: widths[index])
            : 1
          rowLines = max(rowLines, ResultPDFRenderer.estimatedWrappedLines(text, charsPerLine: per))
        }
        lines += rowLines
      }
      pages = ResultPDFRenderer.pageCount(visualLineCount: lines, query: result.sourceQuery)
      bytes = textBytes + pages * 2_000
    } else {
      pages = ResultPDFRenderer.pageCount(
        visualLineCount: result.rows.count, query: result.sourceQuery)
      bytes = pages * 4_000
    }
    let aboutWrap = options.wrapText && pages >= ExportSizeEstimate.largePageCount
    return ExportSizeEstimate(bytes: bytes, pageCount: pages, warnsAboutWrap: aboutWrap)
  }

  /// UTF-8 bytes of the text that would be written, plus about one separator byte per field.
  private static func textBytes(result: CellResult, options: ExportOptions) -> Int {
    var bytes = 0
    if options.format.offersHeaderToggle && options.includeHeader {
      for column in result.columns {
        bytes += column.name.utf8.count + 1
      }
    } else if options.format == .json || options.format == .sqlInsert || options.format == .excel {
      for column in result.columns {
        bytes += column.name.utf8.count
      }
    }
    let perCellOverhead = options.format == .excel ? 40 : (options.format == .json ? 8 : 1)
    for row in exportedTexts(result: result, options: options) {
      for text in row {
        bytes += text.utf8.count + perCellOverhead
      }
      if options.format == .sqlInsert {
        bytes += 24
      }
    }
    return bytes
  }

  private static func maxChars(_ rows: [[String]]) -> [Int] {
    var counts: [Int] = []
    for row in rows {
      for (index, text) in row.enumerated() {
        if index >= counts.count {
          counts.append(text.count)
        } else {
          counts[index] = max(counts[index], text.count)
        }
      }
    }
    return counts
  }

  private static func exportedTexts(result: CellResult, options: ExportOptions) -> [[String]] {
    result.rows.map { row in
      row.enumerated().map { index, value in
        cellText(value, column: index, options: options)
      }
    }
  }

  private static func cellText(_ value: CellValue, column: Int, options: ExportOptions) -> String {
    if options.redactedColumns.contains(column) {
      return ExportOptions.mask
    }
    if options.emptiesNulls && value.isNull {
      return ""
    }
    switch value {
    case .string(let text), .json(let text):
      return text
    case .int(let number):
      return String(number)
    case .double(let number):
      return String(number)
    case .bool(let flag):
      return flag ? "true" : "false"
    case .null:
      return "NULL"
    case .date(let date):
      return ISO8601DateFormatter().string(from: date)
    case .data(let data):
      return data.base64EncodedString()
    }
  }
}
