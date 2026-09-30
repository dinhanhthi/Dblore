//
//  SidebarEntityFilter.swift
//  Dblore
//
//  Loose fuzzy matching for the left sidebar filter field.
//

import Foundation

/// Columns to show for a table or view, and whether the row should open so matches are visible.
struct SidebarColumnMatch {
  let columns: [DatabaseColumn]
  let expandForMatch: Bool
}

enum SidebarEntityFilter {
  /// Whitespace-separated terms. Empty query matches everything.
  static func keywords(in query: String) -> [String] {
    query.split(whereSeparator: \.isWhitespace).map { String($0).lowercased() }
  }

  /// Every keyword fuzzy-matches `text`.
  static func matchesAll(_ text: String, keywords: [String]) -> Bool {
    guard !keywords.isEmpty else { return true }
    return keywords.allSatisfy { fuzzy($0, in: text) }
  }

  /// A table or view stays visible when every keyword hits its name or a column name.
  /// A name match keeps every column. A column-only match opens the row and shows those columns.
  static func matchColumns(
    name: String,
    columns: [DatabaseColumn],
    keywords: [String]
  ) -> SidebarColumnMatch? {
    guard !keywords.isEmpty else {
      return SidebarColumnMatch(columns: columns, expandForMatch: false)
    }
    if matchesAll(name, keywords: keywords) {
      return SidebarColumnMatch(columns: columns, expandForMatch: false)
    }

    let covered = keywords.allSatisfy { keyword in
      fuzzy(keyword, in: name) || columns.contains { fuzzy(keyword, in: $0.name) }
    }
    guard covered else { return nil }

    let visible = columns.filter { column in
      keywords.contains { fuzzy($0, in: column.name) }
    }
    return SidebarColumnMatch(columns: visible, expandForMatch: true)
  }

  /// Case-insensitive and loose: a contiguous hit, an in-order abbreviation, or one typo.
  private static func fuzzy(_ keyword: String, in text: String) -> Bool {
    let needle = keyword.lowercased()
    guard !needle.isEmpty else { return true }
    let haystack = text.lowercased()
    if haystack.contains(needle) { return true }

    let collapsed = haystack.replacingOccurrences(of: "_", with: "")
    // Two-letter terms stay contiguous (`id` still means id). Longer terms may skip letters.
    let maxSpan = needle.count <= 2 ? needle.count : needle.count * 3
    if hasSubsequence(in: haystack, needle: needle, maxSpan: maxSpan) { return true }
    if collapsed != haystack, hasSubsequence(in: collapsed, needle: needle, maxSpan: maxSpan) {
      return true
    }

    // One insertion, deletion, substitution, or adjacent swap. Short terms stay subsequence-only
    // so two letters do not match every nearby identifier.
    guard needle.count >= 4 else { return false }
    return hasNearMiss(in: haystack, collapsed: collapsed, needle: needle)
  }

  /// Characters of `needle` appear in order inside a bounded span, so abbreviations match
  /// (`usr` → `users`) without treating scattered letters in a long name as a hit.
  private static func hasSubsequence(in haystack: String, needle: String, maxSpan: Int) -> Bool {
    let h = Array(haystack)
    let n = Array(needle)
    guard n.count >= 2, h.count >= n.count else { return false }

    var start = 0
    while start <= h.count - n.count {
      guard let startIndex = h[start..<h.count].firstIndex(of: n[0]) else { return false }
      var end = startIndex
      var matched = true
      for character in n.dropFirst() {
        let from = end + 1
        guard from < h.count, let next = h[from..<h.count].firstIndex(of: character) else {
          matched = false
          break
        }
        end = next
      }
      if matched, end - startIndex + 1 <= maxSpan { return true }
      start = startIndex + 1
    }
    return false
  }

  private static func hasNearMiss(in haystack: String, collapsed: String, needle: String) -> Bool {
    var candidates = haystack.split(separator: "_").map(String.init)
    candidates.append(haystack)
    if collapsed != haystack { candidates.append(collapsed) }

    let minWindow = max(1, needle.count - 1)
    let maxWindow = needle.count + 1
    for candidate in candidates {
      if editDistance(candidate, needle) <= 1 { return true }
      let chars = Array(candidate)
      guard chars.count >= minWindow else { continue }
      let upper = min(maxWindow, chars.count)
      guard upper >= minWindow else { continue }
      for width in minWindow...upper {
        let last = chars.count - width
        for index in 0...last {
          let window = String(chars[index..<(index + width)])
          if editDistance(window, needle) <= 1 { return true }
        }
      }
    }
    return false
  }

  /// Optimal string alignment. Distances above 1 collapse to 2 so callers can stop early.
  private static func editDistance(_ a: String, _ b: String) -> Int {
    let s = Array(a)
    let t = Array(b)
    let n = s.count
    let m = t.count
    if abs(n - m) > 1 { return 2 }
    if n == 0 || m == 0 { return max(n, m) }

    var twoBack = [Int](repeating: 0, count: m + 1)
    var previous = Array(0...m)
    var current = [Int](repeating: 0, count: m + 1)

    for i in 1...n {
      current[0] = i
      var rowMin = i
      for j in 1...m {
        let cost = s[i - 1] == t[j - 1] ? 0 : 1
        var best = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
        if i > 1, j > 1, s[i - 1] == t[j - 2], s[i - 2] == t[j - 1] {
          best = min(best, twoBack[j - 2] + 1)
        }
        current[j] = best
        rowMin = min(rowMin, best)
      }
      if rowMin > 1 { return 2 }
      twoBack = previous
      previous = current
    }
    return min(previous[m], 2)
  }
}
