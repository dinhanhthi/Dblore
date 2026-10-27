// JoinBuilderModel.swift
// The Build Join Query sheet's state: the picked tables in join order, each with its join kind,
// checked columns and filter rows, over the tables, columns and foreign keys the workspace's
// schema load read (taken when the sheet opens, so nothing is read here). The SQL is rebuilt by
// the pure `JoinQueryBuilder` on every read, so the preview follows every change.

import Foundation
import Observation

@Observable
@MainActor
final class JoinBuilderModel {
  /// One picked table as the sheet edits it
  struct Entry: Identifiable {
    let id = UUID()
    var table: DatabaseTable
    var kind: JoinQueryBuilder.JoinKind = .inner
    /// Checked column names; the SQL lists them in the table's column order
    var selected: Set<String> = []
    /// Starts with one blank row: the filter editor keeps at least one, and a blank one adds
    /// nothing to the WHERE clause
    var conditions = [FilterCondition()]

    var tableName: JoinQueryBuilder.TableName {
      JoinQueryBuilder.TableName(schema: table.schema, name: table.name)
    }

    var pick: JoinQueryBuilder.Pick {
      JoinQueryBuilder.Pick(
        table: tableName, kind: kind,
        columns: table.columns.map(\.name).filter(selected.contains),
        filter: TableFilter(conditions: conditions))
    }
  }

  let tables: [DatabaseTable]
  let foreignKeys: [ForeignKey]
  let dialect: SQLDialect
  var entries: [Entry]

  /// `initialTables` are picked in order: one for a table's menu, several for the ER diagram's
  /// selection, none for the File menu
  init(
    tables: [DatabaseTable], foreignKeys: [ForeignKey], dialect: SQLDialect,
    initialTables: [DatabaseTable] = []
  ) {
    self.tables = tables
    self.foreignKeys = foreignKeys
    self.dialect = dialect
    // A sidebar row may hold only the columns its filter matched: take the schema's own table
    entries = initialTables.map {
      Entry(table: Self.table(named: $0.schema, $0.name, in: tables) ?? $0)
    }
  }

  /// The query over the picks, or why none can be built
  var preview: Result<JoinQueryBuilder.Query, Error> {
    Result {
      try JoinQueryBuilder.query(
        picks: entries.map(\.pick), foreignKeys: foreignKeys, dialect: dialect)
    }
  }

  /// The names `add` takes, in the schema's order
  var tableNames: [JoinQueryBuilder.TableName] {
    tables.map { JoinQueryBuilder.TableName(schema: $0.schema, name: $0.name) }
  }

  var spansSchemas: Bool { Set(tables.map(\.schema)).count > 1 }

  /// Picks `name` last; a table picked again joins as a fresh copy (a self-join)
  func add(_ name: JoinQueryBuilder.TableName) {
    guard let table = Self.table(named: name.schema, name.name, in: tables) else { return }
    entries.append(Entry(table: table))
  }

  func remove(_ id: Entry.ID) {
    entries.removeAll { $0.id == id }
  }

  /// One place earlier in the join order; the first pick is the FROM table
  func moveUp(_ id: Entry.ID) {
    guard let index = entries.firstIndex(where: { $0.id == id }), index > 0 else { return }
    entries.swapAt(index, index - 1)
  }

  private static func table(
    named schema: String, _ name: String, in tables: [DatabaseTable]
  ) -> DatabaseTable? {
    tables.first { $0.schema == schema && $0.name == name }
  }
}

extension WorkspaceManager {
  /// Build Join Query: a connected SQL engine (not MongoDB) with its schema read since the last
  /// connect (the tables, columns and foreign keys the sheet joins)
  var canBuildJoinQuery: Bool {
    connectionState.isConnected && !isMongoWorkspace && schemaConnectionEpoch != nil
  }

  /// The sheet's model over this workspace's schema, picking `initialTables` in order
  func makeJoinBuilderModel(initialTables: [DatabaseTable] = []) -> JoinBuilderModel {
    JoinBuilderModel(
      tables: databaseTables, foreignKeys: databaseForeignKeys,
      dialect: workspace.connectionConfig?.databaseType.dialect ?? .postgresql,
      initialTables: initialTables)
  }
}
