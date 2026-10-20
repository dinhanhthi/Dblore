// AIMention.swift
// @mentions of the AI composer: parsing the question, the tokens the composer inserts, and the
// labelled context blocks a turn sends. Resolution reads the connection and the gate
// (`AIAssistantViewModel+Mentions`).

import Foundation

/// One mention in a question. `@table:<name>` and `@favorite:<name>` take a name: a run of
/// letters, digits, `_`, `.`, `$` or `-` (a trailing `.` ends the sentence, not the name), or any
/// text in double quotes (`@table:"order items"`). A table name may be `schema.name`; it resolves
/// against the current connection's loaded schema only. `@query` and `@results` take none (a
/// trailing `.` after them ends the sentence too).
nonisolated enum AIMention: Hashable, Sendable {
  case table(String)
  case query
  case results
  case favorite(String)

  /// The four kinds, as the composer lists them
  nonisolated enum Kind: String, CaseIterable, Sendable {
    case table, query, results, favorite

    /// A colon and a name follow the keyword
    var takesName: Bool { self == .table || self == .favorite }

    /// What the composer types for this kind: `@table:` (a name follows) or `@query`
    var prefix: String { "@" + rawValue + (takesName ? ":" : "") }

    var summary: String {
      switch self {
      case .table: "Structure of a table or collection"
      case .query: "The current query"
      case .results: "The current result"
      case .favorite: "A saved favorite query"
      }
    }
  }

  /// Mentions one question resolves; later ones are ignored
  static let maxMentions = 8
  /// Characters of a name
  static let maxNameChars = AITools.maxNameCharacters
  /// Characters one block keeps
  static let maxBlockChars = AIPrompts.maxInputChars
  /// Characters all blocks of a turn keep; blocks past it are left out
  static let maxTotalChars = 24_000
  static let truncationMarker = "[truncated]"

  var kind: Kind {
    switch self {
    case .table: .table
    case .query: .query
    case .results: .results
    case .favorite: .favorite
    }
  }

  /// The text that parses back into this mention, quoted when the name needs it. Nil when no
  /// text does: an empty or too long name, or one holding a double quote or a line break.
  var token: String? {
    switch self {
    case .query, .results: return kind.prefix
    case .table(let name), .favorite(let name):
      guard !name.isEmpty, name.count <= Self.maxNameChars,
        !name.contains(where: { $0 == "\"" || $0.isNewline })
      else { return nil }
      let plain = name.allSatisfy(Self.isNameCharacter) && name.last != "."
      return kind.prefix + (plain ? name : "\"\(name)\"")
    }
  }

  // MARK: - Parsing

  /// The mentions of `text` in order, each once, at most `maxMentions`. A mention starts a word
  /// (the text's start, after whitespace or an opening bracket), so `a@b.com` is none. The
  /// keyword is lowercase; `@query` and `@results` end at a character no name holds, or at dots
  /// followed by one or the end. An empty, unclosed or too long name is no mention.
  static func parse(_ text: String) -> [AIMention] {
    var found: [AIMention] = []
    var rest = Substring(text)
    var previous: Character?
    while let first = rest.first, found.count < maxMentions {
      if first == "@", previous.map(startsWord) ?? true,
        let (mention, after) = mention(at: rest.dropFirst())
      {
        if !found.contains(mention) { found.append(mention) }
        previous = rest[rest.index(before: after)]
        rest = rest[after...]
      } else {
        previous = first
        rest = rest.dropFirst()
      }
    }
    return found
  }

  /// The mention after an `@` and where it ends
  private static func mention(at text: Substring) -> (AIMention, Substring.Index)? {
    for kind in Kind.allCases where text.hasPrefix(kind.rawValue) {
      let after = text.dropFirst(kind.rawValue.count)
      guard kind.takesName else {
        // Trailing dots end the sentence, as after a name
        if let next = after.drop(while: { $0 == "." }).first, isNameCharacter(next) || next == ":" {
          return nil
        }
        return (kind == .query ? .query : .results, after.startIndex)
      }
      guard after.first == ":", let (name, end) = name(at: after.dropFirst()) else { return nil }
      return (kind == .table ? .table(name) : .favorite(name), end)
    }
    return nil
  }

  /// A quoted or plain name and where it ends
  private static func name(at text: Substring) -> (String, Substring.Index)? {
    let name: Substring
    let end: Substring.Index
    if text.first == "\"" {
      let body = text.dropFirst()
      guard let close = body.firstIndex(where: { $0 == "\"" || $0.isNewline }),
        body[close] == "\""
      else { return nil }
      name = body[..<close]
      end = body.index(after: close)
    } else {
      var run = text.prefix(while: isNameCharacter)
      while run.last == "." { run = run.dropLast() }
      name = run
      end = run.endIndex
    }
    guard !name.isEmpty, name.count <= maxNameChars else { return nil }
    return (String(name), end)
  }

  private static func isNameCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || "_.$-".contains(character)
  }

  private static func startsWord(after character: Character) -> Bool {
    character.isWhitespace || "([{".contains(character)
  }

  // MARK: - Resolution helpers

  /// The favorite of that name: exact first, then ignoring case
  static func favorite(named name: String, in favorites: [FavoriteStatement]) -> FavoriteStatement?
  {
    favorites.first { $0.name == name }
      ?? favorites.first { $0.name.lowercased() == name.lowercased() }
  }

  /// A mention and the text it resolved to
  nonisolated struct Block: Equatable, Sendable {
    let mention: AIMention
    let text: String
  }

  /// The blocks under one data notice, each labelled with its mention and fenced, each cut at
  /// `maxBlockChars`; a block that would pass `maxTotalChars` is left out. "" without blocks.
  static func render(_ blocks: [Block]) -> String {
    var used = 0
    let parts = blocks.compactMap { block -> String? in
      let text =
        block.text.count > maxBlockChars
        ? String(block.text.prefix(maxBlockChars)) + "\n" + truncationMarker : block.text
      guard used + text.count <= maxTotalChars else { return nil }
      used += text.count
      let label = block.mention.token ?? block.mention.kind.prefix
      return label + "\n" + AIPrompts.fenced(text, info: "")
    }
    guard !parts.isEmpty else { return "" }
    return "Context the user attached with @mentions. " + MCPResultEncoder.dataNotice + "\n\n"
      + parts.joined(separator: "\n\n")
  }
}
