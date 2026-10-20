// AIInlineCompletion.swift
// Ghost text in SQL editors: the text around the caret, the request and the reply sanitizer

import Foundation

nonisolated enum AIInlineCompletion {

  /// Characters of query text a request holds before and after the caret
  static let maxPrefixChars = 2_000
  static let maxSuffixChars = 500
  /// Lines and characters a suggestion keeps
  static let maxLines = 3
  static let maxSuggestionChars = 300
  /// Output budget of a request: a suggestion is short
  static let maxTokens = 96
  /// Characters of the compact schema
  static let schemaBudgetChars = 1_500

  struct Context: Equatable, Sendable {
    var prefix: String
    var suffix: String
    var dialect: SQLDialect
    /// Compact schema; nil when the connection's AI access does not allow it
    var schema: String?
    /// Lines the suggestion may take (see `context`)
    var maxLines = AIInlineCompletion.maxLines
  }

  /// The editable query text around `caret`, a UTF-16 offset (`NSTextView.selectedRange()`):
  /// the last `maxPrefixChars` characters before it and the first `maxSuffixChars` after it.
  /// Nil on a read-only source tab (its text comes from the server and never goes into a
  /// prompt), for a caret outside the text or inside a character, when only whitespace
  /// precedes the caret, and when text follows the caret on its line (ghost text would cover
  /// it).
  ///
  /// Ghost text is drawn over the editor, never inserted, so it only goes where the text is
  /// blank: lines after the first draw over the blank lines that already follow the caret line.
  /// `maxLines` is 1 plus their count (at most `maxLines`), and 1 when any later line holds
  /// text. The editor's height already holds those lines, so nothing is clipped and no height is
  /// reserved for the suggestion.
  static func context(
    text: String, caret: Int, dialect: SQLDialect, schema: String?, isReadOnlySource: Bool
  ) -> Context? {
    guard !isReadOnlySource, caret >= 0,
      let range = Range(NSRange(location: caret, length: 0), in: text),
      let index = range.lowerBound.samePosition(in: text)
    else { return nil }
    let prefix = String(text[..<index].suffix(maxPrefixChars))
    guard !prefix.allSatisfy(\.isWhitespace) else { return nil }
    var lines = 1
    for character in text[index...] {
      if character.isNewline {
        lines += 1
      } else if !character.isWhitespace {
        guard lines > 1 else { return nil }
        lines = 1
        break
      }
    }
    return Context(
      prefix: prefix, suffix: String(text[index...].prefix(maxSuffixChars)), dialect: dialect,
      schema: schema, maxLines: min(maxLines, lines))
  }

  /// Compact schema of the tables the statement before the caret names (else the first tables)
  static func schema(prefix: String, tables: [DatabaseTable], foreignKeys: [ForeignKey]) -> String {
    let statement = prefix.split(separator: ";", omittingEmptySubsequences: false).last ?? ""
    let selected = AISchemaContext.relevantTables(
      question: String(statement), tables: tables, foreignKeys: foreignKeys)
    return AISchemaContext.render(
      tables: selected, foreignKeys: foreignKeys, budgetChars: schemaBudgetChars)
  }

  /// `schema(prefix:tables:foreignKeys:)` off the main actor: scoring every table and column
  /// of a large schema takes too long for a typing pause on the main thread
  @concurrent static func schemaOffMain(
    prefix: String, tables: [DatabaseTable], foreignKeys: [ForeignKey]
  ) async -> String {
    schema(prefix: prefix, tables: tables, foreignKeys: foreignKeys)
  }

  /// One-shot request: no history and no tools, a small output budget
  static func request(_ context: Context, model: String) -> AIChatRequest {
    let prompt = AIPrompts.inline(context: context)
    return AIChatRequest(
      model: model, system: prompt.system,
      messages: [AIChatMessage(role: .user, text: prompt.user)], maxTokens: maxTokens)
  }

  /// The text to show after the caret: one leading and one trailing code fence and an echo of
  /// the end of `prefix` removed, at most `maxLines` lines and `maxSuggestionChars` characters.
  /// Nil when nothing but whitespace is left.
  static func sanitize(
    _ raw: String, prefix: String, maxLines: Int = AIInlineCompletion.maxLines
  ) -> String? {
    // Every line break the editor draws ("\r", U+2028...) counts as one, as in `context`, in
    // the reply and in the prefix it may echo
    var text = stripFences(normalizingNewlines(raw))
    text.removeFirst(echoLength(text, prefix: normalizingNewlines(prefix)))
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(maxLines)
    text = String(lines.joined(separator: "\n").prefix(maxSuggestionChars))
    while text.last?.isWhitespace == true { text.removeLast() }
    return text.allSatisfy(\.isWhitespace) ? nil : text
  }

  private static func normalizingNewlines(_ text: String) -> String {
    String(text.map { $0.isNewline ? "\n" : $0 })
  }

  private static func stripFences(_ text: String) -> String {
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    if let first = lines.firstIndex(where: { !isBlank($0) }), isFence(lines[first]) {
      lines.removeSubrange(...first)
    }
    if let last = lines.lastIndex(where: { !isBlank($0) }), isFence(lines[last]) {
      lines.removeSubrange(last...)
    }
    return lines.joined(separator: "\n")
  }

  private static func isBlank(_ line: Substring) -> Bool { line.allSatisfy(\.isWhitespace) }

  /// ``` or ```sql (any info word) alone on its line
  private static func isFence(_ line: Substring) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("```") else { return false }
    return trimmed.drop(while: { $0 == "`" }).allSatisfy(isWordCharacter)
  }

  /// Length of the longest end of `prefix` that `text` repeats at its start (the current line,
  /// the whole prefix or the word being typed), never cutting inside a word: after "bo",
  /// "okings" stays.
  private static func echoLength(_ text: String, prefix: String) -> Int {
    let before = Array(prefix)
    let start = Array(text.prefix(before.count))
    for length in stride(from: start.count, to: 0, by: -1) {
      let offset = before.count - length
      guard before[offset...].elementsEqual(start[..<length]) else { continue }
      if offset > 0 && isWordCharacter(before[offset - 1]) && isWordCharacter(start[0]) {
        continue
      }
      return length
    }
    return 0
  }

  private static func isWordCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "_"
  }
}
