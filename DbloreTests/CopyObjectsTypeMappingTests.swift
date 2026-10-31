// CopyObjectsTypeMappingTests.swift
// CopyObjectsTypeMapping: the lossy or risky mappings only (boolean, the binary bind form, uuid,
// timestamptz on MySQL, arrays / LIST / STRUCT / MAP to JSON text, identity, unbounded text in a
// MySQL key, unknown and user types to text with a warning, MySQL BIT and spatial types as bytes),
// escaped string defaults across engines, and the MySQL source read of BIT, spatial and decimal
// key columns.

import Foundation
import Testing

@testable import Dblore

@Suite("CopyObjectsTypeMappingTests")
struct CopyObjectsTypeMappingTests {
  typealias Engine = StructureDDLBuilder.Engine
  typealias Mapping = CopyObjectsTypeMapping

  static let mysql = Engine.mysql(MySQLServerInfo(flavor: .mysql, major: 8, minor: 0, patch: 36))
  static let sqlite = Engine.sqlite(libraryVersion: 3_045_000)

  struct Case: Sendable, CustomTestStringConvertible {
    var label: String
    var column: TableStructure.Column
    var context = Mapping.Context(primaryKey: [], leadsKey: false, isKeyed: false)
    var source: Engine
    var target: Engine
    var type: String
    var bindForm = Mapping.BindForm.plain
    var valueForm = Mapping.ValueForm.asIs
    var identity: Mapping.IdentityForm?
    var warns: Bool

    var testDescription: String { label }
  }

  static func column(
    _ type: String, columnType: String? = nil, default text: String? = nil,
    identity: TableStructure.Identity? = nil
  ) -> TableStructure.Column {
    TableStructure.Column(
      ordinal: 1, name: "c", dataType: type, isNullable: true, defaultExpression: text,
      identity: identity, columnType: columnType)
  }

  static let keyed = Mapping.Context(primaryKey: [], leadsKey: false, isKeyed: true)
  static let soleKey = Mapping.Context(primaryKey: ["c"], leadsKey: true, isKeyed: true)
  static let compositeKey = Mapping.Context(
    primaryKey: ["c", "d"], leadsKey: true, isKeyed: true)

