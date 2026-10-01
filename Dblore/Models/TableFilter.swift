//
//  TableFilter.swift
//  Dblore
//

import Foundation

/// Comparison operator of one filter condition
enum FilterOperator: String, Codable, CaseIterable {
  case equals, notEquals, like, notLike, ilike, notIlike
  case lessThan, lessThanOrEqual, greaterThan, greaterThanOrEqual
  case `in`, isNull, isNotNull

  var displayName: String {
    switch self {
    case .equals: return "equals"
    case .notEquals: return "does not equal"
    case .like: return "like"
    case .notLike: return "not like"
    case .ilike: return "ilike"
    case .notIlike: return "not ilike"
    case .lessThan: return "less than"
    case .lessThanOrEqual: return "less than or equal"
    case .greaterThan: return "greater than"
    case .greaterThanOrEqual: return "greater than or equal"
    case .in: return "in"
    case .isNull: return "is null"
    case .isNotNull: return "is not null"
    }
  }

  /// False for the null checks, which take no value
  var needsValue: Bool { self != .isNull && self != .isNotNull }
}

/// How a condition joins the previous one (unused on the first row)
enum FilterConnector: String, Codable {
  case and, or
}

/// One filter row: `column op value`
struct FilterCondition: Codable, Hashable, Identifiable {
  var id = UUID()
  var column: String = ""
  var op: FilterOperator = .equals
  var value: String = ""
  var connector: FilterConnector = .and

  /// Has a column and, when the operator takes one, a value
  var isComplete: Bool {
    !column.isEmpty && (!op.needsValue || !value.isEmpty)
  }
}

/// A list of conditions that becomes a WHERE clause (no grouping, standard AND/OR precedence)
struct TableFilter: Codable, Hashable {
  var conditions: [FilterCondition]

  var isEmpty: Bool { conditions.isEmpty }

  /// `a AND b OR c` over the complete conditions with literals escaped for `dialect`,
  /// nil when no condition is complete. The first complete row ignores its connector.
  func whereClause(dialect: SQLDialect) -> String? {
    var clause = ""
    for condition in conditions {
      guard let sql = Self.sql(for: condition, dialect: dialect) else { continue }
      if !clause.isEmpty {
        clause += condition.connector == .and ? " AND " : " OR "
      }
      clause += sql
    }
    return clause.isEmpty ? nil : clause
  }

  /// Dialect quoting, or the historical non-throwing quote when the name contains NUL.
  private static func quotedIdentifier(_ name: String, dialect: SQLDialect) -> String {
    do {
      return try dialect.quoteIdentifier(name)
    } catch {
      return CellUpdateStatement.quoteIdentifier(name)
    }
  }

  private static func sql(for condition: FilterCondition, dialect: SQLDialect) -> String? {
    guard condition.isComplete else { return nil }
    let column = quotedIdentifier(condition.column, dialect: dialect)
    let value = dialect.literal(.string(condition.value))
    switch condition.op {
    case .equals: return "\(column) = \(value)"
    case .notEquals: return "\(column) <> \(value)"
    case .lessThan: return "\(column) < \(value)"
    case .lessThanOrEqual: return "\(column) <= \(value)"
    case .greaterThan: return "\(column) > \(value)"
    case .greaterThanOrEqual: return "\(column) >= \(value)"
    case .isNull: return "\(column) IS NULL"
    case .isNotNull: return "\(column) IS NOT NULL"
    case .like, .notLike, .ilike, .notIlike:
      return likeSQL(column: column, value: value, op: condition.op, dialect: dialect)
    case .in:
      let items = condition.value.split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
      guard !items.isEmpty else { return nil }
      let list = items.map { dialect.literal(.string($0)) }.joined(separator: ", ")
      return "\(column) IN (\(list))"
    }
  }

  /// PostgreSQL casts to text and keeps `LIKE` vs `ILIKE`. SQLite is always `LIKE`.
  /// `caseInsensitiveLike` matches only the non-negated form of that text.
  private static func likeSQL(
    column: String, value: String, op: FilterOperator, dialect: SQLDialect
  ) -> String {
    let negated = op == .notLike || op == .notIlike
    let insensitive = op == .ilike || op == .notIlike
    if !negated && (insensitive || dialect.likeIsCaseInsensitive) {
      return dialect.caseInsensitiveLike(column: column, pattern: value)
    }
    let subject = dialect == .postgresql ? "\(column)::text" : column
    let keyword = dialect == .postgresql && insensitive ? "ILIKE" : "LIKE"
    return "\(subject) \(negated ? "NOT " : "")\(keyword) \(value)"
  }
}
