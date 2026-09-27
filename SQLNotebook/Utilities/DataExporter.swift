//
//  DataExporter.swift
//  SQLNotebook
//

import AppKit
import Foundation
// Import UniformTypeIdentifiers for UTType
import UniformTypeIdentifiers

/// Utility for exporting query results to various formats
enum DataExporter {

  /// Export result to CSV format
  static func toCSV(result: CellResult) -> String {
    var csv = ""

    // Header row
    let headers = result.columns.map { escapeCSV($0.name) }
    csv += headers.joined(separator: ",") + "\n"

    // Data rows
    for row in result.rows {
      let values = row.map { escapeCSV($0.fullString) }
      csv += values.joined(separator: ",") + "\n"
    }

    return csv
  }

  /// Export result to TSV format (tab-separated, Excel-compatible)
  static func toTSV(result: CellResult) -> String {
    var tsv = ""

    // Header row
    let headers = result.columns.map { $0.name }
    tsv += headers.joined(separator: "\t") + "\n"

    // Data rows
    for row in result.rows {
      let values = row.map { escapeTSV($0.fullString) }
      tsv += values.joined(separator: "\t") + "\n"
    }

    return tsv
  }

  /// TSV value escape shared with the grid selection copy: a value with a tab, LF, CR or quote
  /// (checked per unicode scalar, so CRLF counts) is quoted with inner quotes doubled, as in CSV
  static func escapeTSV(_ value: String) -> String {
    guard value.unicodeScalars.contains(where: { "\t\n\r\"".unicodeScalars.contains($0) }) else {
      return value
    }
    return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
  }

