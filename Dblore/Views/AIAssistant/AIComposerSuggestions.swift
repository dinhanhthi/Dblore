// AIComposerSuggestions.swift
// The suggestion popup of the AI composer: the `/` command or `@` mention being typed, what the
// popup lists for it and the draft a pick leaves. The composer's text field does not expose its
// caret, so the token is the one at the end of the draft, where typing happens.

import SwiftUI

nonisolated enum AIComposerSuggestions {
  /// The token at the end of the draft
  struct Token: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
      /// `/` and part of a command name: the whole draft, leading whitespace aside
      case command
      /// `@` and part of a mention keyword
      case mention
      /// `@table:` or `@favorite:` and part of a name
      case name(AIMention.Kind)
    }

    let kind: Kind
    /// UTF-16 offset of the `/` or `@` in the draft
    let start: Int
    /// The token as typed, from its `/` or `@` to the end of the draft
    let text: String
    /// What follows the `/`, the `@` or the colon, an opening quote dropped
    let partial: String
  }

  struct Item: Equatable, Identifiable, Sendable {
    let title: String
    let detail: String
    /// Replaces the token
    let insertion: String

    var id: String { insertion }
  }

  static let maxItems = 8

  // MARK: - Token

  /// The token being typed. A command is the whole draft: `/` then no whitespace. A mention
  /// starts a word (same rule as `AIMention.parse`): `@` then letters, or `@table:` /
  /// `@favorite:` then name characters or an unclosed quote. Nil for anything else.
  static func token(in draft: String) -> Token? {
    let text = draft.drop(while: \.isWhitespace)
    if text.first == "/", !text.contains(where: \.isWhitespace) {
      return Token(
        kind: .command, start: text.startIndex.utf16Offset(in: draft), text: String(text),
        partial: String(text.dropFirst()))
    }
    guard let at = mentionStart(in: draft),
      let (kind, partial) = classify(draft[draft.index(after: at)...])
    else { return nil }
    return Token(
      kind: kind, start: at.utf16Offset(in: draft), text: String(draft[at...]), partial: partial)
  }

  /// The last `@` that starts a word, within the longest token's reach of the end
  private static func mentionStart(in draft: String) -> String.Index? {
    let window = draft.suffix(AIMention.maxNameChars + 16)
    return window.indices.last { index in
      guard window[index] == "@" else { return false }
      guard index > draft.startIndex else { return true }
      return startsWord(after: draft[draft.index(before: index)])
    }
  }

  /// The kind of token after an `@` and its partial text
  private static func classify(_ tail: Substring) -> (Token.Kind, String)? {
    if tail.allSatisfy(\.isLetter) { return (.mention, String(tail)) }
    for kind in AIMention.Kind.allCases where kind.takesName {
      // Lowercase only, as `AIMention.parse` reads it
      let keyword = kind.rawValue + ":"
      guard tail.hasPrefix(keyword) else { continue }
      let name = tail.dropFirst(keyword.count)
      if name.first == "\"" {
        let body = name.dropFirst()
        guard !body.contains(where: { $0 == "\"" || $0.isNewline }) else { return nil }
        return (.name(kind), String(body))
      }
      guard name.allSatisfy(isNameCharacter) else { return nil }
      return (.name(kind), String(name))
    }
    return nil
  }

  /// Same rules as `AIMention`'s private helpers
  private static func isNameCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || "_.$-".contains(character)
  }

  private static func startsWord(after character: Character) -> Bool {
    character.isWhitespace || "([{".contains(character)
  }

  // MARK: - Items

  /// What the popup lists for `token`, matched by prefix ignoring case, exact matches first, at
  /// most `maxItems`. Empty when nothing matches or the one match is already typed in full.
  /// Only the source the token needs is read.
  static func items(
    for token: Token,
    commands: @autoclosure () -> [AISlashCommand],
    tables: @autoclosure () -> [DatabaseTable],
    favorites: @autoclosure () -> [FavoriteStatement]
  ) -> [Item] {
    let partial = token.partial.lowercased()
    func ranked<T>(_ candidates: [T], key: (T) -> [String]) -> [T] {
      let matching = candidates.filter { key($0).contains { $0.lowercased().hasPrefix(partial) } }
      func isExact(_ candidate: T) -> Bool {
        key(candidate).contains { $0.lowercased() == partial }
      }
      return matching.filter(isExact) + matching.filter { !isExact($0) }
    }

    var items: [Item]
    switch token.kind {
    case .command:
      items = ranked(commands()) { [$0.name] }.map { command in
        Item(
          title: "/" + command.name, detail: summary(of: command), insertion: "/\(command.name) ")
      }
    case .mention:
      items = ranked(AIMention.Kind.allCases) { [$0.rawValue] }.map { kind in
        // A name follows `@table:`, so the popup stays open on the names
        Item(
          title: kind.prefix, detail: kind.summary,
          insertion: kind.prefix + (kind.takesName ? "" : " "))
      }
    case .name(.favorite):
      items = ranked(favorites()) { [$0.name] }.compactMap { favorite in
        AIMention.favorite(favorite.name).token.map {
          Item(title: favorite.name, detail: firstLine(of: favorite.sql), insertion: $0 + " ")
        }
      }
    case .name:
      let all = tables()
      // `DatabaseTable.qualifiedName` is main-actor isolated
      let qualified = { (table: DatabaseTable) in table.schema + "." + table.name }
      let nameCounts = Dictionary(all.map { ($0.name, 1) }, uniquingKeysWith: +)
      items = ranked(all) { [$0.name, qualified($0)] }.compactMap { table in
        // The bare name resolves when no other table has it; `schema.name` otherwise
        let unique = nameCounts[table.name] == 1
        return AIMention.table(unique ? table.name : qualified(table)).token.map {
          Item(title: table.name, detail: table.schema, insertion: $0 + " ")
        }
      }
    }

    var seen = Set<String>()
    items = Array(items.filter { seen.insert($0.insertion).inserted }.prefix(maxItems))
    if items.count == 1, items[0].insertion.trimmingCharacters(in: .whitespaces) == token.text {
      return []
    }
    return items
  }

  private static func summary(of command: AISlashCommand) -> String {
    switch command {
    case .builtIn(let builtIn): builtIn.summary
    case .custom(let custom): firstLine(of: custom.template)
    }
  }

  private static func firstLine(of text: String) -> String {
    text.split(whereSeparator: \.isNewline)
      .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
      .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
  }

  // MARK: - Pick

  /// `draft` with `token` replaced by the item's insertion
  static func draft(_ draft: String, picking item: Item, at token: Token) -> String {
    guard token.start <= draft.utf16.count else { return draft }
    let start = String.Index(utf16Offset: token.start, in: draft)
    return String(draft[..<start]) + item.insertion
  }
}

