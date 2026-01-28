// DataModelSchemaTests.swift
// Unit tests for Database Schema data models (DatabaseTable, DatabaseView, DatabaseFunction, etc.)

import Foundation
import Testing

@testable import SQLNotebook

@Suite("Data Model - Database Schema Tests")
@MainActor
struct DataModelSchemaTests {

  // MARK: - DatabaseTable Tests

  @Test("DatabaseTable encoding and properties")
  func databaseTableProperties() {
    // Arrange
    let table = DatabaseTable(
      schema: "public",
      name: "users",
      columns: [
        DatabaseColumn(name: "id", type: "integer", isNullable: false, isPrimaryKey: true),
        DatabaseColumn(name: "email", type: "varchar", isNullable: false),
        DatabaseColumn(name: "created_at", type: "timestamp", isNullable: true),
      ],
      isExpanded: true,
      rowCount: 1234
    )

    // Assert
    #expect(table.schema == "public")
    #expect(table.name == "users")
    #expect(table.qualifiedName == "public.users")
    #expect(table.columns.count == 3)
    #expect(table.isExpanded == true)
    #expect(table.rowCount == 1234)
  }

  // MARK: - DatabaseColumn Type Icon Tests

  @Test("DatabaseColumn type icon mapping")
  func databaseColumnTypeIcons() {
    // Test primary key - must be tested first as it takes precedence
    let pkColumn = DatabaseColumn(name: "id", type: "integer", isPrimaryKey: true)
    #expect(pkColumn.typeIcon == "key")

    // Test numeric types (integers)
    let intColumn = DatabaseColumn(name: "age", type: "integer")
    #expect(intColumn.typeIcon == "textformat.123")

    // Test numeric types (decimals)
    let numericColumn = DatabaseColumn(name: "price", type: "numeric")
    #expect(numericColumn.typeIcon == "number")

    let decimalColumn = DatabaseColumn(name: "amount", type: "decimal")
    #expect(decimalColumn.typeIcon == "number")

    // Test text types
    let varcharColumn = DatabaseColumn(name: "name", type: "varchar")
    #expect(varcharColumn.typeIcon == "textformat")

    let textColumn = DatabaseColumn(name: "bio", type: "text")
    #expect(textColumn.typeIcon == "textformat")

    // Test boolean
    let boolColumn = DatabaseColumn(name: "active", type: "boolean")
    #expect(boolColumn.typeIcon == "checklist")

    // Test date/time
    let timestampColumn = DatabaseColumn(name: "created", type: "timestamp")
    #expect(timestampColumn.typeIcon == "calendar")

    let dateColumn = DatabaseColumn(name: "birthday", type: "date")
    #expect(dateColumn.typeIcon == "calendar")

    // Test JSON
    let jsonColumn = DatabaseColumn(name: "data", type: "jsonb")
    #expect(jsonColumn.typeIcon == "curlybraces")

    // Test UUID
    let uuidColumn = DatabaseColumn(name: "uuid", type: "uuid")
    #expect(uuidColumn.typeIcon == "number.square")

    // Test array
    let arrayColumn = DatabaseColumn(name: "tags", type: "text[]")
    #expect(arrayColumn.typeIcon == "list.bullet")

    // Test unknown type
    let unknownColumn = DatabaseColumn(name: "unknown", type: "custom_type")
    #expect(unknownColumn.typeIcon == "questionmark.circle")
  }

  // MARK: - DatabaseView Tests

  @Test("DatabaseView properties and qualified name")
  func databaseViewProperties() {
    // Arrange
    let view = DatabaseView(
      schema: "public",
      name: "active_users",
      columns: [
        DatabaseColumn(name: "id", type: "integer"),
        DatabaseColumn(name: "username", type: "varchar"),
      ],
      isExpanded: false,
      definition: "SELECT id, username FROM users WHERE active = true"
    )

    // Assert
    #expect(view.schema == "public")
    #expect(view.name == "active_users")
    #expect(view.qualifiedName == "public.active_users")
    #expect(view.columns.count == 2)
    #expect(view.definition != nil)
  }

  // MARK: - DatabaseFunction Tests

  @Test("DatabaseFunction signature formatting")
  func databaseFunctionSignature() {
    // Arrange
    let function = DatabaseFunction(
      schema: "public",
      name: "get_user_count",
      returnType: "integer",
      arguments: "start_date timestamp, end_date timestamp",
      definition: "BEGIN RETURN (SELECT COUNT(*) FROM users); END;"
    )

    // Assert
    #expect(function.schema == "public")
    #expect(function.name == "get_user_count")
    #expect(function.qualifiedName == "public.get_user_count")
    #expect(
      function.signature == "get_user_count(start_date timestamp, end_date timestamp) → integer")
  }

  // MARK: - DatabaseProcedure Tests

  @Test("DatabaseProcedure signature formatting")
  func databaseProcedureSignature() {
    // Arrange
    let procedure = DatabaseProcedure(
      schema: "public",
      name: "cleanup_old_records",
      arguments: "days_old integer",
      definition: "DELETE FROM logs WHERE created_at < NOW() - days_old * INTERVAL '1 day'"
    )

    // Assert
    #expect(procedure.qualifiedName == "public.cleanup_old_records")
    #expect(procedure.signature == "cleanup_old_records(days_old integer)")
  }

  // MARK: - DatabaseUser Tests

  @Test("DatabaseUser attributes display")
  func databaseUserAttributes() {
    // Test superuser
    let superuser = DatabaseUser(
      name: "postgres",
      canLogin: true,
      isSuperuser: true,
      canCreateDB: true,
      canCreateRole: true
    )
    #expect(superuser.attributes.contains("Superuser"))
    #expect(superuser.attributes.contains("Create DB"))
    #expect(superuser.attributes.contains("Create Role"))

    // Test regular user with no login
    let noLoginUser = DatabaseUser(
      name: "readonly",
      canLogin: false,
      connectionLimit: 5
    )
    #expect(noLoginUser.attributes.contains("No Login"))
    #expect(noLoginUser.attributes.contains("Limit: 5"))
  }

  // MARK: - DatabaseRole Tests

  @Test("DatabaseRole attributes display")
  func databaseRoleAttributes() {
    // Arrange
    let role = DatabaseRole(
      name: "developers",
      canLogin: true,
      canCreateDB: true,
      members: ["alice", "bob", "charlie"]
    )

    // Assert
    #expect(role.attributes.contains("Can Login"))
    #expect(role.attributes.contains("Create DB"))
    #expect(role.members.count == 3)
    #expect(role.members.contains("alice"))
  }
}
