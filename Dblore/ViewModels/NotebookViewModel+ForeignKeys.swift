//
//  NotebookViewModel+ForeignKeys.swift
//  Dblore
//
//  Referenced-row lookup for a data viewer tab or a single-table result.
//  The SELECT is user SQL: the protection gate binds it, and history does not store it.
//

import Foundation

extension NotebookViewModel {
  /// The referenced rows (at most two), or nil when nothing is looked up.
  /// Nil schema or table, no matching key, or a NULL component sends nothing — never `= NULL`.
  /// A connection or gate failure is thrown. The statement is not recorded.
  func lookupReferencedRow(
    column: String, schema: String?, table: String?, rowColumns: [String],
    values: [String: CellValue]
  ) async throws -> QueryResult? {
    guard
      let key = referencedKey(
        column: column, schema: schema, table: table, rowColumns: rowColumns),
      let query = ForeignKeyLookup.lookupSQL(for: key, values: values, dialect: sqlDialect)
    else { return nil }
    guard let connectionManager else { throw DatabaseError.notConnected }
    // LIMIT 2 is in the SQL. Cap the read at 2 so a smaller result cap cannot hide the second row.
    return try await connectionManager.execute(
      userSQL: query.sql, parameters: query.parameters, policy: protectionPolicy, maxRows: 2,
      caller: id)
  }

  /// Opens the referenced table in the data viewer, filtered to this row.
  /// False when there is no filter or no opener: nothing is opened.
  @discardableResult
  func jumpToReferencedRow(
    column: String, schema: String?, table: String?, rowColumns: [String],
    values: [String: CellValue]
  ) -> Bool {
    guard
      let key = referencedKey(
        column: column, schema: schema, table: table, rowColumns: rowColumns),
      let filter = ForeignKeyLookup.jumpFilter(for: key, values: values),
      let onOpenDataViewer
    else { return false }
    let order = referencedOrderColumns(schema: key.targetSchema, name: key.targetTable)
    onOpenDataViewer(key.targetSchema, key.targetTable, order, filter)
    return true
  }

  /// The key that owns `column` on `schema.table`, or nil when the relation or the key is missing.
  private func referencedKey(
    column: String, schema: String?, table: String?, rowColumns: [String]
  ) -> ForeignKey? {
    guard let schema, let table else { return nil }
    return ForeignKeyLookup.reference(
      for: column, schema: schema, table: table, foreignKeys: databaseForeignKeys,
      rowColumns: rowColumns)
  }

  /// Primary-key columns of a known table, else heap order. Same choice as the sidebar.
  private func referencedOrderColumns(schema: String, name: String) -> [String] {
    databaseTables.first { $0.schema == schema && $0.name == name }?
      .columns.filter(\.isPrimaryKey).map(\.name) ?? []
  }
}
