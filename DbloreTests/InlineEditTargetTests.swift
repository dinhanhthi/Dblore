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
}
