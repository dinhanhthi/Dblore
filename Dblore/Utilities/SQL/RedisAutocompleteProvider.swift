//
//  RedisAutocompleteProvider.swift
//  Dblore
//
//  Autocomplete for Redis command cells
//

import Foundation

/// Redis completions, read on the cursor's line as `RedisTokenizer` reads it:
/// - the first word of a line: command names (`RedisCommandClassifier.commandNames`);
/// - the second word, after a command that takes a subcommand (`CONFIG`, `CLIENT`, `XINFO`,
///   `MEMORY`, `OBJECT`, `SCRIPT`, `FUNCTION`, `ACL`, ...): its subcommands.
/// Commands and subcommands the editor refuses (`RedisCommandClassifier.classify` gives a
/// refusal: `SELECT`, `MULTI`, `SUBSCRIBE`, blocking commands, `CLIENT SETNAME`, ...) are left
/// out. Nothing is offered for an empty word, on a `#` comment line, inside quotes or from the
/// third word on; key names need the server and are not offered. Names match the typed word
/// case-insensitively and are inserted upper-case, sorted: exact match first, then
/// alphabetically.
enum RedisAutocompleteProvider {
  /// UTF-16 units scanned back from the cursor to its line start; farther, nothing is offered
  static let maxScan = 10_240
  static let maxSuggestions = 20

  /// The command names the editor runs, sorted
  static let commands: [String] = RedisCommandClassifier.commandNames
    .filter { runs([$0]) }.sorted()

  /// The subcommands the editor runs, sorted, by command
  static let subcommands: [String: [String]] = RedisCommandClassifier.subcommandNames
    .reduce(into: [:]) { result, entry in
      result[entry.key] = entry.value.filter { runs([entry.key, $0]) }.sorted()
    }

  /// Suggestions at `position` (UTF-16 offset)
  static func suggestions(for text: String, at position: Int) -> [AutocompleteSuggestion] {
    let ns = text as NSString
    let cursor = min(max(position, 0), ns.length)

    // The typed word must be a whole argument, so the editor's token is exactly that word
    var wordStart = cursor
    while wordStart > 0 && isNamePart(ns.character(at: wordStart - 1)) { wordStart -= 1 }
    var wordEnd = cursor
    while wordEnd < ns.length && isNamePart(ns.character(at: wordEnd)) { wordEnd += 1 }
    guard wordStart < cursor,
      wordStart == 0 || isSeparator(ns.character(at: wordStart - 1)),
      wordEnd == ns.length || isSeparator(ns.character(at: wordEnd))
    else { return [] }

    var lineStart = wordStart
    let limit = max(0, wordStart - maxScan)
    while lineStart > limit && ns.character(at: lineStart - 1) != RedisSyntaxHighlighter.lineFeed {
      lineStart -= 1
    }
    guard lineStart == 0 || ns.character(at: lineStart - 1) == RedisSyntaxHighlighter.lineFeed
    else { return [] }

    var buffer = [unichar](repeating: 0, count: wordStart - lineStart)
    ns.getCharacters(&buffer, range: NSRange(location: lineStart, length: buffer.count))
    guard let names = candidates(before: buffer) else { return [] }

    let partial = ns.substring(with: NSRange(location: wordStart, length: cursor - wordStart))
      .uppercased()
    let matches = names.filter { $0.name.hasPrefix(partial) }
    let exact = matches.filter { $0.name == partial }
    let others = matches.filter { $0.name != partial }
    return (exact + others).prefix(maxSuggestions).map {
      AutocompleteSuggestion(text: $0.name, type: .keyword, description: $0.description)
    }
  }

  // MARK: - Context

  /// The names offered after `line` (the text from the line start to the typed word), nil when
  /// nothing is: a comment line, inside quotes, or from the third word on
  private static func candidates(
    before line: [unichar]
  ) -> [(name: String, description: String)]? {
    let n = line.count
    var i = 0
    var arguments: [(start: Int, end: Int, quoted: Bool)] = []
    while i < n {
      if RedisSyntaxHighlighter.isSpace(line[i]) {
        i += 1
        continue
      }
      if arguments.isEmpty && line[i] == RedisSyntaxHighlighter.hash { return nil }
      guard arguments.count < 2 else { return nil }
      let start = i
      var quoted = false
      while i < n && !RedisSyntaxHighlighter.isSpace(line[i]) {
        let c = line[i]
        if c == RedisSyntaxHighlighter.doubleQuote || c == RedisSyntaxHighlighter.singleQuote {
          quoted = true
          let end = RedisSyntaxHighlighter.quotedEnd(line, from: i, to: n)
          // `line` ends with the space before the word, so a quote that reaches its end is still
          // open: the word is inside a string
          if end == n { return nil }
          i = end
        } else {
          i += 1
        }
      }
      arguments.append((start, i, quoted))
    }

    switch arguments.count {
    case 0:
      return commands.map { ($0, "Command") }
    case 1:
      let first = arguments[0]
      guard !first.quoted,
        let command = RedisSyntaxHighlighter.upperName(line, first.start, first.end),
        let names = subcommands[command]
      else { return nil }
      return names.map { ($0, "\(command) subcommand") }
    default:
      return nil
    }
  }

  /// The editor runs `words` (no refusal from the classifier)
  private static func runs(_ words: [String]) -> Bool {
    RedisCommandClassifier.classify(words.map { Data($0.utf8) }).refusal == nil
  }

  /// A character of a command or subcommand name
  private static func isNamePart(_ c: unichar) -> Bool {
    (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c) || (0x30...0x39).contains(c)
      || c == 0x5F || c == 0x2D  // _ -
  }

  /// Ends a Redis word and the editor's token alike: space, tab, LF, vertical tab, form feed, CR
  private static func isSeparator(_ c: unichar) -> Bool {
    c == 0x20 || (0x09...0x0D).contains(c)
  }
}
