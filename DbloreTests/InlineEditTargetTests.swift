// InlineEditTargetTests.swift
// Inline edit is allowed only when every result column is a plain column of the target table
// (source table OID + attribute number from the RowDescription), so an edit can never be keyed
// by a value that came from another table or an expression.

import Foundation
import Testing

@testable import Dblore

@Suite("Inline Edit Target Tests")
struct InlineEditTargetTests {
  private static let ordersOID: UInt32 = 16_400
  private static let customersOID: UInt32 = 16_500

  /// orders(id PK = attnum 1, customer_id = 2, total = 3)
  private let orders = EditTable(
    oid: ordersOID, attributeNames: [1: "id", 2: "customer_id", 3: "total"],
    primaryKeyColumns: ["id"])

  private func column(_ name: String, _ oid: UInt32 = 0, _ attnum: Int16 = 0) -> ColumnInfo {
    ColumnInfo(name: name, type: "int4", tableOID: oid, attributeNumber: attnum)
  }

  @Test("SELECT * FROM orders is editable")
  func plainTableEditable() {
    let columns = [
      column("id", Self.ordersOID, 1), column("customer_id", Self.ordersOID, 2),
      column("total", Self.ordersOID, 3),
    ]
    #expect(CellUpdateStatement.editablePrimaryKey(columns: columns, table: orders) == ["id"])
  }

  @Test("Comma join: customers.id shadows orders.id -> not editable")
  func commaJoinNotEditable() {
    let columns = [
      column("id", Self.ordersOID, 1), column("customer_id", Self.ordersOID, 2),
      column("total", Self.ordersOID, 3), column("id", Self.customersOID, 1),
      column("name", Self.customersOID, 2),
    ]
    #expect(CellUpdateStatement.editablePrimaryKey(columns: columns, table: orders).isEmpty)
  }

  @Test("SELECT *, 5 AS id FROM orders -> not editable")
  func computedAliasNotEditable() {
    let columns = [
      column("id", Self.ordersOID, 1), column("customer_id", Self.ordersOID, 2),
      column("total", Self.ordersOID, 3), column("id"),
    ]
    #expect(CellUpdateStatement.editablePrimaryKey(columns: columns, table: orders).isEmpty)
  }

  @Test("Scalar subquery aliased as the PK -> not editable")
  func scalarSubqueryNotEditable() {
    let columns = [column("id"), column("total", Self.ordersOID, 3)]
    #expect(CellUpdateStatement.editablePrimaryKey(columns: columns, table: orders).isEmpty)
  }

  @Test("A real column aliased as another column's name -> not editable")
  func renamedColumnNotEditable() {
    // SELECT id, total AS customer_id FROM orders
    let columns = [column("id", Self.ordersOID, 1), column("customer_id", Self.ordersOID, 3)]
    #expect(CellUpdateStatement.editablePrimaryKey(columns: columns, table: orders).isEmpty)
  }

  @Test("PK column missing from the result -> not editable")
  func missingPrimaryKeyNotEditable() {
    let columns = [column("total", Self.ordersOID, 3)]
    #expect(CellUpdateStatement.editablePrimaryKey(columns: columns, table: orders).isEmpty)
  }

  @Test("No origin metadata (old result) or no table -> not editable")
  func missingMetadataNotEditable() {
    let columns = [ColumnInfo(name: "id", type: "int4"), ColumnInfo(name: "total", type: "int4")]
    #expect(CellUpdateStatement.editablePrimaryKey(columns: columns, table: orders).isEmpty)
    let plain = [column("id", Self.ordersOID, 1)]
    #expect(CellUpdateStatement.editablePrimaryKey(columns: plain, table: nil).isEmpty)
  }

  @Test("Table without primary key -> not editable")
  func noPrimaryKeyNotEditable() {
    let table = EditTable(oid: Self.ordersOID, attributeNames: [1: "id"], primaryKeyColumns: [])
    let columns = [column("id", Self.ordersOID, 1)]
    #expect(CellUpdateStatement.editablePrimaryKey(columns: columns, table: table).isEmpty)
  }

  /// `orders` with its catalog schema and name, as the server resolves it
  private var namedOrders: EditTable {
    EditTable(
      oid: Self.ordersOID, attributeNames: [1: "id", 2: "customer_id", 3: "total"],
      primaryKeyColumns: ["id"], connectionEpoch: 4, schema: "public", name: "orders")
  }

