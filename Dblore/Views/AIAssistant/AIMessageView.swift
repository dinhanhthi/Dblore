//
//  AIMessageView.swift
//  Dblore
//
//  One chat entry: markdown text, fenced code blocks with Copy / Insert, safety badge,
//  or the result card of a query the app ran for the assistant
//

import AppKit
import SwiftUI

struct AIMessageView: View {
  let entry: AIChatEntry
  /// Shown while the entry has no text yet
  var placeholder = "Thinking…"
  /// Places SQL in the active tab; nil disables Insert. Inserting never executes: queries run
  /// only through the assistant's read-only run setting.
  let onInsert: ((String) -> Void)?
  /// Connection dialect used to classify SQL blocks for the "modifies data" badge
  let dialect: SQLDialect
  /// Restarts the conversation from this entry; nil hides the button
  var onRetry: (() -> Void)?
  /// Restarts the conversation from this entry with edited text; nil hides the button
  var onEdit: ((String) -> Void)?
  /// Label of this entry's first ```sql run block ("Ran", "Failed" or "Not run"); other run
  /// blocks are "Not run". nil while the reply streams: no label yet.
  var firstRunLabel: String? = "Not run"

  @State private var isHovering = false
  @State private var isEditing = false
  @State private var editText = ""

  private var isUser: Bool { entry.role == .user }
  private var segments: [AIMessageSegment] { AIMessageParser.parse(entry.text) }

  var body: some View {
    HStack(spacing: 0) {
      if isUser { Spacer(minLength: Spacing.xl) }
      // A result is its own bordered card: no bubble around it, no actions on it
      if let result = entry.queryResult {
        AIQueryResultCard(result: result)
      } else {
        bubble
      }
      if !isUser { Spacer(minLength: Spacing.xl) }
    }
    .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
  }

