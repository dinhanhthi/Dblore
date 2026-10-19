// SQLLineDiff.swift
// Local line diff of two SQL texts as unified-diff hunks with context lines

import Foundation

/// A longest-common-subsequence line diff, computed locally. Shared leading and trailing lines
/// are trimmed first; when the remaining lines would need more than `cellLimit` table cells the
/// middle becomes one whole-replace block, so giant inputs stay fast.
nonisolated enum SQLLineDiff {
  static let contextLines = 3
  /// Largest old × new line product diffed line by line
  static let cellLimit = 1_000_000

  enum Line: Equatable, Sendable {
    case context(String)
    case removed(String)
    case added(String)
  }

  /// Starts are 1-based line numbers; as in unified diff, a side with count 0 starts at the line
  /// before the hunk
  struct Hunk: Equatable, Sendable {
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    let lines: [Line]
  }

  /// The hunks turning `old` into `new`, each with up to `context` unchanged lines around its
  /// changes; changes closer than `2 × context` lines share a hunk. Identical texts give [].
  /// A trailing newline does not count as an extra empty line.
  static func unified(old: String, new: String, context: Int = contextLines) -> [Hunk] {
    hunks(script(lines(old), lines(new)), context: context)
  }

  private static func lines(_ text: String) -> [String] {
    var parts = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    if parts.last?.isEmpty == true { parts.removeLast() }
    return parts.map(String.init)
  }

  /// The edit script: shared prefix, LCS of the middle (or a whole replace), shared suffix
  private static func script(_ old: [String], _ new: [String]) -> [Line] {
    var prefix = 0
    while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
    var suffix = 0
    while suffix < old.count - prefix, suffix < new.count - prefix,
      old[old.count - 1 - suffix] == new[new.count - 1 - suffix]
    {
      suffix += 1
    }
    let a = Array(old[prefix..<(old.count - suffix)])
    let b = Array(new[prefix..<(new.count - suffix)])
    let middle =
      a.count * b.count > cellLimit
      ? a.map(Line.removed) + b.map(Line.added) : lcsScript(a, b)
    return old[..<prefix].map(Line.context) + middle
      + old[(old.count - suffix)...].map(Line.context)
  }

  private static func lcsScript(_ a: [String], _ b: [String]) -> [Line] {
    // table[i][j] = LCS length of a[i...] and b[j...], flattened row by row
    let width = b.count + 1
    var table = [Int32](repeating: 0, count: (a.count + 1) * width)
    for i in stride(from: a.count - 1, through: 0, by: -1) {
      for j in stride(from: b.count - 1, through: 0, by: -1) {
        table[i * width + j] =
          a[i] == b[j]
          ? table[(i + 1) * width + j + 1] + 1
          : max(table[(i + 1) * width + j], table[i * width + j + 1])
      }
    }
    var result: [Line] = []
    var i = 0
    var j = 0
    while i < a.count, j < b.count {
      if a[i] == b[j] {
        result.append(.context(a[i]))
        i += 1
        j += 1
      } else if table[(i + 1) * width + j] >= table[i * width + j + 1] {
        result.append(.removed(a[i]))
        i += 1
      } else {
        result.append(.added(b[j]))
        j += 1
      }
    }
    return result + a[i...].map(Line.removed) + b[j...].map(Line.added)
  }

  private static func hunks(_ script: [Line], context: Int) -> [Hunk] {
    // Lines of each side before script[k]
    var oldBefore: [Int] = []
    var newBefore: [Int] = []
    var oldLine = 0
    var newLine = 0
    var changes: [Int] = []
    for (index, line) in script.enumerated() {
      oldBefore.append(oldLine)
      newBefore.append(newLine)
      switch line {
      case .context:
        oldLine += 1
        newLine += 1
      case .removed:
        oldLine += 1
        changes.append(index)
      case .added:
        newLine += 1
        changes.append(index)
      }
    }

    func hunk(_ first: Int, _ last: Int) -> Hunk {
      let lower = max(0, first - context)
      let upper = min(script.count - 1, last + context)
      let lines = Array(script[lower...upper])
      let oldCount = lines.count(where: { if case .added = $0 { false } else { true } })
      let newCount = lines.count(where: { if case .removed = $0 { false } else { true } })
      return Hunk(
        oldStart: oldBefore[lower] + (oldCount > 0 ? 1 : 0), oldCount: oldCount,
        newStart: newBefore[lower] + (newCount > 0 ? 1 : 0), newCount: newCount, lines: lines)
    }

    guard var first = changes.first else { return [] }
    var last = first
    var result: [Hunk] = []
    for index in changes.dropFirst() {
      if index - last - 1 > 2 * context {
        result.append(hunk(first, last))
        first = index
      }
      last = index
    }
    result.append(hunk(first, last))
    return result
  }
}
