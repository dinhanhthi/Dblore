// SQLTokenizer+Comments.swift
// SQL text without its comments, for display

import Foundation

nonisolated extension SQLTokenizer {
  /// `sql` without `--` and `/* */` comments, using `dialect` (strings, quoted identifiers and
  /// dollar-quoted bodies are kept verbatim). Lines left empty are dropped, trailing spaces are
  /// trimmed, and the result is trimmed. A block comment between two tokens becomes one space.
  func strippingComments(_ sql: String) -> String {
    let scalars = Array(sql.unicodeScalars)
    var lines: [String.UnicodeScalarView] = []
    var line = String.UnicodeScalarView()
    var lineHasContent = false
    func endLine() {
      while let last = line.last, Self.isWhitespace(last) { line.removeLast() }
      if lineHasContent { lines.append(line) }
      line = String.UnicodeScalarView()
      lineHasContent = false
    }

    var i = 0
    while i < scalars.count {
      let lexeme = self.lexeme(in: scalars, at: i)
      let range = lexeme.range
      switch lexeme.kind {
      case .whitespace:
        for scalar in scalars[range] {
          if scalar == "\n" || scalar == "\r" {
            endLine()
          } else {
            line.append(scalar)
          }
        }
      case .comment:
        let before = line.last
        let after = range.upperBound < scalars.count ? scalars[range.upperBound] : nil
        if let before, let after, !Self.isWhitespace(before), !Self.isWhitespace(after) {
          line.append(" ")
        }
      default:
        // Line breaks inside a string or identifier belong to it
        line.append(contentsOf: scalars[range])
        lineHasContent = true
      }
      i = range.upperBound
    }
    endLine()

    let joined = lines.map { String($0) }.joined(separator: "\n")
    return joined.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// PostgreSQL `strippingComments`
  static func strippingComments(_ sql: String) -> String {
    SQLTokenizer().strippingComments(sql)
  }
}
