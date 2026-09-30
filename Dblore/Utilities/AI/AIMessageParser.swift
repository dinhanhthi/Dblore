// AIMessageParser.swift
// Splits assistant markdown into text and fenced code segments; SQL safety check for Insert

import Foundation

/// One block of an assistant message.
nonisolated enum AIMessageSegment: Equatable, Sendable {
  case text(String)
  case code(language: String?, body: String)
}

nonisolated enum AIMessageParser {

  private static let fence = "```"
  private static let sqlLanguages: Set<String> = ["sql", "postgresql", "postgres", "psql", "pgsql"]

  /// Split into text and ``` fenced code segments, in order. An unclosed trailing fence
  /// (message still streaming) becomes a code segment. Blank text segments are dropped.
  static func parse(_ markdown: String) -> [AIMessageSegment] {
    var segments: [AIMessageSegment] = []
    var textLines: [Substring] = []
    var codeLines: [Substring] = []
    var language: String?
    var inCode = false

    func flushText() {
      let text = textLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty { segments.append(.text(text)) }
      textLines = []
    }

    for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if inCode {
        if trimmed == fence {
          segments.append(.code(language: language, body: codeLines.joined(separator: "\n")))
          codeLines = []
          inCode = false
        } else {
          codeLines.append(line)
        }
      } else if trimmed.hasPrefix(fence) {
        flushText()
        let info = trimmed.dropFirst(fence.count).trimmingCharacters(in: .whitespaces)
        language = info.split(separator: " ").first.map(String.init)
        inCode = true
      } else {
        textLines.append(line)
      }
    }
    if inCode {
      segments.append(.code(language: language, body: codeLines.joined(separator: "\n")))
    } else {
      flushText()
    }
    return segments
  }

  /// True for SQL-ish fence languages; an untagged fence is treated as SQL.
  static func isSQL(language: String?) -> Bool {
    guard let language else { return true }
    return sqlLanguages.contains(language.lowercased())
  }

  /// True when every statement is read-only safe per `SQLStatementClassifier` (empty is true).
  static func isReadOnly(_ sql: String) -> Bool {
    SQLStatementClassifier.classify(sql).allSatisfy(\.isReadOnlySafe)
  }
}
