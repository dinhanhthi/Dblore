//
//  DataExporter.swift
//  Dblore
//

import AppKit
import Foundation
// Import UniformTypeIdentifiers for UTType
import UniformTypeIdentifiers

/// Utility for exporting query results to various formats
enum DataExporter {

  /// Export result to CSV format. Nonisolated: a pure function, callable from any isolation
  nonisolated static func toCSV(
    result: CellResult, includeHeader: Bool = true, quote: ExportQuote = .ifNeeded
  ) -> String {
    var csv = ""

    if includeHeader {
      let headers = result.columns.map { escapeCSV($0.name, quote: quote) }
      csv += headers.joined(separator: ",") + "\n"
    }

    for row in result.rows {
      let values = row.map { escapeCSV($0.fullString, quote: quote) }
      csv += values.joined(separator: ",") + "\n"
    }

    return csv
  }

  /// Export result to TSV format (tab-separated, Excel-compatible). `neutralizesFormulas`
  /// prefixes formula-like text cells and headers as in CSV; other cell types stay raw.
  /// Headers are escaped like cells either way.
  static func toTSV(result: CellResult, neutralizesFormulas: Bool) -> String {
    var tsv = ""

    // Header row
    let headers = result.columns.map {
      tsvField(.string($0.name), neutralizesFormulas: neutralizesFormulas)
    }
    tsv += headers.joined(separator: "\t") + "\n"

    // Data rows
    for row in result.rows {
      let values = row.map { tsvField($0, neutralizesFormulas: neutralizesFormulas) }
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

  /// One escaped TSV field. The formula prefix (text cells only, first scalar only: the
  /// quoting keeps every line in this field) is added before escaping, so it lands inside the
  /// quotes. A JSON cell copies raw, so a jsonb scalar `-5` stays `-5`.
  static func tsvField(_ value: CellValue, neutralizesFormulas: Bool) -> String {
    if neutralizesFormulas, case .string(let text) = value {
      return escapeTSV(prefixedIfFormula(text, splitsFields: false))
    }
    return escapeTSV(value.fullString)
  }

  /// Grid selection copy in `format`, rows joined by LF with no trailing line break (JSON and
  /// Markdown keep their export text). `neutralizesFormulas` prefixes formula-like text cells,
  /// and headers, in the TSV and CSV formats; other cell types stay raw. CSV quotes as the
  /// export's "if needed".
  static func copyText(
    result: CellResult, format: CopyRowsFormat, neutralizesFormulas: Bool
  ) -> String {
    switch format {
    case .tsv, .tsvWithHeaders:
      let header = result.columns.map {
        tsvField(.string($0.name), neutralizesFormulas: neutralizesFormulas)
      }
      let rows = result.rows.map { row in
        row.map { tsvField($0, neutralizesFormulas: neutralizesFormulas) }
      }
      return lines(header: format == .tsvWithHeaders ? header : nil, rows: rows, separator: "\t")
    case .csv, .csvWithHeaders:
      let header = result.columns.map {
        csvField(.string($0.name), neutralizesFormulas: neutralizesFormulas)
      }
      let rows = result.rows.map { row in
        row.map { csvField($0, neutralizesFormulas: neutralizesFormulas) }
      }
      return lines(header: format == .csvWithHeaders ? header : nil, rows: rows, separator: ",")
    case .json:
      return toJSON(result: result)
    case .markdown:
      return toMarkdown(result: result)
    }
  }

  private static func lines(header: [String]?, rows: [[String]], separator: String) -> String {
    ((header.map { [$0] } ?? []) + rows)
      .map { $0.joined(separator: separator) }
      .joined(separator: "\n")
  }

  /// One CSV field quoted if needed. The formula prefix applies to text cells only, as in
  /// `tsvField`.
  private static func csvField(_ value: CellValue, neutralizesFormulas: Bool) -> String {
    if neutralizesFormulas, case .string(let text) = value {
      return escapeCSV(prefixedIfFormula(text, splitsFields: false), quote: .ifNeeded)
    }
    return escapeCSV(value.fullString, quote: .ifNeeded)
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
          <dc:creator>Dblore</dc:creator>
          <dcterms:created xsi:type="dcterms:W3CDTF">\(ISO8601DateFormatter().string(from: Date()))</dcterms:created>
        </cp:coreProperties>
        """
      try core.write(
        to: docPropsDir.appendingPathComponent("core.xml"), atomically: true, encoding: .utf8)

      // docProps/app.xml
      let app = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">
          <Application>Dblore</Application>
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

  /// Export result to JSON format: one object per row, keys in column order. A repeated column
  /// name gets a suffix (`id`, `id_2`, `id_3`, skipping a name another column already has), so
  /// no value is lost. Written by hand because a dictionary would drop the order.
  static func toJSON(
    result: CellResult, pretty: Bool = true, includeNull: Bool = true, valuesAsString: Bool = false
  ) -> String {
    let keys = jsonKeys(result.columns.map(\.name)).map(jsonString)
    let objects = result.rows.map { row in
      let members = keys.indices.compactMap { index -> (String, String)? in
        let value = index < row.count ? row[index] : .null
        if !includeNull && value.isNull { return nil }
        let json = valuesAsString ? jsonString(value.fullString) : jsonValue(value, pretty: pretty)
        return (keys[index], json)
      }
      return jsonContainer(
        members.map { pretty ? "\($0.0) : \($0.1)" : "\($0.0):\($0.1)" }, open: "{",
        close: "}", pretty: pretty)
    }
    return jsonContainer(objects, open: "[", close: "]", pretty: pretty)
  }

  /// Column names made unique: a repeat gets the first free `name_2`, `name_3`, ...
  private static func jsonKeys(_ names: [String]) -> [String] {
    var used = Set(names)
    var seen = Set<String>()
    return names.map { name in
      guard seen.insert(name).inserted else {
        var suffix = 2
        while used.contains("\(name)_\(suffix)") { suffix += 1 }
        used.insert("\(name)_\(suffix)")
        return "\(name)_\(suffix)"
      }
      return name
    }
  }

  /// One cell as JSON text. Only a finite double (its number format) and a parsed `.json` value
  /// go through `JSONSerialization`; the rest is written here as it would write it.
  private static func jsonValue(_ value: CellValue, pretty: Bool) -> String {
    switch value {
    case .int(let int):
      return String(int)
    case .bool(let bool):
      return bool ? "true" : "false"
    case .null:
      return "null"
    case .double(let double) where double.isFinite:
      return serializedJSON(double, pretty: false) ?? jsonString(value.fullString)
    case .json:
      // A parsed value can still be unwritable (`-1e400` parses as an infinity), and an invalid
      // one raises an Objective-C exception that `try` cannot catch, so it is checked first
      let object = cellValueToJSON(value)
      guard !(object is String), JSONSerialization.isValidJSONObject(object) else {
        return jsonString(object as? String ?? value.fullString)
      }
      return serializedJSON(object, pretty: pretty) ?? jsonString(value.fullString)
    default:
      return jsonString(cellValueToJSON(value) as? String ?? value.fullString)
    }
  }

  /// `object` (a valid JSON value) as `JSONSerialization` writes it
  private static func serializedJSON(_ object: Any, pretty: Bool) -> String? {
    let options: JSONSerialization.WritingOptions =
      pretty ? [.fragmentsAllowed, .prettyPrinted] : [.fragmentsAllowed]
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: options) else {
      return nil
    }
    return String(decoding: data, as: UTF8.self)
  }

  /// `text` as a JSON string, byte for byte as `JSONSerialization` writes it: `"`, `\` and `/`
  /// get a backslash, a control character its short form (`\b`, `\t`, `\n`, `\f`, `\r`) or
  /// `\u00xx` (lowercase hex), and every other character stays as it is
  private static func jsonString(_ text: String) -> String {
    guard text.utf8.contains(where: { $0 < 0x20 || $0 == 0x22 || $0 == 0x5C || $0 == 0x2F })
    else { return "\"" + text + "\"" }
    var result = String.UnicodeScalarView()
    result.reserveCapacity(text.utf8.count + 16)
    result.append("\"")
    for scalar in text.unicodeScalars {
      switch scalar.value {
      case 0x22: result.append(contentsOf: "\\\"".unicodeScalars)
      case 0x5C: result.append(contentsOf: "\\\\".unicodeScalars)
      case 0x2F: result.append(contentsOf: "\\/".unicodeScalars)
      case 0x08: result.append(contentsOf: "\\b".unicodeScalars)
      case 0x09: result.append(contentsOf: "\\t".unicodeScalars)
      case 0x0A: result.append(contentsOf: "\\n".unicodeScalars)
      case 0x0C: result.append(contentsOf: "\\f".unicodeScalars)
      case 0x0D: result.append(contentsOf: "\\r".unicodeScalars)
      case 0x00...0x1F:
        let hex = String(scalar.value, radix: 16)
        result.append(contentsOf: ("\\u00" + (hex.count < 2 ? "0" : "") + hex).unicodeScalars)
      default: result.append(scalar)
      }
    }
    result.append("\"")
    return String(result)
  }

  /// `items` in `open`/`close`, one per line indented two spaces when `pretty` (a nested value
  /// keeps its own lines one level deeper: JSON text has no raw line break inside a string)
  private static func jsonContainer(
    _ items: [String], open: String, close: String, pretty: Bool
  ) -> String {
    guard !items.isEmpty else { return open + close }
    guard pretty else { return open + items.joined(separator: ",") + close }
    let body = items.map { "  " + $0.replacingOccurrences(of: "\n", with: "\n  ") }
    return open + "\n" + body.joined(separator: ",\n") + "\n" + close
  }

  /// Export result to Markdown table format
  static func toMarkdown(result: CellResult, includeHeader: Bool = true) -> String {
    guard !result.columns.isEmpty else {
      return "No data"
    }

    var markdown = ""

    if includeHeader {
      let headers = result.columns.map { "| \(escapeMarkdown($0.name)) " }
      markdown += headers.joined() + "|\n"
      let separators = result.columns.map { _ in "| --- " }
      markdown += separators.joined() + "|\n"
    }

    for row in result.rows {
      let values = row.map { "| \(escapeMarkdown($0.fullString)) " }
      markdown += values.joined() + "|\n"
    }

    return markdown
  }

  /// INSERT script. `rows` nil exports every row; otherwise only in-range indexes, in that order.
  /// The table is `table` when that is non-nil, otherwise `result.tableName`.
  static func sqlInsert(
    result: CellResult, rows: [Int]? = nil, table: String? = nil, dialect: SQLDialect,
    includeColumns: Bool = true
  ) -> String {
    let exported = queryResult(from: result, rowIndexes: rows)
    let name = SQLInsertRenderer.tableName(for: exported, fallback: table ?? result.tableName)
    return SQLInsertRenderer.insertScript(
      result: exported, table: name, dialect: dialect, includeColumns: includeColumns)
  }

  /// Parenthesized IN list for `values`.
  static func sqlINList(values: [CellValue], dialect: SQLDialect) -> String {
    SQLInsertRenderer.inList(values: values, dialect: dialect)
  }

  /// PDF of the cell result. `query` is drawn only when the caller passes it.
  static func pdfData(
    result: CellResult, title: String, query: String?, wrapText: Bool = false
  ) -> Data {
    ResultPDFRenderer.render(
      result: queryResult(from: result), title: title, query: query, wrapText: wrapText)
  }

  /// Save the result using the sheet's format and options. Copy actions do not call this.
  static func download(
    result: CellResult, options: ExportOptions, queryIndex: Int? = nil,
    dialect: SQLDialect = .postgresql
  ) {
    let prepared = applying(options, to: result)
    switch options.format {
    case .csv:
      let csv = toCSV(
        result: prepared, includeHeader: options.includeHeader, quote: options.quote)
      let name = generateFilename(extension: "csv", queryIndex: queryIndex)
      saveFile(
        data: fileData(text: csv, options: options), defaultFilename: name,
        allowedFileTypes: ["csv"])
    case .excel:
      downloadExcel(result: prepared, queryIndex: queryIndex)
    case .json:
      let json = toJSON(
        result: prepared, pretty: options.jsonPretty, includeNull: options.jsonIncludeNull,
        valuesAsString: options.jsonValuesAsString)
      let name = generateFilename(extension: "json", queryIndex: queryIndex)
      saveFile(
        data: fileData(text: json, options: options), defaultFilename: name,
        allowedFileTypes: ["json"])
    case .markdown:
      let markdown = toMarkdown(result: prepared, includeHeader: options.includeHeader)
      let name = generateFilename(extension: "md", queryIndex: queryIndex)
      saveFile(
        data: fileData(text: markdown, options: options), defaultFilename: name,
        allowedFileTypes: ["md", "markdown"])
    case .pdf:
      downloadPDF(
        result: prepared, queryIndex: queryIndex, query: result.sourceQuery,
        wrapText: options.wrapText)
    case .sqlInsert:
      let sql = sqlInsert(
        result: prepared, table: result.tableName, dialect: dialect,
        includeColumns: options.includeHeader)
      let name = generateFilename(extension: "sql", queryIndex: queryIndex)
      saveFile(
        data: fileData(text: sql, options: options), defaultFilename: name,
        allowedFileTypes: ["sql"])
    case .parquet:
      // Async with progress: the export sheet runs `exportParquet` after its own save panel.
      assertionFailure("Parquet is exported by ResultExportSheet")
      break
    }
  }

  // MARK: - Parquet

  /// Writes `result` (options already applied) to `destination` through the DuckDB plugin,
  /// off the main actor (`@concurrent` leaves it). `loadLibrary` is the plugin's loader (nil
  /// when it is not installed).
  /// - Throws: `ParquetExport.Failure.pluginMissing` and the errors of `ParquetExporter.export`.
  @concurrent nonisolated static func exportParquet(
    result: CellResult, to destination: URL,
    loadLibrary: AppDatabaseSessionFactory.DuckDBLibraryLoader =
      AppDatabaseSessionFactory().duckDBLibraryLoader,
    progress: @escaping @Sendable (Int) -> Void = { _ in }
  ) async throws {
    guard let load = await loadLibrary() else { throw ParquetExport.Failure.pluginMissing }
    try await PerfSignpost.interval("export.parquet") {
      try await ParquetExporter(loadLibrary: load).export(
        result, to: destination, progress: progress)
    }
  }

  /// The save panel of a Parquet download; nil when cancelled.
  static func chooseParquetDestination(queryIndex: Int?) async -> URL? {
    let savePanel = NSSavePanel()
    savePanel.nameFieldStringValue = generateFilename(
      extension: "parquet", queryIndex: queryIndex)
    savePanel.allowedContentTypes = UTType(filenameExtension: "parquet").map { [$0] } ?? []
    savePanel.canCreateDirectories = true
    let response = await withCheckedContinuation { continuation in
      savePanel.begin { continuation.resume(returning: $0) }
    }
    return response == .OK ? savePanel.url : nil
  }

  // MARK: - Download Functions

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

  /// Download the result as a PDF. The title is the filename without its extension.
  static func downloadPDF(
    result: CellResult, filename: String? = nil, queryIndex: Int? = nil, query: String? = nil,
    wrapText: Bool = false
  ) {
    let defaultName = filename ?? generateFilename(extension: "pdf", queryIndex: queryIndex)
    let data = pdfData(
      result: result, title: pdfTitle(defaultName), query: query, wrapText: wrapText)
    saveFile(data: data, defaultFilename: defaultName, allowedFileTypes: ["pdf"])
  }

  /// Download an INSERT script for every row.
  static func downloadSQLInsert(
    result: CellResult, table: String? = nil, dialect: SQLDialect, filename: String? = nil,
    queryIndex: Int? = nil
  ) {
    let sql = sqlInsert(result: result, table: table, dialect: dialect)
    let defaultName = filename ?? generateFilename(extension: "sql", queryIndex: queryIndex)
    saveFile(content: sql, defaultFilename: defaultName, allowedFileTypes: ["sql"])
  }

  /// Copy result to clipboard in TSV format (Excel-compatible)
  static func copyTSV(result: CellResult) {
    let tsv = toTSV(
      result: result, neutralizesFormulas: AppSettings.shared.neutralizesCopiedFormulas)
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

  /// Copy an INSERT script to the clipboard.
  static func copyInsert(
    result: CellResult, rows: [Int]? = nil, table: String? = nil, dialect: SQLDialect
  ) {
    copyToClipboard(sqlInsert(result: result, rows: rows, table: table, dialect: dialect))
  }

  /// Copy an IN list to the clipboard.
  static func copyINList(values: [CellValue], dialect: SQLDialect) {
    copyToClipboard(sqlINList(values: values, dialect: dialect))
  }

  // MARK: - Private Helpers

  /// `CellResult` as a `QueryResult`. `rowIndexes` nil keeps every row; out-of-range indexes drop.
  private static func queryResult(from result: CellResult, rowIndexes: [Int]? = nil) -> QueryResult
  {
    let selectedRows: [[CellValue]]
    if let rowIndexes {
      selectedRows = rowIndexes.compactMap { index in
        guard result.rows.indices.contains(index) else { return nil }
        return result.rows[index]
      }
    } else {
      selectedRows = result.rows
    }
    return QueryResult(
      columns: result.columns,
      rows: selectedRows,
      rowCount: selectedRows.count,
      executionTime: result.executionTime,
      wasLimited: result.wasLimited,
      affectedRows: result.affectedRows)
  }

  /// Filename without its extension, or `"Result"` when that stem is empty.
  private static func pdfTitle(_ filename: String) -> String {
    let stem = (filename as NSString).deletingPathExtension
    return stem.isEmpty ? "Result" : stem
  }

  /// Generate filename with format: query_<i>-YYYY-MM-DD_HHMMSS.<extension>
  private static func generateFilename(extension: String, queryIndex: Int?) -> String {
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
    let timestamp = dateFormatter.string(from: Date())

    if let index = queryIndex {
      return "dblore_query_\(index)-\(timestamp).\(`extension`)"
    } else {
      return "dblore_query-\(timestamp).\(`extension`)"
    }
  }

  nonisolated static func escapeCSV(_ value: String, quote: ExportQuote) -> String {
    switch quote {
    case .always:
      return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    case .never:
      return value
    case .ifNeeded:
      // Per unicode scalar, so a CRLF counts as a line break.
      if value.unicodeScalars.contains(where: { ",\"\n\r".unicodeScalars.contains($0) }) {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
      }
      return value
    }
  }

  /// A backslash and then a pipe are escaped (so `\|` in the data cannot end the cell), `&`, `<`
  /// and `>` become `&amp;`, `&lt;` and `&gt;` (no HTML or entity in a rendered table), and then
  /// a line break (CRLF, LF or CR) becomes `<br>`, so a cell or header stays one table row
  private static func escapeMarkdown(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "|", with: "\\|")
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\r\n", with: "<br>")
      .replacingOccurrences(of: "\n", with: "<br>")
      .replacingOccurrences(of: "\r", with: "<br>")
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
      // JSON has no NaN or infinity, so they are written as text ("NaN", "Infinity",
      // "-Infinity"), as JavaScript names them
      guard double.isFinite else {
        return double.isNaN ? "NaN" : (double < 0 ? "-Infinity" : "Infinity")
      }
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

  /// `completion` gets true once the file is written, false when the panel is cancelled or the
  /// write fails (after its alert).
  static func saveFile(
    content: String, defaultFilename: String, allowedFileTypes: [String],
    completion: @escaping @MainActor (Bool) -> Void = { _ in }
  ) {
    let savePanel = NSSavePanel()
    savePanel.nameFieldStringValue = defaultFilename
    savePanel.allowedContentTypes = allowedFileTypes.compactMap { UTType(filenameExtension: $0) }
    savePanel.canCreateDirectories = true

    savePanel.begin { response in
      guard response == .OK, let url = savePanel.url else {
        completion(false)
        return
      }
      completeSave(url, completion: completion) {
        try content.write(to: url, atomically: true, encoding: .utf8)
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
      completeSave(url) {
        try data.write(to: url, options: .atomic)
      }
    }
  }

  /// Writes the file off the main actor, then asks whether to open it or reveal it. Cancel leaves
  /// the saved file as is. `completion` gets false when the write failed (after its alert).
  /// `write` only captures Sendable values (the text or bytes and the URL).
  private static func completeSave(
    _ url: URL, completion: @escaping @MainActor (Bool) -> Void = { _ in },
    write: @escaping @Sendable () throws -> Void
  ) {
    Task {
      do {
        try await performWrite(write)
      } catch {
        let alert = NSAlert()
        alert.messageText = "Export Failed"
        alert.informativeText = "Could not save file: \(error.localizedDescription)"
        alert.alertStyle = .critical
        alert.runModal()
        completion(false)
        return
      }

      // The save panel may still be dismissing. Presenting now stacks the two modals.
      DispatchQueue.main.async {
        presentSavedFile(url)
      }
      completion(true)
    }
  }

  /// Runs a file write off the main actor (`@concurrent` leaves it).
  @concurrent nonisolated private static func performWrite(
    _ write: @Sendable () throws -> Void
  ) async throws {
    try write()
  }

  /// The Open File / Open Location alert after a file was saved.
  static func presentSavedFile(_ url: URL) {
    let alert = NSAlert()
    alert.messageText = "Export Complete"
    alert.informativeText = "Saved \(url.lastPathComponent)."
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Open File")
    alert.addButton(withTitle: "Open Location")
    alert.addButton(withTitle: "Cancel")
    if alert.buttons.count > 2 {
      alert.buttons[2].keyEquivalent = "\u{1b}"
    }
    switch alert.runModal() {
    case .alertFirstButtonReturn:
      NSWorkspace.shared.open(url)
    case .alertSecondButtonReturn:
      NSWorkspace.shared.activateFileViewerSelecting([url])
    default:
      break
    }
  }
}
