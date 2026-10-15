// AIMessageParser.swift
// Splits assistant markdown into text and fenced code segments; read-only check for Insert

import Foundation

/// One block of an assistant message.
nonisolated enum AIMessageSegment: Equatable, Sendable {
  case text(String)
  /// `isRun` marks a run fence (```sql run, ```mongodb run on a MongoDB tab): a read-only query
  /// the app runs instead of suggesting.
  case code(language: String?, body: String, isRun: Bool = false)
}

nonisolated enum AIMessageParser {

  private static let fence = "```"
  private static let sqlLanguages: Set<String> = ["sql", "postgresql", "postgres", "psql", "pgsql"]
  /// Fence languages of mongosh commands; never runnable on a SQL tab
  private static let mongoLanguages: Set<String> = ["mongodb", "js", "javascript"]

  /// Split into text and ``` fenced code segments, in order. An unclosed trailing fence
  /// (message still streaming) becomes a code segment. Blank text segments are dropped.
  /// `dialect` is the tab's connection: it decides which fence languages can be run.
  static func parse(_ markdown: String, dialect: SQLDialect) -> [AIMessageSegment] {
    var segments: [AIMessageSegment] = []
    var textLines: [Substring] = []
    var codeLines: [Substring] = []
    var language: String?
    var isRun = false
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
          segments.append(
            .code(language: language, body: codeLines.joined(separator: "\n"), isRun: isRun))
          codeLines = []
          inCode = false
        } else {
          codeLines.append(line)
        }
      } else if trimmed.hasPrefix(fence) {
        flushText()
        (language, isRun) = fenceInfo(trimmed, dialect: dialect)
        inCode = true
      } else {
        textLines.append(line)
      }
    }
    if inCode {
      segments.append(
        .code(language: language, body: codeLines.joined(separator: "\n"), isRun: isRun))
    } else {
      flushText()
    }
    return segments
  }

  /// Trimmed body of the first closed run fence of a language runnable on `dialect`; nil when it
  /// is absent, still streaming (unclosed) or empty.
  static func runQuery(in markdown: String, dialect: SQLDialect) -> String? {
    var codeLines: [Substring] = []
    var isRun = false
    var inCode = false
    for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if inCode {
        if trimmed == fence {
          if isRun {
            let body = codeLines.joined(separator: "\n")
              .trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? nil : body
          }
          codeLines = []
          inCode = false
        } else {
          codeLines.append(line)
        }
      } else if trimmed.hasPrefix(fence) {
        isRun = fenceInfo(trimmed, dialect: dialect).isRun
        inCode = true
      }
    }
    return nil
  }

  /// Language (first info token) and run marker (second token "run" on a language runnable on
  /// `dialect`) of an opening fence line.
  private static func fenceInfo(
    _ fenceLine: String, dialect: SQLDialect
  ) -> (language: String?, isRun: Bool) {
    let tokens = fenceLine.dropFirst(fence.count).split(separator: " ")
    let language = tokens.first.map(String.init)
    let isRun =
      tokens.count > 1 && tokens[1].lowercased() == "run"
      && isRunnable(language: language, dialect: dialect)
    return (language, isRun)
  }

  /// True for fence languages the tab can insert and run: `mongoLanguages` on a MongoDB tab,
  /// `sqlLanguages` on any other; an untagged fence is the tab's language.
  static func isRunnable(language: String?, dialect: SQLDialect) -> Bool {
    guard let language else { return true }
    let languages = dialect == .mongodb ? mongoLanguages : sqlLanguages
    return languages.contains(language.lowercased())
  }

  /// True when every statement is read-only safe per `SQLStatementClassifier` with the
  /// connection `dialect` (empty is true). MongoDB text goes to `MongoCommandClassifier`: a
  /// write, or a command outside the subset (`.unknown`), is not read-only.
  static func isReadOnly(_ sql: String, dialect: SQLDialect) -> Bool {
    SQLStatementClassifier.classify(sql, dialect: dialect).allSatisfy(\.isReadOnlySafe)
  }
}
