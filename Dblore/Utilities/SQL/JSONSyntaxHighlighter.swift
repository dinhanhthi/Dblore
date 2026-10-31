//
//  JSONSyntaxHighlighter.swift
//  Dblore
//
//  JSON syntax highlighting with colored tokens
//

import SwiftUI

nonisolated enum JSONSyntaxHighlighter {
  nonisolated enum TokenType: CaseIterable, Sendable {
    case key
    case string
    case number
    case boolean
    case null
    case punctuation
    case whitespace

    @MainActor var color: Color {
      switch self {
      case .key:
        return Color(light: Color(hex: "9333ea"), dark: Color(hex: "c084fc"))  // Purple 600 / 400
      case .string:
        return .syntaxString
      case .number:
        return .syntaxNumber
      case .boolean:
        return .syntaxFunction  // Sky
      case .null:
        return Color(hex: "6b7280")  // Gray for null
      case .punctuation, .whitespace:
        return .syntaxOperator  // Near black / near white for {}, [], :, ,
      }
    }
  }

  nonisolated struct Token: Sendable {
    let text: String
    let type: TokenType
  }

  /// Color of each token type, read on the main actor and passed to `highlighted(_:palette:)`
  @MainActor static var palette: [TokenType: Color] {
    Dictionary(uniqueKeysWithValues: TokenType.allCases.map { ($0, $0.color) })
  }

  /// `json` with each token colored from `palette`. Pure, so a large JSON is highlighted off the
  /// main actor: tokenizing and building the text is O(size).
  static func highlighted(_ json: String, palette: [TokenType: Color]) -> AttributedString {
    var result = AttributedString()
    for token in tokenize(json) {
      var attributed = AttributedString(token.text)
      attributed.foregroundColor = palette[token.type]
      result.append(attributed)
    }
    return result
  }

  static func tokenize(_ json: String) -> [Token] {
    var tokens: [Token] = []
    var currentIndex = json.startIndex

    while currentIndex < json.endIndex {
      let char = json[currentIndex]

      // Skip whitespace and newlines (preserve them)
      if char.isWhitespace || char.isNewline {
        var whitespace = String(char)
        currentIndex = json.index(after: currentIndex)

        while currentIndex < json.endIndex,
          json[currentIndex].isWhitespace || json[currentIndex].isNewline
        {
          whitespace.append(json[currentIndex])
          currentIndex = json.index(after: currentIndex)
        }

        tokens.append(Token(text: whitespace, type: .whitespace))
        continue
      }

      // Punctuation: {, }, [, ], :, ,
      if char == "{" || char == "}" || char == "[" || char == "]" || char == ":" || char == "," {
        tokens.append(Token(text: String(char), type: .punctuation))
        currentIndex = json.index(after: currentIndex)
        continue
      }

      // Strings (both keys and values)
      if char == "\"" {
        let stringStartIndex = currentIndex
        currentIndex = json.index(after: currentIndex)  // Skip opening quote

        while currentIndex < json.endIndex {
          let c = json[currentIndex]
          if c == "\\" {
            // Skip escaped character
            currentIndex = json.index(after: currentIndex)
            if currentIndex < json.endIndex {
              currentIndex = json.index(after: currentIndex)
            }
          } else if c == "\"" {
            // Found closing quote
            currentIndex = json.index(after: currentIndex)
            break
          } else {
            currentIndex = json.index(after: currentIndex)
          }
        }

        let stringValue = String(json[stringStartIndex..<currentIndex])

        // Determine if this is a key or a value by looking ahead
        var isKey = false
        var lookAheadIndex = currentIndex

        // Skip whitespace
        while lookAheadIndex < json.endIndex,
          json[lookAheadIndex].isWhitespace || json[lookAheadIndex].isNewline
        {
          lookAheadIndex = json.index(after: lookAheadIndex)
        }

        // If next non-whitespace character is ":", this is a key
        if lookAheadIndex < json.endIndex, json[lookAheadIndex] == ":" {
          isKey = true
        }

        tokens.append(Token(text: stringValue, type: isKey ? .key : .string))
        continue
      }

      // Numbers
      if char.isNumber || char == "-" {
        let numberStartIndex = currentIndex

        // Handle negative sign
        if char == "-" {
          currentIndex = json.index(after: currentIndex)
        }

        // Integer part
        while currentIndex < json.endIndex, json[currentIndex].isNumber {
          currentIndex = json.index(after: currentIndex)
        }

        // Decimal part
        if currentIndex < json.endIndex, json[currentIndex] == "." {
          currentIndex = json.index(after: currentIndex)
          while currentIndex < json.endIndex, json[currentIndex].isNumber {
            currentIndex = json.index(after: currentIndex)
          }
        }

        // Exponent part
        if currentIndex < json.endIndex, json[currentIndex] == "e" || json[currentIndex] == "E" {
          currentIndex = json.index(after: currentIndex)
          if currentIndex < json.endIndex, json[currentIndex] == "+" || json[currentIndex] == "-" {
            currentIndex = json.index(after: currentIndex)
          }
          while currentIndex < json.endIndex, json[currentIndex].isNumber {
            currentIndex = json.index(after: currentIndex)
          }
        }

        let numberValue = String(json[numberStartIndex..<currentIndex])
        tokens.append(Token(text: numberValue, type: .number))
        continue
      }

      // Boolean and null
      if char == "t" || char == "f" || char == "n" {
        let keywordStartIndex = currentIndex

        while currentIndex < json.endIndex && json[currentIndex].isLetter {
          currentIndex = json.index(after: currentIndex)
        }

        let keyword = String(json[keywordStartIndex..<currentIndex])

        if keyword == "true" || keyword == "false" {
          tokens.append(Token(text: keyword, type: .boolean))
        } else if keyword == "null" {
          tokens.append(Token(text: keyword, type: .null))
        } else {
          // Unknown keyword, treat as whitespace
          tokens.append(Token(text: keyword, type: .whitespace))
        }
        continue
      }

      // Unknown character, skip it
      currentIndex = json.index(after: currentIndex)
    }

    return tokens
  }
}

// MARK: - Highlighted JSON Text View

/// JSON highlighted beforehand (`JSONSyntaxHighlighter.highlighted`, off the main actor)
struct HighlightedJSONText: View {
  let text: AttributedString

  /// Last highlighted JSON and its text: parents re-render with the same JSON (sidebar
  /// animation, copy feedback), and tokenizing plus building the text is O(size)
  static var lastHighlight: (json: String, text: AttributedString)?
  /// Highlighted JSON above this many UTF-8 bytes is not cached unless `cachesAnySize`: nothing
  /// clears the cache for cell info, so a multi-MB jsonb cell would stay for the process lifetime
  static let maxCachedBytes = 1_000_000

  var body: some View {
    Text(text)
      .font(.mono)
      .textSelection(.enabled)
  }

  /// `json` highlighted on the calling actor, through the cache
  static func attributedString(for json: String, cachesAnySize: Bool = false) -> AttributedString {
    if let lastHighlight, lastHighlight.json == json { return lastHighlight.text }
    let result = JSONSyntaxHighlighter.highlighted(json, palette: JSONSyntaxHighlighter.palette)
    if cachesAnySize || json.utf8.count <= maxCachedBytes { lastHighlight = (json, result) }
    return result
  }
}