// MARK: - Popup

/// The list above the composer. The composer keeps the keyboard: it moves `selected` and picks.
/// Rows taller than the space offered scroll, keeping the selected one in view.
struct AIComposerSuggestionPopup: View {
  let items: [AIComposerSuggestions.Item]
  let selected: Int
  let onPick: (Int) -> Void

  private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: CornerRadius.lg) }

  var body: some View {
    ViewThatFits(in: .vertical) {
      rows
      ScrollViewReader { proxy in
        ScrollView(.vertical) { rows }
          .onChange(of: selected, initial: true) { _, index in
            if items.indices.contains(index) { proxy.scrollTo(items[index].id) }
          }
      }
    }
    .background(Color.cardBackground)
    .clipShape(shape)
    .overlay(HairlineBorder(shape: shape, color: .border.opacity(0.5)))
    .shadow(color: .black.opacity(0.25), radius: 24, x: 0, y: 8)
    .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)
  }

  private var rows: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
        AIComposerSuggestionRow(item: item, isSelected: index == selected) { onPick(index) }
      }
    }
    .padding(.vertical, Spacing.xs)
  }
}

private struct AIComposerSuggestionRow: View {
  let item: AIComposerSuggestions.Item
  let isSelected: Bool
  let onPick: () -> Void

  @State private var isHovering = false

  var body: some View {
    HStack(spacing: Spacing.sm) {
      Text(item.title)
        .font(.monoSmall)
        .foregroundColor(.foreground)
        .lineLimit(1)
        .layoutPriority(1)
      Text(item.detail)
        .font(.small)
        .foregroundColor(.foregroundSubtle)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.xs)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .background(isSelected ? Color.selectionFill : (isHovering ? Color.hoverFill : Color.clear))
    .onHover { isHovering = $0 }
    .onTapGesture(perform: onPick)
  }
}