  private var bubble: some View {
    bubbleContent
      .padding(Spacing.sm)
      .background(bubbleBackground)
      .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg))
      .overlay(
        RoundedRectangle(cornerRadius: CornerRadius.lg)
          .stroke(entry.isError ? Color.destructive : Color.border, lineWidth: 1)
          .opacity(isUser && !entry.isError ? 0 : 1)
      )
      .overlay(alignment: .topTrailing) {
        if isHovering, !isEditing, onRetry != nil || onEdit != nil {
          HStack(spacing: Spacing.xs) {
            if onEdit != nil {
              actionButton("pencil", help: "Edit") {
                editText = entry.text
                isEditing = true
              }
            }
            if let onRetry {
              actionButton("arrow.clockwise", help: "Try again", action: onRetry)
            }
          }
          .padding(Spacing.xs)
        }
      }
      .onHover { isHovering = $0 }
  }

  private func actionButton(
    _ symbol: String, help: String, action: @escaping () -> Void
  )
    -> some View
  {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 10, weight: .medium))
        .foregroundColor(.foregroundMuted)
        .frame(width: 18, height: 18)
        .background(bubbleBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm))
    }
    .buttonStyle(.plain)
    .help(help)
  }

  @ViewBuilder
  private var bubbleContent: some View {
    if isEditing {
      editor
    } else {
      content
    }
  }

  private var canSendEdit: Bool {
    !editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var editor: some View {
    VStack(alignment: .trailing, spacing: Spacing.sm) {
      TextField("Edit message", text: $editText, axis: .vertical)
        .textFieldStyle(.plain)
        .font(.labelText)
        .lineLimit(1...8)
      HStack(spacing: Spacing.sm) {
        Button("Cancel") { isEditing = false }
        Button("Send") {
          isEditing = false
          onEdit?(editText)
        }
        .disabled(!canSendEdit)
      }
      .font(.labelText)
    }
    .frame(minWidth: 200, maxWidth: .infinity, alignment: .trailing)
  }

  private var bubbleBackground: Color {
    isUser ? Color.inputBackground : Color.cardBackground
  }

  @ViewBuilder
  private var content: some View {
    if entry.isError {
      Text(entry.text)
        .font(.labelText)
        .foregroundColor(.destructive)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else if entry.isRunning == true {
      HStack(spacing: Spacing.sm) {
        ProgressView().controlSize(.small)
        Text("Running query…")
          .font(.labelText)
          .foregroundColor(.foregroundMuted)
      }
    } else if entry.text.isEmpty {
      Text(placeholder)
        .font(.labelText)
        .foregroundColor(.foregroundMuted)
    } else {
      let segments = segments
      let firstRun = segments.firstIndex {
        if case .code(_, _, true) = $0 { return true } else { return false }
      }
      VStack(alignment: .leading, spacing: Spacing.sm) {
        ForEach(Array(segments.enumerated()), id: \.offset) { offset, segment in
          switch segment {
          case .text(let text):
            AIMarkdownText(text: text)
          case .code(let language, let body, let isRun):
            AICodeBlock(
              language: language, code: body, onInsert: onInsert, dialect: dialect,
              runLabel: isRun ? runLabel(isFirstRun: offset == firstRun) : nil)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func runLabel(isFirstRun: Bool) -> String? {
    guard let firstRunLabel else { return nil }
    return isFirstRun ? firstRunLabel : "Not run"
  }
}

/// Rows of a query the app ran for the assistant: one value large, otherwise a compact grid.
/// Rows are not saved with the chat, so a reopened chat shows only the row count.
private struct AIQueryResultCard: View {
  let result: AIQueryResult

  @Environment(\.pixelLength) private var pixelLength

  /// Longer cell values and column names are cut with "…"; the full value is the tooltip
  private static let maxCellCharacters = 28

  private var isSingleValue: Bool { result.columns.count == 1 && result.rows.count == 1 }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if !result.rows.isEmpty {
        if isSingleValue {
          singleValue
        } else {
          grid
        }
        Rectangle().fill(Color.border).frame(height: pixelLength)
      }
      Text(footer)
        .font(.small)
        .foregroundColor(.foregroundMuted)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(Color.cardHeaderBackground)
    }
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
    .overlay(
      RoundedRectangle(cornerRadius: CornerRadius.md).stroke(Color.border, lineWidth: pixelLength))
  }

  private var footer: String {
    let count = result.rowCount
    guard count > 0 else { return "No rows" }
    let rows = "\(count) row\(count == 1 ? "" : "s")"
    if result.rows.isEmpty {
      let partial = result.rowsTruncated ? " · first \(count) rows only" : ""
      return rows + partial + " · results are not saved with the chat"
    }
    if result.rowsTruncated {
      return rows + " · first \(count) rows only — run the SQL above for all"
    }
    return rows
  }

  private var singleValue: some View {
    VStack(alignment: .leading, spacing: Spacing.xxs) {
      Text(result.columns.first?.name ?? "")
        .font(.smallest)
        .foregroundColor(.foregroundMuted)
        .lineLimit(1)
      valueText(result.rows[0].first ?? nil, font: .subheading)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(Spacing.sm)
    .background(Color.cellBackground)
  }

  /// A grid that fits stretches its last column to the card edge; a wider one scrolls sideways.
  /// Cells keep no fill of their own (a cell narrower than its column would leave a gap).
  private var grid: some View {
    ViewThatFits(in: .horizontal) {
      gridRows
      ScrollView(.horizontal, showsIndicators: false) { gridRows }
    }
    .background(Color.cellBackground)
  }

  private var gridRows: some View {
    let lastColumn = result.columns.count - 1
    return Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
      GridRow {
        ForEach(Array(result.columns.enumerated()), id: \.offset) { column, info in
          Text(verbatim: Self.cut(info.name))
            .font(.smallest.weight(.medium))
            .foregroundColor(.foregroundMuted)
            .lineLimit(1)
            .help(info.type.isEmpty ? info.name : "\(info.name) (\(info.type))")
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .frame(maxWidth: column == lastColumn ? .infinity : nil, alignment: .leading)
        }
      }
      Rectangle().fill(Color.border).frame(height: pixelLength)
        .gridCellUnsizedAxes(.horizontal)
      ForEach(Array(result.rows.enumerated()), id: \.offset) { _, row in
        GridRow {
          ForEach(Array(row.enumerated()), id: \.offset) { column, value in
            valueText(value.map(Self.cut), font: .monoSmall)
              .lineLimit(1)
              .help(value ?? "NULL")
              .padding(.horizontal, Spacing.sm)
              .padding(.vertical, Spacing.xxs)
              .frame(maxWidth: column == lastColumn ? .infinity : nil, alignment: .leading)
          }
        }
      }
    }
  }

  private static func cut(_ text: String) -> String {
    text.count > maxCellCharacters ? text.prefix(maxCellCharacters - 1) + "…" : text
  }

  /// NULL shows as a dim "NULL" so it never reads as the text "NULL" or an empty string
  private func valueText(_ value: String?, font: Font) -> some View {
    Text(verbatim: value ?? "NULL")
      .font(value == nil ? font.italic() : font)
      .foregroundColor(value == nil ? .foregroundSubtle : .foreground)
      .textSelection(.enabled)
  }
}

/// One block of assistant text after fenced code has been split out.
nonisolated enum AIMarkdownBlock: Equatable, Sendable {
  case heading(level: Int, text: String)
  case paragraph(String)
  case list(items: [AIMarkdownListItem])
}

nonisolated struct AIMarkdownListItem: Equatable, Sendable {
  var marker: String
  var text: String
}

/// Inline markdown plus ATX headings and lists. Links are stripped (link text stays as
/// plain text) so model output can never present a clickable or URL-hiding link.
/// Headings use body size, one step above the bubble's `labelText`.
struct AIMarkdownText: View {
  let text: String

  nonisolated static func sanitized(_ markdown: String) -> AttributedString {
    guard
      var parsed = try? AttributedString(
        markdown: markdown,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    else { return AttributedString(markdown) }
    parsed.link = nil
    return parsed
  }

  nonisolated static func blocks(_ markdown: String) -> [AIMarkdownBlock] {
    var blocks: [AIMarkdownBlock] = []
    var paragraph: [String] = []
    var list: [AIMarkdownListItem] = []
    var listOrdered: Bool?

    func flushParagraph() {
      let text = paragraph.joined(separator: "\n")
      if !text.isEmpty { blocks.append(.paragraph(text)) }
      paragraph = []
    }

    func flushList() {
      if !list.isEmpty { blocks.append(.list(items: list)) }
      list = []
      listOrdered = nil
    }

    for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(raw.trimmingCharacters(in: .whitespacesAndNewlines))
      if line.isEmpty {
        flushParagraph()
        flushList()
        continue
      }
      if let heading = heading(from: line) {
        flushParagraph()
        flushList()
        blocks.append(.heading(level: heading.level, text: heading.text))
        continue
      }
      if let item = listItem(from: line) {
        flushParagraph()
        if let listOrdered, listOrdered != item.ordered { flushList() }
        listOrdered = item.ordered
        list.append(item.item)
        continue
      }
      flushList()
      paragraph.append(line)
    }
    flushParagraph()
    flushList()
    return blocks
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
        switch block {
        case .heading(_, let text):
          markdownLine(text, font: .bodyText.weight(.semibold))
        case .paragraph(let text):
          markdownLine(text, font: .labelText)
        case .list(let items):
          VStack(alignment: .leading, spacing: Spacing.xxs) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
              markdownLine(item.marker + " " + item.text, font: .labelText)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func markdownLine(_ markdown: String, font: Font) -> some View {
    Text(Self.sanitized(markdown))
      .font(font)
      .foregroundColor(.foreground)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// CommonMark ATX heading. Requires whitespace after the hashes; a closing `#` run is dropped.
  nonisolated private static func heading(from line: String) -> (level: Int, text: String)? {
    var index = line.startIndex
    var level = 0
    while index < line.endIndex, line[index] == "#", level < 7 {
      level += 1
      index = line.index(after: index)
    }
    guard (1...6).contains(level), index < line.endIndex else { return nil }
    let separator = line[index]
    guard separator == " " || separator == "\t" else { return nil }
    let text = stripClosingHashes(String(line[index...]))
    guard !text.isEmpty else { return nil }
    return (level, text)
  }

  nonisolated private static func stripClosingHashes(_ raw: String) -> String {
    let content = raw.trimmingCharacters(in: .whitespaces)
    guard content.hasSuffix("#") else { return content }
    var index = content.endIndex
    while index > content.startIndex {
      let previous = content.index(before: index)
      if content[previous] != "#" { break }
      index = previous
    }
    guard index > content.startIndex else { return "" }
    let before = content.index(before: index)
    guard content[before] == " " || content[before] == "\t" else { return content }
    return content[..<before].trimmingCharacters(in: .whitespaces)
  }

  nonisolated private static func listItem(
    from line: String
  ) -> (ordered: Bool, item: AIMarkdownListItem)? {
    if let text = bulletText(from: line) {
      return (false, AIMarkdownListItem(marker: "•", text: text))
    }
    if let numbered = numberedText(from: line) {
      return (true, AIMarkdownListItem(marker: "\(numbered.number).", text: numbered.text))
    }
    return nil
  }

  nonisolated private static func bulletText(from line: String) -> String? {
    guard let first = line.first, first == "-" || first == "*" || first == "+" else { return nil }
    let rest = line.dropFirst()
    guard let space = rest.first, space == " " || space == "\t" else { return nil }
    let text = rest.dropFirst().trimmingCharacters(in: .whitespaces)
    return text.isEmpty ? nil : text
  }

  nonisolated private static func numberedText(from line: String) -> (number: Int, text: String)? {
    var index = line.startIndex
    var value = 0
    var digits = 0
    while index < line.endIndex, let digit = line[index].wholeNumberValue {
      digits += 1
      if digits > 9 { return nil }
      value = value * 10 + digit
      index = line.index(after: index)
    }
    guard digits > 0, index < line.endIndex, line[index] == "." || line[index] == ")" else {
      return nil
    }
    index = line.index(after: index)
    guard index < line.endIndex, line[index] == " " || line[index] == "\t" else { return nil }
    let text = line[line.index(after: index)...].trimmingCharacters(in: .whitespaces)
    return text.isEmpty ? nil : (value, text)
  }
}

private struct AICodeBlock: View {
  let language: String?
  let code: String
  let onInsert: ((String) -> Void)?
  let dialect: SQLDialect
  /// "Ran", "Failed" or "Not run" on a ```sql run block; nil for plain blocks
  var runLabel: String? = nil

  @State private var copied = false

  private var isSQL: Bool { AIMessageParser.isSQL(language: language) }
  private var modifiesData: Bool { isSQL && !AIMessageParser.isReadOnly(code, dialect: dialect) }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: Spacing.xs) {
        Text(language ?? "sql")
          .font(.small)
          .foregroundColor(.foregroundMuted)
        if let runLabel { runBadge(runLabel) }
        if modifiesData { modifiesBadge }
        Spacer(minLength: 0)
        Button(copied ? "Copied" : "Copy") { copy() }
          .buttonStyle(AICodeActionButtonStyle())
        if isSQL {
          Button("Insert") { onInsert?(code) }
            .buttonStyle(AICodeActionButtonStyle())
            .disabled(onInsert == nil)
            .help(onInsert == nil ? "No active tab" : "Insert into the active tab (does not run)")
        }
      }
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xs)
      .background(Color.cardHeaderBackground)

      Rectangle().fill(Color.border).frame(height: 1)

      ScrollView(.horizontal, showsIndicators: false) {
        Text(code)
          .font(.monoMedium)
          .foregroundColor(.foreground)
          .textSelection(.enabled)
          .padding(Spacing.sm)
      }
      .background(Color.cellBackground)
    }
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
    .overlay(
      RoundedRectangle(cornerRadius: CornerRadius.md).stroke(Color.border, lineWidth: 1))
  }

  var modifiesBadge: some View {
    Text("Modifies data")
      .font(.smallest)
      .foregroundColor(.warning)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xxs)
      .background(Color.warning.opacity(0.14))
      .clipShape(Capsule())
  }

  private func runBadge(_ label: String) -> some View {
    let (color, help): (Color, String) =
      switch label {
      case "Ran": (.success, "The app ran this read-only query for the assistant")
      case "Failed": (.destructive, "The database returned an error for this query")
      default: (.foregroundMuted, "This query was not run")
      }
    return Text(label)
      .font(.smallest)
      .foregroundColor(color)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xxs)
      .background(color.opacity(0.14))
      .clipShape(Capsule())
      .help(help)
  }

  private func copy() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(code, forType: .string)
    copied = true
    Task {
      try? await Task.sleep(for: .seconds(1.5))
      copied = false
    }
  }
}