  static let cases: [Case] = [
    // Boolean
    Case(
      label: "PostgreSQL boolean to MySQL", column: column("boolean"), source: .postgresql,
      target: mysql, type: "TINYINT(1)", valueForm: .boolean, warns: false),
    Case(
      label: "PostgreSQL boolean to SQLite", column: column("boolean"), source: .postgresql,
      target: sqlite, type: "INTEGER", valueForm: .boolean, warns: false),
    Case(
      label: "MySQL tinyint(1) to PostgreSQL",
      column: column("tinyint", columnType: "tinyint(1)", default: "1"), source: mysql,
      target: .postgresql, type: "boolean", valueForm: .boolean, warns: false),
    // Binary bind form
    Case(
      label: "PostgreSQL bytea to MySQL", column: column("bytea"), source: .postgresql,
      target: mysql, type: "LONGBLOB", bindForm: .mysqlUnhex, warns: false),
    Case(
      label: "SQLite BLOB to PostgreSQL", column: column("BLOB"), source: sqlite,
      target: .postgresql, type: "bytea", bindForm: .postgresHexDecode, warns: false),
    Case(
      label: "MySQL longblob to SQLite", column: column("longblob", columnType: "longblob"),
      source: mysql, target: sqlite, type: "BLOB", bindForm: .sqliteHexLiteral, warns: false),
    Case(
      label: "PostgreSQL bytea kept on PostgreSQL", column: column("bytea"), source: .postgresql,
      target: .postgresql, type: "bytea", bindForm: .postgresHexDecode, warns: false),
    // uuid
    Case(
      label: "PostgreSQL uuid to MySQL", column: column("uuid"), source: .postgresql,
      target: mysql, type: "CHAR(36)", valueForm: .uuid, warns: false),
    Case(
      label: "DuckDB UUID to SQLite", column: column("UUID"), source: .duckdb, target: sqlite,
      type: "TEXT", valueForm: .uuid, warns: false),
    // timestamptz
    Case(
      label: "PostgreSQL timestamptz to MySQL", column: column("timestamp(3) with time zone"),
      source: .postgresql, target: mysql, type: "DATETIME(6)", valueForm: .timestampUTC,
      warns: true),
    // Arrays and DuckDB nested types
    Case(
      label: "PostgreSQL array to MySQL", column: column("integer[]"), source: .postgresql,
      target: mysql, type: "JSON", valueForm: .jsonText, warns: true),
    Case(
      label: "PostgreSQL array kept on PostgreSQL", column: column("text[]"),
      source: .postgresql, target: .postgresql, type: "text[]", warns: false),
    Case(
      label: "DuckDB LIST to PostgreSQL", column: column("INTEGER[]"), source: .duckdb,
      target: .postgresql, type: "jsonb", valueForm: .jsonText, warns: true),
    Case(
      label: "DuckDB STRUCT to SQLite", column: column("STRUCT(a INTEGER, b VARCHAR)"),
      source: .duckdb, target: sqlite, type: "TEXT", valueForm: .jsonText, warns: true),
    Case(
      label: "DuckDB MAP to MySQL", column: column("MAP(VARCHAR, INTEGER)"), source: .duckdb,
      target: mysql, type: "JSON", valueForm: .jsonText, warns: true),
    // Identity
    Case(
      label: "PostgreSQL serial kept as identity",
      column: column("integer", default: "nextval('t_c_seq'::regclass)"), context: soleKey,
      source: .postgresql, target: .postgresql, type: "integer GENERATED BY DEFAULT AS IDENTITY",
      identity: .generatedByDefault, warns: false),
    Case(
      label: "PostgreSQL identity always to MySQL",
      column: column("bigint", identity: .always), context: soleKey, source: .postgresql,
      target: mysql, type: "bigint AUTO_INCREMENT", identity: .autoIncrement, warns: false),
    Case(
      label: "SQLite INTEGER PRIMARY KEY to PostgreSQL", column: column("INTEGER"),
      context: soleKey, source: sqlite, target: .postgresql,
      type: "bigint GENERATED BY DEFAULT AS IDENTITY", identity: .generatedByDefault,
      warns: false),
    Case(
      label: "MySQL AUTO_INCREMENT to SQLite",
      column: column("int", columnType: "int unsigned", identity: .autoIncrement),
      context: soleKey, source: mysql, target: sqlite, type: "INTEGER", identity: .rowid,
      warns: false),
    Case(
      label: "Identity in a composite key on SQLite loses its numbering",
      column: column("integer", identity: .byDefault), context: compositeKey,
      source: .postgresql, target: sqlite, type: "INTEGER", warns: true),
    // Unbounded text on a MySQL target
    Case(
      label: "PostgreSQL text in a key to MySQL", column: column("text"), context: keyed,
      source: .postgresql, target: mysql, type: "VARCHAR(255)", warns: true),
    Case(
      label: "PostgreSQL text outside keys to MySQL", column: column("text"),
      source: .postgresql, target: mysql, type: "LONGTEXT", warns: false),
    Case(
      label: "PostgreSQL varchar without a length to MySQL", column: column("character varying"),
      source: .postgresql, target: mysql, type: "VARCHAR(255)", warns: true),
    Case(
      label: "SQLite TEXT in a key to MySQL", column: column("TEXT"), context: keyed,
      source: sqlite, target: mysql, type: "VARCHAR(255)", warns: true),
    // Unknown and user types
    Case(
      label: "PostgreSQL inet to MySQL", column: column("inet"), source: .postgresql,
      target: mysql, type: "LONGTEXT", warns: true),
    Case(
      label: "PostgreSQL user type kept on PostgreSQL as text",
      column: column("mood", default: "'happy'::mood"), source: .postgresql,
      target: .postgresql, type: "text", warns: true),
    Case(
      label: "DuckDB INTERVAL to SQLite", column: column("INTERVAL"), source: .duckdb,
      target: sqlite, type: "TEXT", warns: true),
    // MySQL BIT and spatial types: bytes
    Case(
      label: "MySQL bit kept on MySQL", column: column("bit", columnType: "bit(8)"),
      source: mysql, target: mysql, type: "bit(8)", bindForm: .mysqlUnhex, warns: false),
    Case(
      label: "MySQL bit to PostgreSQL", column: column("bit", columnType: "bit(1)"),
      source: mysql, target: .postgresql, type: "bytea", bindForm: .postgresHexDecode,
      warns: true),
    Case(
      label: "MySQL geometry kept on MySQL", column: column("geometry", columnType: "geometry"),
      source: mysql, target: mysql, type: "geometry", bindForm: .mysqlUnhex, warns: false),
    Case(
      label: "MySQL point to SQLite", column: column("point", columnType: "point"),
      source: mysql, target: sqlite, type: "BLOB", bindForm: .sqliteHexLiteral, warns: true),
  ]

  @Test("Risky mappings", arguments: cases)
  func mapping(_ test: Case) throws {
    let mapped = try Mapping.map(
      test.column, context: test.context, from: test.source, to: test.target)
    #expect(mapped.type == test.type)
    #expect(mapped.bindForm == test.bindForm)
    #expect(mapped.valueForm == test.valueForm)
    #expect(mapped.identity == test.identity)
    #expect(mapped.warnings.isEmpty == !test.warns, "\(mapped.warnings)")
  }

