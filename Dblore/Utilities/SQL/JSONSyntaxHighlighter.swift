//
//  JSONSyntaxHighlighter.swift
//  Dblore
//
//  JSON syntax highlighting with colored tokens
//

import SwiftUI

enum JSONSyntaxHighlighter {
  enum TokenType {
    case key
    case string
    case number
    case boolean
    case null
    case punctuation
    case whitespace

    var color: Color {
      switch self {
      case .key:
        return Color(hex: "c084fc")  // Purple for keys
      case .string:
        return Color(hex: "4ade80")  // Green for strings
      case .number:
        return Color(hex: "fb923c")  // Orange for numbers
      case .boolean:
        return Color(hex: "38bdf8")  // Cyan for booleans
      case .null:
        return Color(hex: "6b7280")  // Gray for null
      case .punctuation:
        return Color(hex: "fafafa")  // White for {}, [], :, ,
      case .whitespace:
        return Color(hex: "fafafa")  // White for spaces
      }
    }
  }

  struct Token {
    let text: String
    let type: TokenType
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

struct HighlightedJSONText: View {
  let tokens: [JSONSyntaxHighlighter.Token]

  init(json: String) {
    tokens = JSONSyntaxHighlighter.tokenize(json)
  }

  var body: some View {
    Text(attributedString)
      .font(.mono)
      .textSelection(.enabled)
  }

  private var attributedString: AttributedString {
    var result = AttributedString()

    for token in tokens {
      var attributed = AttributedString(token.text)
      attributed.foregroundColor = token.type.color
      result.append(attributed)
    }

    return result
  }
}