/// Compact bordered action on the code-block header, with a hover fill that
/// contrasts against `cardHeaderBackground`.
private struct AICodeActionButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    AICodeActionButton(configuration: configuration)
  }
}

private struct AICodeActionButton: View {
  let configuration: ButtonStyleConfiguration
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovering = false

  private var isHighlighted: Bool { isEnabled && (isHovering || configuration.isPressed) }

  var body: some View {
    configuration.label
      .font(.system(.caption2, weight: .medium))
      .foregroundColor(.foreground)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xxs)
      // Filled so it stands off the gray code header; hover shows on the border.
      .background(Capsule().fill(Color.controlBackground))
      .overlay(
        Capsule().stroke(isHighlighted ? Color.borderStrong : Color.border, lineWidth: 1)
      )
      .contentShape(Capsule())
      .opacity(isEnabled ? 1 : 0.5)
      .animation(.easeInOut(duration: 0.15), value: isHovering)
      .onHover { isHovering = $0 }
      .cursor(.pointingHand)
  }
}

#Preview("AIMessageView") {
  VStack(spacing: Spacing.md) {
    AIMessageView(
      entry: AIChatEntry(
        id: UUID(), role: .user, text: "Delete inactive customers", isError: false),
      onInsert: nil, dialect: .postgresql)
    AIMessageView(
      entry: AIChatEntry(
        id: UUID(), role: .assistant,
        text:
          "### Inactive customers\nThis removes **all** inactive rows:\n- active = false\n```sql\nDELETE FROM customers WHERE active = false;\n```\nReview before running.",
        isError: false),
      onInsert: { _ in }, dialect: .postgresql)
    AIMessageView(
      entry: AIChatEntry(
        id: UUID(), role: .assistant, text: "Request failed: 401", isError: true),
      onInsert: nil, dialect: .postgresql)
  }
  .padding(Spacing.md)
  .frame(width: ComponentSize.sidebarWidth)
  .background(Color.appBackground)
}

