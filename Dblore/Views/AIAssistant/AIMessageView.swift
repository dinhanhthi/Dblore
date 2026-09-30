//
//  AIMessageView.swift
//  Dblore
//
//  One chat entry: inline markdown text, fenced code blocks with Copy / Insert, safety badge
//

import AppKit
import SwiftUI

struct AIMessageView: View {
  let entry: AIChatEntry
  /// Shown while the entry has no text yet
  var placeholder = "Thinking…"
  /// Places SQL in the active tab; nil disables Insert. Never executes.
  let onInsert: ((String) -> Void)?

  private var isUser: Bool { entry.role == .user }
  private var segments: [AIMessageSegment] { AIMessageParser.parse(entry.text) }

  var body: some View {
    HStack(spacing: 0) {
      if isUser { Spacer(minLength: Spacing.xl) }
      content
        .padding(Spacing.sm)
        .background(bubbleBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg))
        .overlay(
          RoundedRectangle(cornerRadius: CornerRadius.lg)
            .stroke(entry.isError ? Color.destructive : Color.border, lineWidth: 1)
            .opacity(isUser && !entry.isError ? 0 : 1)
        )
      if !isUser { Spacer(minLength: Spacing.xl) }
    }
    .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
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

/// Inline-only markdown; falls back to plain text. Links are stripped (link text stays as
/// plain text) so model output can never present a clickable or URL-hiding link.
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

  private var attributed: AttributedString? { Self.sanitized(text) }

  var body: some View {
    Group {
      if let attributed {
        Text(attributed)
      } else {
        Text(text)
      }
    }
    .font(.labelText)
    .foregroundColor(.foreground)
    .textSelection(.enabled)
    .frame(maxWidth: .infinity, alignment: .leading)
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
          .buttonStyle(SecondaryButtonStyle(hPadding: Spacing.sm, vPadding: Spacing.xxs))
          .controlSize(.mini)
        if isSQL {
          Button("Insert") { onInsert?(code) }
            .buttonStyle(SecondaryButtonStyle(hPadding: Spacing.sm, vPadding: Spacing.xxs))
            .controlSize(.mini)
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
          "This removes **all** inactive rows:\n```sql\nDELETE FROM customers WHERE active = false;\n```\nReview before running.",
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