  @Test("Defaults: a boolean literal is restated, an identity's nextval and a user type's cast go")
  func defaults() throws {
    let boolean = try Mapping.map(
      Self.column("tinyint", columnType: "tinyint(1)", default: "1"),
      context: .init(primaryKey: [], leadsKey: false, isKeyed: false), from: Self.mysql,
      to: .postgresql)
    #expect(boolean.defaultExpression == "TRUE")
    let serial = try Mapping.map(
      Self.column("integer", default: "nextval('t_c_seq'::regclass)"), context: Self.soleKey,
      from: .postgresql, to: .postgresql)
    #expect(serial.defaultExpression == nil)
    let userType = try Mapping.map(
      Self.column("mood", default: "'happy'::mood"),
      context: .init(primaryKey: [], leadsKey: false, isKeyed: false), from: .postgresql,
      to: .postgresql)
    #expect(userType.defaultExpression == "'happy'")
  }

  @Test("Across engines a string default with backslash escapes is dropped")
  func escapedDefaults() throws {
    let none = Mapping.Context(primaryKey: [], leadsKey: false, isKeyed: false)
    let mysqlEscaped = try Mapping.map(
      Self.column("varchar", columnType: "varchar(10)", default: #"'a\\b'"#), context: none,
      from: Self.mysql, to: .postgresql)
    #expect(mysqlEscaped.defaultExpression == nil)
    #expect(!mysqlEscaped.warnings.isEmpty)
    let postgresEscaped = try Mapping.map(
      Self.column("text", default: #"E'a\nb'::text"#), context: none, from: .postgresql,
      to: Self.sqlite)
    #expect(postgresEscaped.defaultExpression == nil)
    let plain = try Mapping.map(
      Self.column("varchar", columnType: "varchar(10)", default: "'ab'"), context: none,
      from: Self.mysql, to: .postgresql)
    #expect(plain.defaultExpression == "'ab'")
    // The same engine keeps the text as it is
    let kept = try Mapping.map(
      Self.column("varchar", columnType: "varchar(10)", default: #"'a\\b'"#), context: none,
      from: Self.mysql, to: Self.mysql)
    #expect(kept.defaultExpression == #"'a\\b'"#)
  }

  @Test("MySQL source: BIT and spatial columns are read as hex; decimal keys bind as decimals")
  func mysqlReads() throws {
    let source = TableStructure(
      tableID: .sqlite(schema: "shop", table: "t"), schema: "shop", name: "t",
      columns: [
        TableStructure.Column(
          ordinal: 1, name: "k", dataType: "decimal", isNullable: false,
          columnType: "decimal(10,2)"),
        TableStructure.Column(
          ordinal: 2, name: "b", dataType: "bit", isNullable: true, columnType: "bit(8)"),
        TableStructure.Column(
          ordinal: 3, name: "g", dataType: "geometry", isNullable: true, columnType: "geometry"),
      ],
      indexes: [],
      constraints: [TableStructure.Constraint(name: nil, kind: .primaryKey, columns: ["k"])])
    for target in [Self.mysql, Engine.postgresql] {
      let plan = try CopyObjectsPlanner.plan(
        [.init(structure: source)], source: Self.mysql, target: target, targetSchema: "copy",
        existingNames: [])
      let read = try CopyObjectsTableRead(plan.tables[0], source: Self.mysql, target: target)
      #expect(
        read.select(after: ["1.50"], offset: 0, limit: 7).sql
          == "SELECT CONCAT('v', CAST(`k` AS CHAR)), CONCAT('v', HEX(`b`)), "
          + "CONCAT('v', HEX(`g`)), CONCAT('v', CAST(`k` AS CHAR)) FROM `shop`.`t` "
          + "WHERE `k` > CAST(? AS DECIMAL(10,2)) ORDER BY `k` LIMIT 7")
    }
  }

  @Test("Bind forms write the decoding around the placeholder")
  func bindFragments() {
    #expect(Mapping.BindForm.postgresHexDecode.fragment(placeholder: "$3") == "decode($3, 'hex')")
    #expect(Mapping.BindForm.mysqlUnhex.fragment(placeholder: "?") == "UNHEX(?)")
    #expect(Mapping.BindForm.sqliteHexLiteral.fragment(placeholder: "?1") == nil)
    #expect(Mapping.sqliteHexLiteral(Data([0x00, 0xAB, 0xFF])) == "X'00ABFF'")
  }

  @Test("DuckDB is never a target")
  func duckdbTarget() {
    #expect(throws: StructureDDLError.self) {
      try Mapping.map(
        Self.column("integer"), context: .init(primaryKey: [], leadsKey: false, isKeyed: false),
        from: .postgresql, to: .duckdb)
    }
  }
}
