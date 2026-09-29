//
//  DataViewerState.swift
//  SQLNotebook
//

import Foundation

/// State of a table/view data viewer tab: the relation, the current page and the SQL that
/// loads it (server-side LIMIT/OFFSET pagination plus an exact COUNT(*)).
struct DataViewerState: Equatable {
  /// Rows-per-page choices (all within the session row cap)
  static let pageSizes = [50, 100, 250, 500, 1000]

  var schema: String
  var name: String
  /// Columns of the ORDER BY (e.g. the primary key), empty for heap order
  var orderColumns: [String]
  /// 1-based page number
  var page: Int = 1
  var pageSize: Int = 100
  /// Exact row count, nil until COUNT(*) returned
  var totalRows: Int? = nil
  /// Result column names hidden in the grid
  var hiddenColumns: Set<String> = []
  /// Dialect of the connection, for literal escaping in the WHERE clause
  var databaseType: DatabaseType = .postgresql
  /// The applied filter
  var filter = TableFilter(conditions: [])
  /// The applied highlight: painted client-side, so not part of `LoadKey`
  var highlight = TableHighlight(filter: TableFilter(conditions: []))

  /// What a page load depends on; loads are coalesced while it is unchanged
  struct LoadKey: Hashable {
    let schema: String
    let name: String
    let page: Int
    let pageSize: Int
    let filter: TableFilter
  }

  var loadKey: LoadKey {
    LoadKey(schema: schema, name: name, page: page, pageSize: pageSize, filter: filter)
  }

  /// Tab title: `name` for the public (or no) schema, else `schema.name`
  var title: String {
    schema.isEmpty || schema == "public" ? name : "\(schema).\(name)"
  }

  /// Quoted `"schema"."name"` (or `"name"` without a schema)
  private var relation: String {
    let table = CellUpdateStatement.quoteIdentifier(name)
    return schema.isEmpty ? table : CellUpdateStatement.quoteIdentifier(schema) + "." + table
  }

  /// ` WHERE <clause>` for the applied filter, empty without a complete condition
  private var whereSQL: String {
    filter.whereClause(dialect: databaseType).map { " WHERE " + $0 } ?? ""
  }

  /// `SELECT * FROM rel [WHERE ...] [ORDER BY ...] LIMIT n [OFFSET m]` (OFFSET only after page 1)
  var pageSQL: String {
    var sql = "SELECT * FROM \(relation)\(whereSQL)"
    if !orderColumns.isEmpty {
      sql +=
        " ORDER BY " + orderColumns.map(CellUpdateStatement.quoteIdentifier).joined(separator: ", ")
    }
    sql += " LIMIT \(pageSize)"
    if page > 1 { sql += " OFFSET \((page - 1) * pageSize)" }
    return sql
  }

  var countSQL: String { "SELECT count(*) FROM \(relation)\(whereSQL)" }

  /// Number of pages (at least 1), nil while the total is unknown
  var pageCount: Int? {
    guard let totalRows else { return nil }
    return max(1, (totalRows + pageSize - 1) / pageSize)
  }

  var canGoPrevious: Bool { page > 1 }

  /// Next is allowed while the total is unknown
  var canGoNext: Bool {
    guard let pageCount else { return true }
    return page < pageCount
  }

  /// 1-based row numbers shown on this page, nil when no row was loaded
  func rowRange(loadedRows: Int) -> ClosedRange<Int>? {
    guard loadedRows > 0 else { return nil }
    let first = (page - 1) * pageSize + 1
    return first...(first + loadedRows - 1)
  }

  /// The count of a COUNT(*) result: first cell as an integer or numeric string
  static func total(from result: QueryResult) -> Int? {
    switch result.rows.first?.first {
    case .int(let value): return value
    case .string(let value): return Int(value)
    default: return nil
    }
  }
}
