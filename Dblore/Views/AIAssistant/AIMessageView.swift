//
//  AIMessageView.swift
//  Dblore
//
//  One chat entry: markdown text, fenced code blocks with Copy / Insert, safety badge
//

import AppKit
import SwiftUI

struct AIMessageView: View {
  let entry: AIChatEntry
  /// Shown while the entry has no text yet
  var placeholder = "Thinking…"
  /// Places SQL in the active tab; nil disables Insert. Never executes.
  let onInsert: ((String) -> Void)?
  /// Restarts the conversation from this entry; nil hides the button
  var onRetry: (() -> Void)?
  /// Restarts the conversation from this entry with edited text; nil hides the button
  var onEdit: ((String) -> Void)?

  @State private var isHovering = false
  @State private var isEditing = false
  @State private var editText = ""

  private var isUser: Bool { entry.role == .user }
  private var segments: [AIMessageSegment] { AIMessageParser.parse(entry.text) }

  var body: some View {
    HStack(spacing: 0) {
      if isUser { Spacer(minLength: Spacing.xl) }
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
      if !isUser { Spacer(minLength: Spacing.xl) }
    }
    .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
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
    } else if entry.text.isEmpty {
      Text(placeholder)
        .font(.labelText)
        .foregroundColor(.foregroundMuted)
    } else {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
          switch segment {
          case .text(let text):
            AIMarkdownText(text: text)
          case .code(let language, let body):
            AICodeBlock(language: language, code: body, onInsert: onInsert)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
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

  @State private var copied = false

  private var isSQL: Bool { AIMessageParser.isSQL(language: language) }
  private var modifiesData: Bool { isSQL && !AIMessageParser.isReadOnly(code) }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: Spacing.xs) {
        Text(language ?? "sql")
          .font(.small)
          .foregroundColor(.foregroundMuted)
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
      .background(Capsule().fill(isHighlighted ? Color.gutterBackground : Color.clear))
      .overlay(
        Capsule().stroke(isHighlighted ? Color.borderSubtle : Color.border, lineWidth: 1)
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
      onInsert: nil)
    AIMessageView(
      entry: AIChatEntry(
        id: UUID(), role: .assistant,
        text:
          "### Inactive customers\nThis removes **all** inactive rows:\n- active = false\n```sql\nDELETE FROM customers WHERE active = false;\n```\nReview before running.",
        isError: false),
      onInsert: { _ in })
    AIMessageView(
      entry: AIChatEntry(
        id: UUID(), role: .assistant, text: "Request failed: 401", isError: true),
      onInsert: nil)
  }
  .padding(Spacing.md)
  .frame(width: ComponentSize.sidebarWidth)
  .background(Color.appBackground)
}