#Preview("AIMessageView query results") {
  let columns = [
    AIQueryResult.Column(name: "id", type: "int4"),
    AIQueryResult.Column(name: "email", type: "text"),
    AIQueryResult.Column(name: "last_login", type: "timestamptz"),
  ]
  let rows: [[String?]] = (1...6).map { index in
    [
      "\(index)", "customer\(index)@example.com",
      index.isMultiple(of: 3) ? nil : "2026-10-0\(index)",
    ]
  }
  func entry(text: String = "", result: AIQueryResult? = nil, running: Bool? = nil) -> AIChatEntry {
    AIChatEntry(
      id: UUID(), role: .assistant, text: text, isError: false, queryResult: result,
      isRunning: running)
  }
  return ScrollView {
    VStack(spacing: Spacing.md) {
      AIMessageView(
        entry: entry(text: "```sql run\nSELECT email FROM customers WHERE id = 11;\n```"),
        onInsert: { _ in }, dialect: .postgresql, firstRunLabel: "Ran")
      AIMessageView(entry: entry(running: true), onInsert: nil, dialect: .postgresql)
      AIMessageView(
        entry: entry(
          result: AIQueryResult(
            columns: [AIQueryResult.Column(name: "email", type: "text")],
            rows: [["ada@example.com"]], rowCount: 1, rowsTruncated: false)),
        onInsert: nil, dialect: .postgresql)
      AIMessageView(
        entry: entry(
          result: AIQueryResult(columns: columns, rows: rows, rowCount: 6, rowsTruncated: false)),
        onInsert: nil, dialect: .postgresql)
      AIMessageView(
        entry: entry(
          result: AIQueryResult(columns: columns, rows: rows, rowCount: 6, rowsTruncated: true)),
        onInsert: nil, dialect: .postgresql)
      AIMessageView(
        entry: entry(
          result: AIQueryResult(columns: columns, rows: [], rowCount: 50, rowsTruncated: true)),
        onInsert: nil, dialect: .postgresql)
      AIMessageView(
        entry: entry(
          result: AIQueryResult(columns: columns, rows: [], rowCount: 0, rowsTruncated: false)),
        onInsert: nil, dialect: .postgresql)
    }
    .padding(Spacing.md)
  }
  .frame(width: ComponentSize.sidebarWidth, height: 900)
  .background(Color.appBackground)
}
