//
//  TableFilter.swift
//  SQLNotebook
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
  func whereClause(dialect: DatabaseType) -> String? {
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

  private static func literal(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
  }

  private static func sql(for condition: FilterCondition, dialect: DatabaseType) -> String? {
    guard condition.isComplete else { return nil }
    let column = CellUpdateStatement.quoteIdentifier(condition.column)
    let value = literal(condition.value)
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
      let negated = condition.op == .notLike || condition.op == .notIlike
      let insensitive = condition.op == .ilike || condition.op == .notIlike
      let keyword: String
      let subject: String
      if dialect == .postgresql {
        keyword = insensitive ? "ILIKE" : "LIKE"
        subject = "\(column)::text"
      } else {
        keyword = "LIKE"
        subject = column
      }
      return "\(subject) \(negated ? "NOT " : "")\(keyword) \(value)"
    case .in:
      let items = condition.value.split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
      guard !items.isEmpty else { return nil }
      return "\(column) IN (\(items.map(literal).joined(separator: ", ")))"
    }
  }
}
