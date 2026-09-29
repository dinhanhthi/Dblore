//
//  TableHighlightMatcher.swift
//  Dblore
//
//  Client-side twin of `TableFilter.whereClause`: same AND/OR precedence and operator meaning,
//  evaluated over the loaded rows.
//

import Foundation

extension TableHighlight {
  /// Row index -> column indexes of the individually-true conditions, only for rows where the
  /// whole expression is true (AND binds tighter than OR). The `row` style uses just the keys.
  /// Incomplete conditions and unknown columns are skipped, like the filter skips incomplete ones.
  func matches(rows: [[CellValue]], columns: [String], dialect: DatabaseType) -> [Int: Set<Int>] {
    // OR of AND-groups; each entry is (column index, condition)
    var groups: [[(Int, FilterCondition)]] = []
    for condition in filter.conditions
    where condition.isComplete && !(condition.op == .in && Self.inItems(condition.value).isEmpty) {
      guard let index = columns.firstIndex(of: condition.column) else { continue }
      if groups.isEmpty || condition.connector == .or {
        groups.append([])
      }
      groups[groups.count - 1].append((index, condition))
    }
    guard !groups.isEmpty else { return [:] }

    var result: [Int: Set<Int>] = [:]
    for (rowIndex, row) in rows.enumerated() {
      var hits = Set<Int>()
      var rowMatches = false
      for group in groups {
        let trueOnes = group.filter { index, condition in
          index < row.count && Self.test(row[index], condition, dialect: dialect)
        }
        if trueOnes.count == group.count { rowMatches = true }
        hits.formUnion(trueOnes.map(\.0))
      }
      if rowMatches { result[rowIndex] = hits }
    }
    return result
  }

  private static func test(
    _ cell: CellValue, _ condition: FilterCondition, dialect: DatabaseType
  )
    -> Bool
  {
    if condition.op == .isNull { return cell.isNull }
    if condition.op == .isNotNull { return !cell.isNull }
    if cell.isNull { return false }
    let text = cell.fullString
    let value = condition.value
    switch condition.op {
    case .equals: return compare(cell, value) == .orderedSame
    case .notEquals: return compare(cell, value) != .orderedSame
    case .lessThan: return compare(cell, value) == .orderedAscending
    case .lessThanOrEqual: return compare(cell, value) != .orderedDescending
    case .greaterThan: return compare(cell, value) == .orderedDescending
    case .greaterThanOrEqual: return compare(cell, value) != .orderedAscending
    case .in:
      return inItems(value).contains { compare(cell, $0) == .orderedSame }
    case .like, .notLike, .ilike, .notIlike:
      let negated = condition.op == .notLike || condition.op == .notIlike
      // Postgres LIKE is case sensitive; SQLite LIKE (which the filter also uses for ilike) is not
      let insensitive =
        dialect == .sqlite || condition.op == .ilike || condition.op == .notIlike
      return like(text, pattern: value, insensitive: insensitive) != negated
    case .isNull, .isNotNull: return false
    }
  }

  private static func inItems(_ value: String) -> [String] {
    value.split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  private static let isoFormatter = ISO8601DateFormatter()

  /// Compares like the database would for the cell's type: dates by value (date-only literals by
  /// UTC day), UUIDs case-insensitively, booleans accepting t/f/1/0, numbers numerically,
  /// everything else by string order.
  private static func compare(_ cell: CellValue, _ rhs: String) -> ComparisonResult {
    let literal = rhs.trimmingCharacters(in: .whitespaces)
    switch cell {
    case .date(let date):
      if literal.count == 10, literal.dropFirst(4).first == "-" {
        return order(String(isoFormatter.string(from: date).prefix(10)), literal)
      }
      if let parsed = isoFormatter.date(from: literal) {
        return order(date.timeIntervalSince1970, parsed.timeIntervalSince1970)
      }
    case .bool(let flag):
      switch literal.lowercased() {
      case "true", "t", "1": return order(flag ? 1 : 0, 1)
      case "false", "f", "0": return order(flag ? 1 : 0, 0)
      default: break
      }
    case .string(let text) where UUID(uuidString: text) != nil:
      return order(text.lowercased(), literal.lowercased())
    default: break
    }
    return compare(cell.fullString, rhs)
  }

  private static func order<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
    lhs < rhs ? .orderedAscending : (lhs > rhs ? .orderedDescending : .orderedSame)
  }

  /// Numeric when both sides parse as numbers (not NaN), else string order
  private static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
    if let left = Double(lhs), let right = Double(rhs), !left.isNaN, !right.isNaN {
      return order(left, right)
    }
    return order(lhs, rhs)
  }

  /// SQL LIKE: `%` any run, `_` one character, everything else literal, anchored
  private static func like(_ text: String, pattern: String, insensitive: Bool) -> Bool {
    var regex = "^"
    for character in pattern {
      switch character {
      case "%": regex += "[\\s\\S]*"
      case "_": regex += "[\\s\\S]"
      default: regex += NSRegularExpression.escapedPattern(for: String(character))
      }
    }
    regex += "$"
    let options: NSRegularExpression.Options = insensitive ? [.caseInsensitive] : []
    guard let expression = try? NSRegularExpression(pattern: regex, options: options) else {
      return false
    }
    return expression.firstMatch(
      in: text, range: NSRange(text.startIndex..., in: text)) != nil
  }
}
