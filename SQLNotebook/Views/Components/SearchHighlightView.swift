//
//  SearchHighlightView.swift
//  SQLNotebook
//
//  Search highlighting utilities using AttributedString
//

import SwiftUI

// MARK: - Search Highlighting Utilities

enum SearchHighlighter {
  /// Highlight color cho search matches
  static let highlightColor = Color(red: 1.0, green: 0.973, blue: 0.769) // #FFF9C4 (light yellow)
  static let currentMatchColor = Color(red: 1.0, green: 0.835, blue: 0.0) // #FFD500 (orange-yellow)

  /// Create AttributedString với highlighted search matches
  /// - Parameters:
  ///   - text: The text to highlight
  ///   - query: The search query
  ///   - caseSensitive: Whether search is case sensitive
  ///   - currentMatchRange: Optional range of the current match (highlighted in orange)
  static func highlight(
    text: String,
    query: String,
    caseSensitive: Bool,
    currentMatchRange: Range<String.Index>? = nil
  ) -> AttributedString {
    guard !query.isEmpty else {
      return AttributedString(text)
    }

    var attributedString = AttributedString(text)
    let searchText = caseSensitive ? text : text.lowercased()
    let searchQuery = caseSensitive ? query : query.lowercased()

    // Find all matches and highlight them
    var searchStartIndex = searchText.startIndex
    while let range = searchText.range(of: searchQuery, range: searchStartIndex..<searchText.endIndex) {
      // Convert String.Index to AttributedString.Index
      if let attrStart = AttributedString.Index(range.lowerBound, within: attributedString),
         let attrEnd = AttributedString.Index(range.upperBound, within: attributedString) {
        let attrRange = attrStart..<attrEnd

        // Check if this is the current match
        let isThisCurrentMatch = currentMatchRange != nil && range == currentMatchRange

        // Apply highlight background color
        attributedString[attrRange].backgroundColor = isThisCurrentMatch ? currentMatchColor : highlightColor

        // For accessibility, also make text slightly darker
        attributedString[attrRange].foregroundColor = .black
      }

      searchStartIndex = range.upperBound
    }

    return attributedString
  }

  /// Highlight specific match range in text
  static func highlightRange(
    text: String,
    matchRange: Range<String.Index>,
    isCurrentMatch: Bool = false
  ) -> AttributedString {
    var attributedString = AttributedString(text)

    // Convert String.Index to AttributedString.Index
    if let attrStart = AttributedString.Index(matchRange.lowerBound, within: attributedString),
       let attrEnd = AttributedString.Index(matchRange.upperBound, within: attributedString) {
      let attrRange = attrStart..<attrEnd

      // Apply highlight background color
      attributedString[attrRange].backgroundColor = isCurrentMatch ? currentMatchColor : highlightColor
      attributedString[attrRange].foregroundColor = .black
    }

    return attributedString
  }
}

// MARK: - Search Highlight Text View

/// SwiftUI Text view với search highlighting
struct SearchHighlightText: View {
  let text: String
  let query: String
  let caseSensitive: Bool
  let currentMatchRange: Range<String.Index>?

  init(
    text: String,
    query: String,
    caseSensitive: Bool,
    currentMatchRange: Range<String.Index>? = nil
  ) {
    self.text = text
    self.query = query
    self.caseSensitive = caseSensitive
    self.currentMatchRange = currentMatchRange
  }

  var body: some View {
    Text(SearchHighlighter.highlight(
      text: text,
      query: query,
      caseSensitive: caseSensitive,
      currentMatchRange: currentMatchRange
    ))
  }
}

// MARK: - Preview

#Preview("Highlighted Text") {
  let text1 = "SELECT * FROM users WHERE name = 'Alice'"
  let text2 = "Error: column 'error' not found. Check error logs."

  return VStack(spacing: Spacing.md) {
    // Normal highlights (all yellow)
    SearchHighlightText(
      text: text1,
      query: "SELECT",
      caseSensitive: false
    )
    .font(.mono)
    .padding()
    .background(Color.cellBackground)

    // Current match highlight (one orange, others yellow)
    SearchHighlightText(
      text: text1,
      query: "users",
      caseSensitive: false,
      currentMatchRange: text1.range(of: "users")
    )
    .font(.mono)
    .padding()
    .background(Color.cellBackground)

    // Multiple matches (all yellow)
    SearchHighlightText(
      text: text2,
      query: "error",
      caseSensitive: false
    )
    .font(.mono)
    .foregroundColor(.destructive)
    .padding()
    .background(Color.destructive.opacity(0.1))
  }
  .padding()
  .frame(width: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}
