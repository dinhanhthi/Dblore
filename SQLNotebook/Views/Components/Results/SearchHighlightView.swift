//
//  SearchHighlightView.swift
//  SQLNotebook
//
//  Search highlighting utilities using AttributedString
//

import SwiftUI

// MARK: - Search Highlighting Utilities

enum SearchHighlighter {
  /// Current match color (orange-yellow, same for both modes)
  // #FFD500 (orange-yellow)
  static let currentMatchColor = Color(red: 1.0, green: 0.835, blue: 0.0)

  /// Check if current appearance is dark mode
  static var isDarkMode: Bool {
    NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
  }

  /// Highlight color for other matches (adapts to color scheme)
  /// Dark mode: white with opacity / Light mode: gray with opacity
  static var highlightColor: Color {
    isDarkMode
      ? Color.white.opacity(0.8)
      : Color.gray.opacity(0.6)
  }

  // MARK: - Caching

  /// LRU cache for AttributedString results to avoid regeneration
  private static var cache: [String: AttributedString] = [:]
  private static let maxCacheSize = 100
  private static var cacheOrder: [String] = []  // Track insertion order for LRU

  /// Clear the AttributedString cache
  /// Call this when search query changes to free memory
  static func clearCache() {
    cache.removeAll()
    cacheOrder.removeAll()
    // Cache cleared - no logging needed as this happens frequently
  }

  /// Create AttributedString với highlighted search matches
  /// - Parameters:
  ///   - text: The text to highlight
  ///   - query: The search query
  ///   - caseSensitive: Whether search is case sensitive
  ///   - currentMatchRange: Optional range of the current match (highlighted in orange)
  /// - Returns: Cached or newly created AttributedString with highlights
  static func highlight(
    text: String,
    query: String,
    caseSensitive: Bool,
    currentMatchRange: Range<String.Index>? = nil
  ) -> AttributedString {
    guard !query.isEmpty else {
      return AttributedString(text)
    }

    // Create cache key from all parameters
    let cacheKey = "\(text)|\(query)|\(caseSensitive)|\(currentMatchRange?.description ?? "")"

    // Check cache first (O(1) lookup)
    if let cached = cache[cacheKey] {
      // Move to end of LRU order (most recently used)
      if let index = cacheOrder.firstIndex(of: cacheKey) {
        cacheOrder.remove(at: index)
        cacheOrder.append(cacheKey)
      }
      return cached
    }

    // Not in cache, compute the AttributedString
    var attributedString = AttributedString(text)
    let searchText = caseSensitive ? text : text.lowercased()
    let searchQuery = caseSensitive ? query : query.lowercased()

    // Find all matches and highlight them
    var searchStartIndex = searchText.startIndex
    while let range = searchText.range(
      of: searchQuery, range: searchStartIndex..<searchText.endIndex)
    {
      // Convert String.Index to AttributedString.Index
      if let attrStart = AttributedString.Index(range.lowerBound, within: attributedString),
        let attrEnd = AttributedString.Index(range.upperBound, within: attributedString)
      {
        let attrRange = attrStart..<attrEnd

        // Check if this is the current match
        let isThisCurrentMatch = currentMatchRange != nil && range == currentMatchRange

        // Apply highlight background color
        attributedString[attrRange].backgroundColor =
          isThisCurrentMatch ? currentMatchColor : highlightColor

        // For accessibility, also make text slightly darker
        attributedString[attrRange].foregroundColor = .black
      }

      searchStartIndex = range.upperBound
    }

    // Store in cache with LRU eviction
    if cache.count >= maxCacheSize {
      // Remove oldest entry (first in order)
      if let oldestKey = cacheOrder.first {
        cache.removeValue(forKey: oldestKey)
        cacheOrder.removeFirst()
      }
    }

    cache[cacheKey] = attributedString
    cacheOrder.append(cacheKey)

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
      let attrEnd = AttributedString.Index(matchRange.upperBound, within: attributedString)
    {
      let attrRange = attrStart..<attrEnd

      // Apply highlight background color
      attributedString[attrRange].backgroundColor =
        isCurrentMatch ? currentMatchColor : highlightColor
      attributedString[attrRange].foregroundColor = .black
    }

    return attributedString
  }
}

// MARK: - Search Highlight Text View

/// SwiftUI Text view với search highlighting
/// Optimized with memoization to avoid regenerating AttributedString on every render
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

  /// Memoized highlighted text - computed once per unique input combination
  /// The SearchHighlighter.highlight() method uses internal caching for efficiency
  private var highlightedText: AttributedString {
    SearchHighlighter.highlight(
      text: text,
      query: query,
      caseSensitive: caseSensitive,
      currentMatchRange: currentMatchRange
    )
  }

  var body: some View {
    Text(highlightedText)  // Use memoized value instead of inline computation
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
