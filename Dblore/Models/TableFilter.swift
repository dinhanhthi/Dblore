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
  nonisolated var needsValue: Bool { self != .isNull && self != .isNotNull }
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
  /// An empty string is a real value (a foreign-key jump), not a blank form row.
  var emptyStringIsValue = false
  /// One character for a LIKE's `ESCAPE` clause; nil renders no clause (the engine's default)
  var likeEscape: String? = nil

  /// Has a column and, when the operator takes one, a value.
  /// A blank value still counts when `emptyStringIsValue` is set. An empty column does not.
  nonisolated var isComplete: Bool {
    !column.isEmpty && (!op.needsValue || !value.isEmpty || emptyStringIsValue)
  }
}

extension FilterCondition {
  enum CodingKeys: String, CodingKey {
    case id, column, op, value, connector, emptyStringIsValue, likeEscape
  }

  /// `emptyStringIsValue` is absent on filters saved before that flag existed.
  nonisolated init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    column = try container.decode(String.self, forKey: .column)
    op = try container.decode(FilterOperator.self, forKey: .op)
    value = try container.decode(String.self, forKey: .value)
    connector = try container.decode(FilterConnector.self, forKey: .connector)
    emptyStringIsValue =
      try container.decodeIfPresent(Bool.self, forKey: .emptyStringIsValue) ?? false
    likeEscape = try container.decodeIfPresent(String.self, forKey: .likeEscape)
  }

  /// Same keys as the synthesized encoder, but nonisolated: with MainActor default isolation the
  /// synthesized one makes the `Encodable` conformance main-actor-isolated.
  nonisolated func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(column, forKey: .column)
    try container.encode(op, forKey: .op)
    try container.encode(value, forKey: .value)
    try container.encode(connector, forKey: .connector)
    try container.encode(emptyStringIsValue, forKey: .emptyStringIsValue)
    try container.encodeIfPresent(likeEscape, forKey: .likeEscape)
  }
}

/// A list of conditions that becomes a WHERE clause (no grouping, standard AND/OR precedence)
struct TableFilter: Codable, Hashable {
  var conditions: [FilterCondition]

  var isEmpty: Bool { conditions.isEmpty }

  /// How `whereClause` writes PostgreSQL: `qualified` (the SQL the app runs) names
  /// `pg_catalog`'s operators and casts, so nothing resolves through the user's `search_path`;
  /// `plain` is the readable text shown to the user (join builder, highlight summary). Other
  /// dialects write the same text either way.
  nonisolated enum Form: Sendable {
    case plain
    case qualified
  }

  /// `a AND b OR c` over the complete conditions with literals escaped for `dialect`,
  /// nil when no condition is complete. The first complete row ignores its connector.
  /// A `qualifier` (a table alias) prefixes every column: `"o"."c"`. `columnTypes` (column name
  /// → schema type text, `DatabaseColumn.type`) picks the operand kind of a qualified
  /// comparison; a column without one qualifies.
  nonisolated func whereClause(
    dialect: SQLDialect, qualifier: String? = nil, columnTypes: [String: String] = [:],
    form: Form = .qualified
  ) -> String? {
    var clause = ""
    for condition in conditions {
      guard
        let sql = Self.sql(
          for: condition, dialect: dialect, qualifier: qualifier, columnTypes: columnTypes,
          form: form)
      else {
        continue
      }
      if !clause.isEmpty {
        clause += condition.connector == .and ? " AND " : " OR "
      }
      clause += sql
    }
    return clause.isEmpty ? nil : clause
  }

  /// Dialect quoting, or the historical non-throwing quote when the name contains NUL.
  private nonisolated static func quotedIdentifier(_ name: String, dialect: SQLDialect) -> String {
    do {
      return try dialect.quoteIdentifier(name)
    } catch {
      return CellUpdateStatement.quoteIdentifier(name, dialect: dialect)
    }
  }

  private nonisolated static func sql(
    for condition: FilterCondition, dialect: SQLDialect, qualifier: String?,
    columnTypes: [String: String], form: Form
  ) -> String? {
    guard condition.isComplete else { return nil }
    let prefix = qualifier.map { quotedIdentifier($0, dialect: dialect) + "." } ?? ""
    let column = prefix + quotedIdentifier(condition.column, dialect: dialect)
    let value = dialect.literal(.string(condition.value))
    let escape = condition.likeEscape.map { dialect.literal(.string($0)) }
    if form == .qualified, dialect == .postgresql {
      return qualifiedSQL(
        op: condition.op, column: column, value: value, escape: escape,
        items: inItems(condition.value, dialect: dialect),
        operand: SQLOperandKind(columnType: columnTypes[condition.column]), dialect: dialect)
    }
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
      return likeSQL(
        column: column, value: value, escape: escape, op: condition.op, dialect: dialect)
    case .in:
      let list = inItems(condition.value, dialect: dialect)
      guard !list.isEmpty else { return nil }
      return "\(column) IN (\(list.joined(separator: ", ")))"
    }
  }

  /// The comma-separated `in` value as literals, trimmed, empty items dropped
  private nonisolated static func inItems(_ value: String, dialect: SQLDialect) -> [String] {
    value.split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .map { dialect.literal(.string($0)) }
  }

  /// PostgreSQL through the `SQLDialect` qualification helpers: `OPERATOR(pg_catalog.op)`
  /// (bare for a denylisted extension `operand`), `IN` as an OR chain, `LIKE` / `ILIKE` as
  /// `::pg_catalog.text OPERATOR(pg_catalog.~~)` with `pg_catalog.like_escape` for an escape
  private nonisolated static func qualifiedSQL(
    op: FilterOperator, column: String, value: String, escape: String?, items: [String],
    operand: SQLOperandKind, dialect: SQLDialect
  ) -> String? {
    func compare(_ comparison: SQLComparison) -> String {
      dialect.comparison(column, comparison, value, operand: operand)
    }
    switch op {
    case .equals: return compare(.equal)
    case .notEquals: return compare(.notEqual)
    case .lessThan: return compare(.less)
    case .lessThanOrEqual: return compare(.lessOrEqual)
    case .greaterThan: return compare(.greater)
    case .greaterThanOrEqual: return compare(.greaterOrEqual)
    case .isNull: return "\(column) IS NULL"
    case .isNotNull: return "\(column) IS NOT NULL"
    case .like, .notLike, .ilike, .notIlike:
      return dialect.like(
        column: column, pattern: value, escape: escape, negated: op == .notLike || op == .notIlike,
        caseInsensitive: op == .ilike || op == .notIlike)
    case .in:
      guard !items.isEmpty else { return nil }
      return dialect.inList(column, items, operand: operand)
    }
  }

  /// PostgreSQL (`::text`) and DuckDB (`::VARCHAR`) cast to text and keep `LIKE` vs `ILIKE`.
  /// SQLite and MySQL have no `ILIKE`: `ilike` is `caseInsensitiveLike` (both sides lowered),
  /// `notIlike` is `NOT LIKE`.
  private nonisolated static func likeSQL(
    column: String, value: String, escape: String?, op: FilterOperator, dialect: SQLDialect
  ) -> String {
    if op == .ilike {
      return dialect.caseInsensitiveLike(column: column, pattern: value, escape: escape)
    }
    let negated = op == .notLike || op == .notIlike
    let subject = dialect.likeSubject(column)
    let keyword = op == .notIlike && !dialect.likeIsCaseInsensitive ? "ILIKE" : "LIKE"
    let pattern = escape.map { "\(value) ESCAPE \($0)" } ?? value
    return "\(subject) \(negated ? "NOT " : "")\(keyword) \(pattern)"
  }
}