  /// Export result to XLSX format (ZIP-based Office Open XML)
  static func toXLSX(result: CellResult) -> Data? {
    // Create temporary directory for XLSX structure
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    do {
      try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

      // Create XLSX folder structure
      let xlDir = tempDir.appendingPathComponent("_rels")
      let docPropsDir = tempDir.appendingPathComponent("docProps")
      let xlWorksheetDir = tempDir.appendingPathComponent("xl").appendingPathComponent("worksheets")
      let xlRelsDir = tempDir.appendingPathComponent("xl").appendingPathComponent("_rels")

      try FileManager.default.createDirectory(at: xlDir, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: docPropsDir, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: xlWorksheetDir, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: xlRelsDir, withIntermediateDirectories: true)

      // [Content_Types].xml
      let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
          <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
          <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
          <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
        </Types>
        """
      try contentTypes.write(
        to: tempDir.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8
      )

      // _rels/.rels
      let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
          <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
          <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
        </Relationships>
        """
      try rels.write(to: xlDir.appendingPathComponent(".rels"), atomically: true, encoding: .utf8)

      // docProps/core.xml
      let core = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <dc:creator>SQLNotebook</dc:creator>
          <dcterms:created xsi:type="dcterms:W3CDTF">\(ISO8601DateFormatter().string(from: Date()))</dcterms:created>
        </cp:coreProperties>
        """
      try core.write(
        to: docPropsDir.appendingPathComponent("core.xml"), atomically: true, encoding: .utf8)

      // docProps/app.xml
      let app = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">
          <Application>SQLNotebook</Application>
        </Properties>
        """
      try app.write(
        to: docPropsDir.appendingPathComponent("app.xml"), atomically: true, encoding: .utf8)

      // xl/workbook.xml
      let workbook = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets>
            <sheet name="Sheet1" sheetId="1" r:id="rId1"/>
          </sheets>
        </workbook>
        """
      try workbook.write(
        to: tempDir.appendingPathComponent("xl").appendingPathComponent("workbook.xml"),
        atomically: true, encoding: .utf8)

      // xl/_rels/workbook.xml.rels
      let workbookRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
        </Relationships>
        """
      try workbookRels.write(
        to: xlRelsDir.appendingPathComponent("workbook.xml.rels"), atomically: true, encoding: .utf8
      )

      // xl/worksheets/sheet1.xml - The actual data
      var worksheet = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData>

        """

      // Header row (row 1)
      worksheet += "    <row r=\"1\">\n"
      for (colIndex, column) in result.columns.enumerated() {
        let cellRef = columnLetter(colIndex) + "1"
        worksheet +=
          "      <c r=\"\(cellRef)\" t=\"inlineStr\"><is><t>\(escapeXML(column.name))</t></is></c>\n"
      }
      worksheet += "    </row>\n"

      // Data rows
      for (rowIndex, row) in result.rows.enumerated() {
        let rowNum = rowIndex + 2  // Start from row 2 (after header)
        worksheet += "    <row r=\"\(rowNum)\">\n"
        for (colIndex, value) in row.enumerated() {
          let cellRef = columnLetter(colIndex) + String(rowNum)
          let (cellType, cellValue) = cellValueToXLSXCell(value)
          worksheet += "      <c r=\"\(cellRef)\" t=\"\(cellType)\">\(cellValue)</c>\n"
        }
        worksheet += "    </row>\n"
      }

      worksheet += """
          </sheetData>
        </worksheet>
        """
      try worksheet.write(
        to: xlWorksheetDir.appendingPathComponent("sheet1.xml"), atomically: true, encoding: .utf8)

      // Create ZIP archive
      let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString + ".xlsx")

      // Use Process to run zip command
      let process = Process()
      process.currentDirectoryURL = tempDir
      process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
      process.arguments = ["-r", "-q", zipURL.path, "."]

      try process.run()
      process.waitUntilExit()

      guard process.terminationStatus == 0 else {
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.removeItem(at: zipURL)
        return nil
      }

      // Read the ZIP file
      let data = try Data(contentsOf: zipURL)

      // Clean up
      try? FileManager.default.removeItem(at: tempDir)
      try? FileManager.default.removeItem(at: zipURL)

      return data

    } catch {
      try? FileManager.default.removeItem(at: tempDir)
      return nil
    }
  }

  /// Export result to Excel XML format (SpreadsheetML) - Legacy format
  static func toExcelXML(result: CellResult) -> String {
    var xml = """
      <?xml version="1.0"?>
      <?mso-application progid="Excel.Sheet"?>
      <Workbook xmlns="urn:schemas-microsoft-com:office:spreadsheet"
       xmlns:ss="urn:schemas-microsoft-com:office:spreadsheet">
       <Worksheet ss:Name="Sheet1">
        <Table>

      """

    // Header row
    xml += "   <Row>\n"
    for column in result.columns {
      xml += "    <Cell><Data ss:Type=\"String\">\(escapeXML(column.name))</Data></Cell>\n"
    }
    xml += "   </Row>\n"

    // Data rows
    for row in result.rows {
      xml += "   <Row>\n"
      for value in row {
        let (type, data) = cellValueToExcelXML(value)
        xml += "    <Cell><Data ss:Type=\"\(type)\">\(data)</Data></Cell>\n"
      }
      xml += "   </Row>\n"
    }

    xml += """
        </Table>
       </Worksheet>
      </Workbook>
      """

    return xml
  }

  /// Export result to JSON format
  static func toJSON(result: CellResult) -> String {
    var objects: [[String: Any]] = []

    for row in result.rows {
      var obj: [String: Any] = [:]
      for (index, column) in result.columns.enumerated() {
        obj[column.name] = cellValueToJSON(row[index])
      }
      objects.append(obj)
    }

    guard
      let jsonData = try? JSONSerialization.data(withJSONObject: objects, options: .prettyPrinted),
      let jsonString = String(data: jsonData, encoding: .utf8)
    else {
      return "[]"
    }

    return jsonString
  }

  /// Export result to Markdown table format
  static func toMarkdown(result: CellResult) -> String {
    guard !result.columns.isEmpty else {
      return "No data"
    }

    var markdown = ""

    // Header row
    let headers = result.columns.map { "| \($0.name) " }
    markdown += headers.joined() + "|\n"

    // Separator row
    let separators = result.columns.map { _ in "| --- " }
    markdown += separators.joined() + "|\n"

    // Data rows
    for row in result.rows {
      let values = row.map { "| \(escapeMarkdown($0.fullString)) " }
      markdown += values.joined() + "|\n"
    }

    return markdown
  }

  // MARK: - Download Functions

  /// Download result as CSV file
  static func downloadCSV(result: CellResult, filename: String? = nil, queryIndex: Int? = nil) {
    let csv = toCSV(result: result)
    let defaultName = filename ?? generateFilename(extension: "csv", queryIndex: queryIndex)
    saveFile(content: csv, defaultFilename: defaultName, allowedFileTypes: ["csv"])
  }

  /// Download result as Excel file (.xlsx format - ZIP-based OOXML)
  static func downloadExcel(result: CellResult, filename: String? = nil, queryIndex: Int? = nil) {
    guard let xlsxData = toXLSX(result: result) else {
      // Fallback to CSV with Excel-compatible encoding
      let csv = toCSV(result: result)
      let bom = "\u{FEFF}"
      let content = bom + csv
      let defaultName = filename ?? generateFilename(extension: "csv", queryIndex: queryIndex)
      saveFile(content: content, defaultFilename: defaultName, allowedFileTypes: ["csv"])
      return
    }

    let defaultName = filename ?? generateFilename(extension: "xlsx", queryIndex: queryIndex)
    saveFile(data: xlsxData, defaultFilename: defaultName, allowedFileTypes: ["xlsx"])
  }

  /// Download result as JSON file
  static func downloadJSON(result: CellResult, filename: String? = nil, queryIndex: Int? = nil) {
    let json = toJSON(result: result)
    let defaultName = filename ?? generateFilename(extension: "json", queryIndex: queryIndex)
    saveFile(content: json, defaultFilename: defaultName, allowedFileTypes: ["json"])
  }

  /// Download result as Markdown file
  static func downloadMarkdown(result: CellResult, filename: String? = nil, queryIndex: Int? = nil)
  {
    let markdown = toMarkdown(result: result)
    let defaultName = filename ?? generateFilename(extension: "md", queryIndex: queryIndex)
    saveFile(content: markdown, defaultFilename: defaultName, allowedFileTypes: ["md", "markdown"])
  }

  /// Copy result to clipboard in TSV format (Excel-compatible)
  static func copyTSV(result: CellResult) {
    let tsv = toTSV(result: result)
    copyToClipboard(tsv)
  }

  /// Copy result to clipboard in JSON format
  static func copyJSON(result: CellResult) {
    let json = toJSON(result: result)
    copyToClipboard(json)
  }

  /// Copy result to clipboard in Markdown format
  static func copyMarkdown(result: CellResult) {
    let markdown = toMarkdown(result: result)
    copyToClipboard(markdown)
  }

  // MARK: - Private Helpers

  /// Generate filename with format: query_<i>-YYYY-MM-DD_HHMMSS.<extension>
  private static func generateFilename(extension: String, queryIndex: Int?) -> String {
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
    let timestamp = dateFormatter.string(from: Date())

    if let index = queryIndex {
      return "sqlnb_query_\(index)-\(timestamp).\(`extension`)"
    } else {
      return "sqlnb_query-\(timestamp).\(`extension`)"
    }
  }

  private static func escapeCSV(_ value: String) -> String {
    // If value contains comma, quote, or newline, wrap in quotes and escape quotes
    if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
      let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
      return "\"\(escaped)\""
    }
    return value
  }

  private static func escapeMarkdown(_ value: String) -> String {
    // Escape pipe characters in markdown tables
    return value.replacingOccurrences(of: "|", with: "\\|")
  }

  private static func escapeXML(_ value: String) -> String {
    var escaped = value
    escaped = escaped.replacingOccurrences(of: "&", with: "&amp;")
    escaped = escaped.replacingOccurrences(of: "<", with: "&lt;")
    escaped = escaped.replacingOccurrences(of: ">", with: "&gt;")
    escaped = escaped.replacingOccurrences(of: "\"", with: "&quot;")
    escaped = escaped.replacingOccurrences(of: "'", with: "&apos;")
    return escaped
  }

  private static func cellValueToExcelXML(_ value: CellValue) -> (type: String, data: String) {
    switch value {
    case .string(let str):
      return ("String", escapeXML(str))
    case .int(let int):
      return ("Number", String(int))
    case .double(let double):
      return ("Number", String(double))
    case .bool(let bool):
      return ("Boolean", bool ? "1" : "0")
    case .null:
      return ("String", "NULL")
    case .json(let json):
      return ("String", escapeXML(json))
    case .date(let date):
      // Use ISO8601 format for dates in Excel
      return ("String", escapeXML(ISO8601DateFormatter().string(from: date)))
    case .data(let data):
      return ("String", escapeXML(data.base64EncodedString()))
    }
  }

  /// Convert cell value to XLSX cell format
  private static func cellValueToXLSXCell(_ value: CellValue) -> (type: String, value: String) {
    switch value {
    case .string(let str):
      return ("inlineStr", "<is><t>\(escapeXML(str))</t></is>")
    case .int(let int):
      return ("n", "<v>\(int)</v>")
    case .double(let double):
      return ("n", "<v>\(double)</v>")
    case .bool(let bool):
      return ("b", "<v>\(bool ? "1" : "0")</v>")
    case .null:
      return ("inlineStr", "<is><t>NULL</t></is>")
    case .json(let json):
      return ("inlineStr", "<is><t>\(escapeXML(json))</t></is>")
    case .date(let date):
      return (
        "inlineStr", "<is><t>\(escapeXML(ISO8601DateFormatter().string(from: date)))</t></is>"
      )
    case .data(let data):
      return ("inlineStr", "<is><t>\(escapeXML(data.base64EncodedString()))</t></is>")
    }
  }

  /// Convert column index to Excel column letter (0 -> A, 1 -> B, ..., 26 -> AA, etc.)
  private static func columnLetter(_ index: Int) -> String {
    var result = ""
    var num = index
    while true {
      let remainder = num % 26
      result = String(UnicodeScalar(65 + remainder)!) + result
      num = num / 26
      if num == 0 { break }
      num -= 1
    }
    return result
  }

  private static func cellValueToJSON(_ value: CellValue) -> Any {
    switch value {
    case .string(let str):
      return str
    case .int(let int):
      return int
    case .double(let double):
      return double
    case .bool(let bool):
      return bool
    case .null:
      return NSNull()
    case .json(let json):
      // Try to parse JSON string into object
      if let data = json.data(using: .utf8),
        let jsonObject = try? JSONSerialization.jsonObject(with: data)
      {
        return jsonObject
      }
      return json
    case .date(let date):
      return ISO8601DateFormatter().string(from: date)
    case .data(let data):
      return data.base64EncodedString()
    }
  }

  private static func copyToClipboard(_ content: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(content, forType: .string)
  }

  private static func saveFile(content: String, defaultFilename: String, allowedFileTypes: [String])
  {
    let savePanel = NSSavePanel()
    savePanel.nameFieldStringValue = defaultFilename
    savePanel.allowedContentTypes = allowedFileTypes.compactMap { UTType(filenameExtension: $0) }
    savePanel.canCreateDirectories = true

    savePanel.begin { response in
      guard response == .OK, let url = savePanel.url else { return }

      do {
        try content.write(to: url, atomically: true, encoding: .utf8)
      } catch {
        // Show error alert
        let alert = NSAlert()
        alert.messageText = "Export Failed"
        alert.informativeText = "Could not save file: \(error.localizedDescription)"
        alert.alertStyle = .critical
        alert.runModal()
      }
    }
  }

  private static func saveFile(data: Data, defaultFilename: String, allowedFileTypes: [String]) {
    let savePanel = NSSavePanel()
    savePanel.nameFieldStringValue = defaultFilename
    savePanel.allowedContentTypes = allowedFileTypes.compactMap { UTType(filenameExtension: $0) }
    savePanel.canCreateDirectories = true

    savePanel.begin { response in
      guard response == .OK, let url = savePanel.url else { return }

      do {
        try data.write(to: url)
      } catch {
        // Show error alert
        let alert = NSAlert()
        alert.messageText = "Export Failed"
        alert.informativeText = "Could not save file: \(error.localizedDescription)"
        alert.alertStyle = .critical
        alert.runModal()
      }
    }
  }
}