  @Test("Lookup relation: an alias maps to its base column, an expression maps to nothing")
  func lookupRelationMapsAliases() throws {
    // SELECT id, customer_id AS cid, 1 AS x FROM orders
    let columns = [
      column("id", Self.ordersOID, 1), column("cid", Self.ordersOID, 2), column("x"),
    ]
    let relation = try #require(
      CellUpdateStatement.lookupRelation(columns: columns, table: namedOrders))
    #expect(relation.schema == "public")
    #expect(relation.table == "orders")
    #expect(relation.baseColumns == ["id", "customer_id", nil])
    #expect(relation.connectionEpoch == 4)
    // Editing stays fail-closed for the same columns
    #expect(CellUpdateStatement.editablePrimaryKey(columns: columns, table: namedOrders).isEmpty)
  }

  @Test("Lookup relation: columns from two tables, no origin, or no catalog name -> none")
  func lookupRelationFailsClosed() {
    let join = [column("id", Self.ordersOID, 1), column("name", Self.customersOID, 2)]
    #expect(CellUpdateStatement.lookupRelation(columns: join, table: namedOrders) == nil)
    #expect(
      CellUpdateStatement.lookupRelation(columns: [column("x")], table: namedOrders) == nil)
    let plain = [column("cid", Self.ordersOID, 2)]
    #expect(CellUpdateStatement.lookupRelation(columns: plain, table: orders) == nil)
    #expect(CellUpdateStatement.lookupRelation(columns: plain, table: nil) == nil)
  }

  @Test("An aliased result gets a lookup relation and still no edit target")
  @MainActor
  func aliasedResultLooksUpButStaysReadOnly() async {
    let orders = TableRef.postgresql(oid: Self.ordersOID)
    let manager = DatabaseConnectionManager()
    var table = namedOrders
    table.qualifiedName = "public.orders"
    table.connectionEpoch = 0
    await manager.seedPausedEditTable(table, id: orders)
    let columns = [
      ColumnInfo(
        name: "id", type: "int4", origin: ColumnOrigin(tableID: orders, columnOrdinal: 1)),
      ColumnInfo(
        name: "cid", type: "int4", origin: ColumnOrigin(tableID: orders, columnOrdinal: 2)),
      ColumnInfo(name: "x", type: "int4"),
    ]
    let result = QueryResult(
      columns: columns, rows: [[.int(1), .int(9), .int(1)]], rowCount: 1, executionTime: 0)
    let targets = await NotebookViewModel().resultTargets(
      for: "SELECT id, customer_id AS cid, 1 AS x FROM orders", result: result,
      connectionManager: manager, epoch: 0)
    #expect(targets.editTarget == nil)
    #expect(targets.lookupRelation?.baseColumns == ["id", "customer_id", nil])
  }

  @Test("A pending transaction resolves the edit target from the column table identity")
  @MainActor
  func pendingTransactionResolvesColumnTableIdentity() async {
    let orders = TableRef.postgresql(oid: Self.ordersOID)
    let target = await cachedTarget(cachedID: orders, columnID: orders)
    #expect(target?.tableID == orders)
    #expect(target?.primaryKeyColumns == ["id"])
    #expect(target?.qualifiedName == "public.orders")
  }

  @Test("The edit-table cache does not match a different table identity")
  @MainActor
  func cacheDoesNotMatchADifferentTableIdentity() async {
    let orders = TableRef.postgresql(oid: Self.ordersOID)
    let customers = TableRef.postgresql(oid: Self.customersOID)
    #expect(await cachedTarget(cachedID: customers, columnID: orders) == nil)
  }

  /// Catalog lookup is paused. The only stored table is `cachedID`; columns name `columnID`.
  @MainActor
  private func cachedTarget(cachedID: TableRef, columnID: TableRef) async -> EditTarget? {
    let manager = DatabaseConnectionManager()
    let table = EditTable(
      oid: Self.ordersOID,
      attributeNames: [1: "id", 2: "customer_id", 3: "total"],
      primaryKeyColumns: ["id"],
      qualifiedName: "public.orders",
      connectionEpoch: 0,
      updateOnly: true)
    await manager.seedPausedEditTable(table, id: cachedID)
    let columns = [
      ColumnInfo(
        name: "id", type: "int4", origin: ColumnOrigin(tableID: columnID, columnOrdinal: 1)),
      ColumnInfo(
        name: "total", type: "int4", origin: ColumnOrigin(tableID: columnID, columnOrdinal: 3)),
    ]
    let result = QueryResult(
      columns: columns, rows: [[.int(1), .int(9)]], rowCount: 1, executionTime: 0)
    return await NotebookViewModel().editTarget(
      for: "SELECT id, total FROM orders", result: result, connectionManager: manager, epoch: 0)
  }
}

extension DatabaseConnectionManager {
  /// Pauses catalog lookup and stores one edit table under `id`.
  fileprivate func seedPausedEditTable(_ table: EditTable, id: TableRef) {
    txState = .appTx(pending: [])
    editTableCache = [id: table]
  }
}
