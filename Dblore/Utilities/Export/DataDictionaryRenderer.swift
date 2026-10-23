// DataDictionaryRenderer.swift
// A database's tables as a data dictionary: a Markdown file, or a standalone HTML file (inline
// CSS, no scripts, no external assets). Every name, type, default and comment comes from the
// catalog and is escaped: Markdown with `DataExporter.escapeMarkdown` plus the link, image,
// emphasis and autolink characters, HTML as text.

import Foundation

nonisolated enum DataDictionaryRenderer {
  /// The file formats offered by File > Export Data Dictionary
  enum Format: String, CaseIterable, Identifiable, Sendable {
    case markdown
    case html

    var id: Self { self }

    var title: String {
      switch self {
      case .markdown: "Markdown"
      case .html: "HTML"
      }
    }

    var fileExtension: String {
      switch self {
      case .markdown: "md"
      case .html: "html"
      }
    }
  }

  /// `skipped`: qualified names of the tables whose structure could not be read
  static func render(
    _ format: Format, tables: [TableStructure], databaseName: String, generatedAt: Date,
    skipped: [String] = []
  ) -> String {
    switch format {
    case .markdown:
      markdown(
        tables: tables, databaseName: databaseName, generatedAt: generatedAt, skipped: skipped)
    case .html:
      html(tables: tables, databaseName: databaseName, generatedAt: generatedAt, skipped: skipped)
    }
  }

  // MARK: - Markdown

  static func markdown(
    tables: [TableStructure], databaseName: String, generatedAt: Date, skipped: [String] = []
  ) -> String {
    var lines = [
      "# Data Dictionary: \(md(databaseName))", "",
      "Generated \(generatedAt.ISO8601Format()). \(tableCount(tables.count)).", "",
    ]
    if !skipped.isEmpty {
      lines += ["\(Self.skippedLabel) \(skipped.map(md).joined(separator: ", ")).", ""]
    }
    lines += ["## Tables", ""]
    for (index, table) in tables.enumerated() {
      lines.append("- [\(md(qualifiedName(table)))](#\(anchor(index)))")
    }
    for (index, table) in tables.enumerated() {
      lines += ["", "<a id=\"\(anchor(index))\"></a>", "", "## \(md(qualifiedName(table)))"]
      if let comment = table.comment, !comment.isEmpty {
        lines += ["", "> \(md(comment))"]
      }
      lines += ["", "### Columns", ""]
      lines += mdTable(Self.columnHeaders, columnRows(table))
      if !table.indexes.isEmpty {
        lines += ["", "### Indexes", ""]
        lines += mdTable(Self.indexHeaders, table.indexes.map(indexRow))
      }
      let foreignKeys = foreignKeyRows(table)
      if !foreignKeys.isEmpty {
        lines += ["", "### Foreign Keys", ""]
        lines += mdTable(Self.foreignKeyHeaders, foreignKeys)
      }
    }
    return lines.joined(separator: "\n") + "\n"
  }

  /// `escapeMarkdown`, then a backslash before the characters that open links, images, code,
  /// emphasis, headings and strikethrough, and before `:` so no `https://` text becomes an
  /// autolink. Catalog text renders as itself, never as a link or a remote image.
  private static func md(_ value: String) -> String {
    // Scalars, not characters: a combining mark must not hide a `[` from the check
    var result = String.UnicodeScalarView()
    for scalar in DataExporter.escapeMarkdown(value).unicodeScalars {
      if Self.markdownSpecials.contains(scalar) { result.append("\\") }
      result.append(scalar)
    }
    return String(result)
  }

  private static let markdownSpecials: Set<Unicode.Scalar> = [
    "`", "*", "_", "[", "]", "(", ")", "!", "#", "~", ":",
  ]

  private static func mdTable(_ headers: [String], _ rows: [[String]]) -> [String] {
    let row = { (cells: [String]) in "| " + cells.map(md).joined(separator: " | ") + " |" }
    return [row(headers), "| " + headers.map { _ in "---" }.joined(separator: " | ") + " |"]
      + rows.map(row)
  }

  // MARK: - HTML

  static func html(
    tables: [TableStructure], databaseName: String, generatedAt: Date, skipped: [String] = []
  ) -> String {
    let title = "Data Dictionary: \(escapeHTML(databaseName))"
    var body = [
      "<h1>\(title)</h1>",
      "<p class=\"meta\">Generated \(generatedAt.ISO8601Format()). "
        + "\(tableCount(tables.count)).</p>",
    ]
    if !skipped.isEmpty {
      body.append(
        "<p class=\"meta\">\(Self.skippedLabel) "
          + "\(skipped.map(escapeHTML).joined(separator: ", ")).</p>")
    }
    body += ["<nav>", "<h2>Tables</h2>", "<ol>"]
    for (index, table) in tables.enumerated() {
      body.append(
        "<li><a href=\"#\(anchor(index))\">\(escapeHTML(qualifiedName(table)))</a></li>")
    }
    body += ["</ol>", "</nav>"]
    for (index, table) in tables.enumerated() {
      body += [
        "<section id=\"\(anchor(index))\">", "<h2>\(escapeHTML(qualifiedName(table)))</h2>",
      ]
      if let comment = table.comment, !comment.isEmpty {
        body.append("<p class=\"comment\">\(escapeHTML(comment))</p>")
      }
      body += ["<h3>Columns</h3>"] + htmlTable(Self.columnHeaders, columnRows(table))
      if !table.indexes.isEmpty {
        body += ["<h3>Indexes</h3>"] + htmlTable(Self.indexHeaders, table.indexes.map(indexRow))
      }
      let foreignKeys = foreignKeyRows(table)
      if !foreignKeys.isEmpty {
        body += ["<h3>Foreign Keys</h3>"] + htmlTable(Self.foreignKeyHeaders, foreignKeys)
      }
      body.append("</section>")
    }
    let head = [
      "<!DOCTYPE html>", "<html lang=\"en\">", "<head>", "<meta charset=\"utf-8\">",
      // Nothing but the inline style may load or run, whatever the catalog text holds
      "<meta http-equiv=\"Content-Security-Policy\" "
        + "content=\"default-src 'none'; style-src 'unsafe-inline'\">",
      "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
      "<title>\(title)</title>", "<style>", Self.css, "</style>", "</head>", "<body>",
    ]
    return (head + body + ["</body>", "</html>"]).joined(separator: "\n") + "\n"
  }

  /// Text and attribute values: `&`, `<`, `>`, `"` and `'` become entities
  static func escapeHTML(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&#39;")
  }

  private static func htmlTable(_ headers: [String], _ rows: [[String]]) -> [String] {
    let cells = { (tag: String, values: [String]) in
      "<tr>" + values.map { "<\(tag)>\(escapeHTML($0))</\(tag)>" }.joined() + "</tr>"
    }
    return ["<table>", "<thead>", cells("th", headers), "</thead>", "<tbody>"]
      + rows.map { cells("td", $0) } + ["</tbody>", "</table>"]
  }

  private static let css = """
    :root { color-scheme: light dark; --fg: #1d1d1f; --muted: #6e6e73; --bg: #ffffff;
      --line: #d2d2d7; --head: #f5f5f7; --link: #0a66d8; }
    @media (prefers-color-scheme: dark) {
      :root { --fg: #f5f5f7; --muted: #a1a1a6; --bg: #1c1c1e; --line: #3a3a3c;
        --head: #2c2c2e; --link: #5aa2ff; }
    }
    body { font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
      color: var(--fg); background: var(--bg); margin: 2rem auto; max-width: 1100px;
      padding: 0 1.5rem; }
    h1 { font-size: 1.6rem; margin-bottom: 0.25rem; }
    h2 { font-size: 1.25rem; margin-top: 2rem; border-bottom: 1px solid var(--line);
      padding-bottom: 0.25rem; }
    h3 { font-size: 1rem; margin: 1.25rem 0 0.5rem; }
    a { color: var(--link); text-decoration: none; }
    .meta, .comment { color: var(--muted); }
    .comment { white-space: pre-wrap; }
    table { border-collapse: collapse; width: 100%; font-size: 13px; }
    th, td { border: 1px solid var(--line); padding: 4px 8px; text-align: left;
      vertical-align: top; white-space: pre-wrap; word-break: break-word; }
    th { background: var(--head); font-weight: 600; }
    """

  // MARK: - Rows

  private static let columnHeaders = ["Column", "Type", "Nullable", "Default", "Key", "Comment"]
  private static let indexHeaders = ["Name", "Columns", "Unique", "Method"]
  private static let foreignKeyHeaders = [
    "Name", "Columns", "References", "On Delete", "On Update",
  ]

  /// Raw cell text; the caller escapes it for its format
  private static func columnRows(_ table: TableStructure) -> [[String]] {
    var primary = Set<String>()
    var foreign = Set<String>()
    var unique = Set<String>()
    for constraint in table.constraints {
      switch constraint.kind {
      case .primaryKey: primary.formUnion(constraint.columns)
      case .foreignKey: foreign.formUnion(constraint.columns)
      case .unique: unique.formUnion(constraint.columns)
      case .check: break
      }
    }
    return table.columns.map { column in
      let keys = [
        primary.contains(column.name) ? "PK" : nil, foreign.contains(column.name) ? "FK" : nil,
        unique.contains(column.name) ? "UQ" : nil,
      ]
      return [
        column.name, column.columnType ?? column.dataType, column.isNullable ? "YES" : "NO",
        defaultText(column), keys.compactMap { $0 }.joined(separator: ", "),
        column.comment ?? "",
      ]
    }
  }

  private static func defaultText(_ column: TableStructure.Column) -> String {
    if let value = column.defaultExpression { return value }
    if let generated = column.generated {
      let kind = generated.isStored ? "STORED" : "VIRTUAL"
      return generated.expression.map { "GENERATED AS (\($0)) \(kind)" } ?? "GENERATED \(kind)"
    }
    switch column.identity {
    case .always: return "GENERATED ALWAYS AS IDENTITY"
    case .byDefault: return "GENERATED BY DEFAULT AS IDENTITY"
    case .autoIncrement: return "AUTO_INCREMENT"
    case nil: return ""
    }
  }

  private static func indexRow(_ index: TableStructure.Index) -> [String] {
    var columns = index.keys.map { key in
      switch key {
      case .column(let name): name
      case .expression(let text): "(\(text ?? "expression"))"
      }
    }.joined(separator: ", ")
    if let predicate = index.predicate { columns += " WHERE \(predicate)" }
    return [index.name, columns, index.isUnique ? "YES" : "NO", index.method ?? ""]
  }

  private static func foreignKeyRows(_ table: TableStructure) -> [[String]] {
    table.constraints.compactMap { constraint in
      guard case .foreignKey(let reference) = constraint.kind else { return nil }
      let target =
        reference.schema.isEmpty ? reference.table : "\(reference.schema).\(reference.table)"
      return [
        constraint.name ?? "", constraint.columns.joined(separator: ", "),
        "\(target) (\(reference.columns.joined(separator: ", ")))",
        reference.onDelete.displayName, reference.onUpdate.displayName,
      ]
    }
  }

  // MARK: - Shared

  private static func qualifiedName(_ table: TableStructure) -> String {
    table.schema.isEmpty ? table.name : "\(table.schema).\(table.name)"
  }

  private static let skippedLabel = "Not included (could not be read):"

  /// Index-based, so no catalog text reaches an id or a link
  private static func anchor(_ index: Int) -> String { "t\(index + 1)" }

  private static func tableCount(_ count: Int) -> String {
    count == 1 ? "1 table" : "\(count) tables"
  }
}
