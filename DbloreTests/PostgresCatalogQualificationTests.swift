// PostgresCatalogQualificationTests.swift
// Catalog reads run on the user's session with the user's search_path. PostgreSQL resolves an
// unqualified function or operator over every schema on the path and prefers an exact-type match
// to a pg_catalog candidate that needs a cast, so every catalog statement names pg_catalog for
// each relation, function, operator, cast type and regclass literal. Each introspector entry point
// runs against a fake session that records its SQL; each statement is linted token by token.

import Foundation
import Testing

@testable import Dblore

@Suite("PostgreSQL catalog reads are pg_catalog-qualified")
struct PostgresCatalogQualificationTests {
  private let introspector = PostgresSchemaIntrospector()

  /// One entry point: the rows the fake answers every statement with (enough to reach the
  /// follow-up reads), the number of statements it sends, and the call.
  private struct EntryPoint {
    let name: String
    var rows: [[CellValue]] = []
    let statements: Int
    let run: (any DatabaseSession) async throws -> Void
  }

  /// Entry points that bind a user-typed table name and resolve it through the session's
  /// search_path on purpose (`pg_catalog.to_regclass($1)`), with the reason.
  private static let boundNameLookups: [String: String] = [
    "editTable": "the name comes from the user's query, so it resolves as the user's SQL does",
    "viewEditCandidate": "the view name comes from the user's query, resolved as in editTable",
    "primaryKeyColumns": "the name is the user's table, resolved as the user's SQL resolves it",
  ]

  // Every method of PostgresSchemaIntrospector (and its +Structure extension) that takes a
  // session, checked by grepping `session: any DatabaseSession` in both files: tables,
  // allColumns, views, functions, procedures, triggers, definition(of:) (routineDefinition for
  // functions and procedures, the trigger read, no SQL for sequences and user types), users,
  // roles, sequences, userTypes, foreignKeys, editTable, viewEditCandidate, enrichColumnTypes
  // (through enrichedColumns), rowCount, primaryKeyColumns, tableStructure (structureColumns,
  // structureIndexes, structureConstraints) and the `rows` helper they all use. The list below
  // matches it.
  private var entryPoints: [EntryPoint] {
    let introspector = introspector
    let function = DatabaseFunction(schema: "public", name: "f", returnType: "int", oid: 7)
    let trigger = DatabaseTrigger(
      schema: "public", table: "t", name: "tr", timing: .before, events: [.insert],
      enabled: true, oid: 8)
    let column = ColumnInfo(name: "v", type: "NUMERIC", tableOID: 16_400, attributeNumber: 1)
    return [
      EntryPoint(name: "tables", statements: 1) { _ = try await introspector.tables(in: $0) },
      EntryPoint(name: "allColumns", statements: 1) {
        _ = try await introspector.allColumns(in: $0)
      },
      EntryPoint(name: "views", statements: 1) { _ = try await introspector.views(in: $0) },
      EntryPoint(name: "functions", statements: 1) {
        _ = try await introspector.functions(in: $0)
      },
      EntryPoint(name: "procedures", statements: 1) {
        _ = try await introspector.procedures(in: $0)
      },
      EntryPoint(name: "triggers", statements: 1) { _ = try await introspector.triggers(in: $0) },
      EntryPoint(name: "definition(function)", statements: 1) {
        _ = try await introspector.definition(of: .function(function), in: $0)
      },
      EntryPoint(name: "definition(trigger)", statements: 1) {
        _ = try await introspector.definition(of: .trigger(trigger), in: $0)
      },
      EntryPoint(name: "users", statements: 1) { _ = try await introspector.users(in: $0) },
      EntryPoint(name: "roles", statements: 1) { _ = try await introspector.roles(in: $0) },
      EntryPoint(name: "sequences", statements: 1) {
        _ = try await introspector.sequences(in: $0)
      },
      EntryPoint(name: "userTypes", statements: 1) {
        _ = try await introspector.userTypes(in: $0)
      },
      EntryPoint(name: "foreignKeys", statements: 1) {
        _ = try await introspector.foreignKeys(in: $0)
      },
      EntryPoint(name: "editTable", statements: 1) {
        _ = try await introspector.editTable(named: "public.orders", in: $0)
      },
      EntryPoint(name: "viewEditCandidate", statements: 1) {
        _ = try await introspector.viewEditCandidate(named: "public.v1", in: $0)
      },
      EntryPoint(name: "enrichColumnTypes", statements: 1) {
        _ = await introspector.enrichColumnTypes(
          [column], query: "SELECT * FROM public.orders", in: $0)
      },
      EntryPoint(name: "rowCount", statements: 1) {
        _ = try await introspector.rowCount(schema: "public", table: "orders", in: $0)
      },
      EntryPoint(name: "primaryKeyColumns", statements: 1) {
        _ = try await introspector.primaryKeyColumns(of: "public.orders", in: $0)
      },
      // The oid row lets the table be found, so the column, index and constraint reads run
      // (they skip a row this short)
      EntryPoint(name: "tableStructure", rows: [[.int(16_400), .string("c")]], statements: 4) {
        _ = try await introspector.tableStructure(schema: "public", table: "orders", in: $0)
      },
    ]
  }

  @Test("Every introspector statement names pg_catalog for each catalog object it uses")
  func introspectorStatementsAreQualified() async throws {
    for entry in entryPoints {
      let session = FakeDatabaseSession(
        capabilities: .contract(), columns: [], rows: entry.rows, slowQueries: false)
      try await entry.run(session)
      #expect(
        session.statements.count == entry.statements,
        "\(entry.name) sent \(session.statements.count) statements")
      let allowsLookup = Self.boundNameLookups[entry.name] != nil
      for sql in session.statements {
        let found = CatalogSQLLint.violations(sql, allowsBoundNameLookup: allowsLookup)
        #expect(found.isEmpty, "\(entry.name): \(found.joined(separator: "; "))\n\(sql)")
      }
    }
  }

  /// A restore script that drops tables and a type, so the probe reads every branch
  private static let restoreDropDump =
    ([
      SQLDumpAssembler.header(
        engine: .postgresql, created: Date(timeIntervalSince1970: 1_760_000_000), version: 2),
      "CREATE SCHEMA IF NOT EXISTS \"app\";",
      "DROP TABLE IF EXISTS \"app\".\"events\";",
      "DROP TYPE IF EXISTS \"app\".\"mood\";",
      "CREATE TYPE \"app\".\"mood\" AS ENUM ('ok');",
      "CREATE TABLE \"app\".\"events\" (\"at\" date);",
    ] as [String]).map { $0 + "\n" }.joined()

  /// App-owned PostgreSQL reads outside the introspector, each through a manager on a fake
  /// session: the rows it is answered with, the statements it sends, and the call.
  private struct ManagerRead {
    let name: String
    var rows: [[CellValue]] = []
    let statements: Int
    let run: (DatabaseConnectionManager) async throws -> Void
  }

  private var managerReads: [ManagerRead] {
    let open = ProtectionPolicy(protectionLevel: .none)
    let structure = TableStructure(
      tableID: .postgresql(oid: 16_400), schema: "public", name: "orders", columns: [],
      indexes: [], constraints: [])
    let lookup = StagedIntegerKey.lookupSQL(
      schema: "public", table: "orders", column: "id", dialect: .postgresql)
    return [
      // An inherits row makes the probe refuse the restore, so nothing else is sent
      ManagerRead(
        name: "restore drop targets",
        rows: [["inherits", "app", "events", "app", "events_2024"].map { .string($0) }],
        statements: 1
      ) { manager in
        _ = try? await manager.executeGatedRestore(
          script: Self.restoreDropDump, policy: open,
          connectionEpoch: await manager.connectionEpoch)
      },
      ManagerRead(
        name: "generate rows enum labels", rows: [[.string("v"), .string("ok")]], statements: 1
      ) { _ = try await $0.readGenerateRowsEnumLabels(structure) },
      // The schema row lets the names read run
      ManagerRead(name: "copy target names", rows: [[.string("public")]], statements: 2) {
        _ = try await $0.copyTargetNames()
      },
      ManagerRead(name: "staged integer key", rows: [[.bool(false), .int(3)]], statements: 1) {
        _ = try await $0.executeInternal(try #require(lookup), maxRows: 1)
      },
    ]
  }

  @Test("App-owned PostgreSQL reads outside the introspector are qualified")
  func managerReadsAreQualified() async throws {
    for read in managerReads {
      let factory = FakeDatabaseSessionFactory(
        capabilities: DatabaseType.postgresql.capabilities, rows: read.rows)
      let manager = DatabaseConnectionManager(sessionFactory: factory)
      try await manager.connect(
        config: ConnectionConfig(
          databaseType: .postgresql, host: "fake", port: 5432, database: "db", username: "u",
          sslMode: .disable, protectionLevel: .none, safeMode: .silent, protectedMode: false))
      try await read.run(manager)
      let sent = factory.statements
      #expect(sent.count == read.statements, "\(read.name) sent \(sent.count) statements: \(sent)")
      for sql in sent {
        let found = CatalogSQLLint.violations(sql)
        #expect(found.isEmpty, "\(read.name): \(found.joined(separator: "; "))\n\(sql)")
      }
      await manager.disconnect()
    }
  }

  @Test("Static catalog SQL sent outside a session's query is qualified")
  func staticCatalogSQLIsQualified() throws {
    let drops = SQLRestorePlan.PostgresDrops(
      tables: [[Array("app".utf8), Array("t".utf8)]],
      types: [[Array("app".utf8), Array("e".utf8)]],
      createdSequences: [])
    var tablesOnly = drops
    tablesOnly.types = []
    var typesOnly = drops
    typesOnly.tables = []
    // One identity column (a nextval default copies as GENERATED BY DEFAULT AS IDENTITY)
    var identity = TableStructure.Column(
      ordinal: 1, name: "id", dataType: "integer", isNullable: false)
    identity.defaultExpression = "nextval('s'::regclass)"
    let copy = try CopyObjectsPlanner.plan(
      [
        CopyObjectsPlanner.SourceTable(
          structure: TableStructure(
            tableID: .postgresql(oid: 16_400), schema: "public", name: "orders",
            columns: [identity], indexes: [],
            constraints: [.init(name: nil, kind: .primaryKey, columns: ["id"])]))
      ], source: .postgresql, target: .postgresql, targetSchema: "app", existingNames: [])
    let restarts = try copy.identityRestartStatements()
    #expect(restarts.count == 1)
    let statements: [(String, String)] = [
      ("viewerExtensionTypesSQL", DatabaseConnectionManager.viewerExtensionTypesSQL),
      // Run on the raw connection at open and on the cancel side connection
      ("sessionIdentitySQL", PostgresSession.sessionIdentitySQL),
      ("cancelBackendSQL", PostgresSession.cancelBackendSQL),
      ("postgresDropTargetsQuery", DatabaseConnectionManager.postgresDropTargetsQuery(drops)),
      ("drop targets, tables", DatabaseConnectionManager.postgresDropTargetsQuery(tablesOnly)),
      ("drop targets, types", DatabaseConnectionManager.postgresDropTargetsQuery(typesOnly)),
      (
        "staged integer key",
        try #require(
          StagedIntegerKey.lookupSQL(
            schema: "public", table: "orders", column: "id", dialect: .postgresql))
      ),
      // An editable view's body, on the side connection of its probe
      ("view definition", PostgresSchemaIntrospector.viewDefinitionSQL),
      // Mask rule origins of a user result, by its table OIDs
      ("mask origin lookup", DatabaseConnectionManager.maskOriginSQL),
      // Run on the target session after the copied rows
      ("copy identity restart", try #require(restarts.first)),
      // Table Health, on a side connection
      ("table health statistics state", TableHealthQueries.postgresStatisticsStateSQL),
      ("table health unused indexes", TableHealthQueries.postgresUnusedIndexesSQL),
      ("table health dead tuples", TableHealthQueries.postgresDeadTuplesSQL),
      // A PostgreSQL restore's search_path read, pin and put-back, on the user's session
      ("restore search_path read", DatabaseConnectionManager.SearchPathPin.readSQL),
      ("restore search_path pin", DatabaseConnectionManager.SearchPathPin.pinSQL),
      ("restore search_path put-back", DatabaseConnectionManager.SearchPathPin.putBackSQL),
    ]
    for (name, sql) in statements {
      let found = CatalogSQLLint.violations(sql)
      #expect(found.isEmpty, "\(name): \(found.joined(separator: "; "))\n\(sql)")
    }
  }

  @Test("The lint flags each unqualified form and accepts the qualified one")
  func lintFlagsUnqualifiedForms() {
    let flagged = [
      "SELECT 1 FROM pg_class c",
      "SELECT format_type(1, NULL)",
      "SELECT x.oid::oid FROM pg_catalog.pg_class x",
      "SELECT 1 FROM pg_catalog.pg_class c WHERE c.relpages = 0",
      "SELECT NULLIF(pg_catalog.pg_my_temp_schema(), 0)",
      "SELECT 1 FROM pg_catalog.pg_class c WHERE c.relkind IN ('r')",
      "SELECT 1 FROM pg_catalog.pg_namespace n WHERE n.nspname NOT LIKE 'pg%'",
      "SELECT 1 WHERE 1 BETWEEN 0 AND 2",
      "SELECT 1 WHERE 1 IS DISTINCT FROM 2",
      "SELECT 1 FROM pg_catalog.pg_class a JOIN pg_catalog.pg_class b USING (oid)",
      "SELECT 1 FROM pg_catalog.pg_class a NATURAL JOIN pg_catalog.pg_class b",
      "SELECT CASE c.relkind WHEN 'r' THEN 1 END FROM pg_catalog.pg_class c",
      "SELECT 'pg_class'::pg_catalog.regclass",
      "SELECT pg_catalog.to_regclass($1)",
      "SELECT $1::pg_catalog.regclass",
      "SELECT x OPERATOR(public.=) 1",
      "SELECT public.format_type(1, NULL)",
      "SELECT pg_catalog.obj_description(c.oid, 'pg_class') FROM pg_catalog.pg_class c",
      "SELECT pg_catalog.col_description(1, 1)",
      "SELECT pg_catalog.shobj_description(1, 'pg_database')",
      "SELECT 1 FROM information_schema.columns c",
    ]
    for sql in flagged {
      #expect(!CatalogSQLLint.violations(sql).isEmpty, "not flagged: \(sql)")
    }
    let qualified = """
      SELECT pg_catalog.count(*), c.oid::pg_catalog.int8,
        CASE WHEN c.relpages OPERATOR(pg_catalog.=) 0 THEN NULL ELSE c.relpages END
      FROM pg_catalog.pg_class c
      CROSS JOIN LATERAL pg_catalog.unnest(ARRAY[1]) WITH ORDINALITY AS x(n, ord)
      WHERE c.relkind OPERATOR(pg_catalog.=) ANY (ARRAY['r', 'p']::pg_catalog."char"[])
        AND c.oid OPERATOR(pg_catalog.<>) 'pg_catalog.pg_class'::pg_catalog.regclass
        AND c.oid OPERATOR(pg_catalog.=) $1::pg_catalog.oid
      """
    #expect(CatalogSQLLint.violations(qualified) == [])
  }
}

/// Token-level rules for a catalog statement. Words are uppercased by `SQLTokenizer`; strings
/// and quoted identifiers are opaque, so a user name or a pattern never matches a rule.
private enum CatalogSQLLint {
  /// Grammar constructs and keywords that may precede `(` without being looked up by name
  private static let notFunctions: Set<String> = [
    "COALESCE", "GREATEST", "LEAST", "CASE", "EXISTS", "ANY", "ALL", "ARRAY", "CAST", "ROW",
    "EXTRACT", "POSITION", "SUBSTRING", "TRIM", "VALUES", "AND", "OR", "NOT", "WHERE", "SELECT",
    "THEN", "ELSE", "WHEN", "ON", "FROM", "JOIN", "LATERAL", "BY", "IS", "FILTER", "OVER",
    // Flagged on their own (`wordViolations`)
    "IN", "USING",
  ]
  /// Symbols that are punctuation, not operators (`*` and `:` and `$` are checked apart)
  private static let punctuation: Set<String> = ["(", ")", ",", ".", "[", "]", ";"]

  /// `allowsBoundNameLookup`: a bound name may resolve through search_path (`to_regclass($n)`,
  /// `$n::pg_catalog.regclass`), see `boundNameLookups`.
  static func violations(_ sql: String, allowsBoundNameLookup: Bool = false) -> [String] {
    let tokens = SQLTokenizer.tokens(sql, dialect: .postgresql)
    // `SET [LOCAL] name = value, ...` names a setting and takes literal values: nothing in it
    // is looked up as a function, operator or relation
    if tokens.first?.keyword == "SET" { return [] }
    var found: [String] = []
    func word(_ index: Int) -> String? {
      tokens.indices.contains(index) ? tokens[index].keyword : nil
    }
    func symbol(_ index: Int, _ text: String) -> Bool {
      tokens.indices.contains(index) && tokens[index].isSymbol(text)
    }
    func qualified(_ index: Int) -> Bool {
      symbol(index - 1, ".") && word(index - 2) == "PG_CATALOG"
    }
    var i = 0
    while i < tokens.count {
      let token = tokens[i]
      if token.kind == .symbol {
        switch token.text {
        case _ where punctuation.contains(token.text):
          break
        case "*" where (symbol(i - 1, "(") && symbol(i + 1, ")")) || word(i - 1) == "SELECT":
          break
        case "$" where word(i + 1).map { $0.allSatisfy(\.isNumber) } ?? false:
          break
        case ":" where symbol(i + 1, ":"):
          found += castViolations(tokens, at: i, allowsBoundNameLookup: allowsBoundNameLookup)
          i += 2
          continue
        default:
          found.append("operator \(token.text) outside OPERATOR(pg_catalog.…)")
        }
        i += 1
        continue
      }
      guard let text = token.keyword else {
        i += 1
        continue
      }
      if text == "OPERATOR", symbol(i + 1, "(") {
        var end = i + 2
        while end < tokens.count, !tokens[end].isSymbol(")") { end += 1 }
        let operatorSymbols = tokens[min(i + 4, end)..<end]
        if word(i + 2) != "PG_CATALOG" || !symbol(i + 3, ".") || operatorSymbols.isEmpty
          || operatorSymbols.contains(where: { $0.kind != .symbol })
        {
          found.append("OPERATOR(…) not in pg_catalog")
        }
        i = end + 1
        continue
      }
      found += wordViolations(text, at: i, word: word, symbol: symbol, qualified: qualified)
      if text == "TO_REGCLASS", !allowsBoundNameLookup {
        found.append("to_regclass resolves a name through search_path")
      }
      i += 1
    }
    return found
  }

  private static func wordViolations(
    _ text: String, at i: Int, word: (Int) -> String?, symbol: (Int, String) -> Bool,
    qualified: (Int) -> Bool
  ) -> [String] {
    var found: [String] = []
    switch text {
    case "PG_CATALOG" where !symbol(i + 1, "."):
      found.append("pg_catalog not followed by a name")
    case "NULLIF", "LIKE", "ILIKE", "SIMILAR", "BETWEEN", "NATURAL":
      found.append("\(text) looks its operator up by name")
    case "IN" where symbol(i + 1, "("), "USING" where symbol(i + 1, "("),
      "DISTINCT" where word(i + 1) == "FROM":
      found.append("\(text) looks its operator up by name")
    case "CASE" where word(i + 1) != "WHEN":
      found.append("simple CASE looks = up by name")
    // On PostgreSQL 13 and older these are LANGUAGE sql functions (and information_schema's
    // views call `_pg_*` ones) whose string body is parsed when they run, with the caller's
    // search_path and unqualified operators, so qualifying the call does not help. Read
    // pg_catalog.pg_description and pg_attribute / pg_type instead.
    case "OBJ_DESCRIPTION", "COL_DESCRIPTION", "SHOBJ_DESCRIPTION":
      found.append("\(text) runs a SQL body with the caller's search_path on PG 13 and older")
    case "INFORMATION_SCHEMA" where symbol(i + 1, "."):
      found.append("information_schema runs SQL bodies with the caller's search_path on PG 13")
    default:
      break
    }
    if text.hasPrefix("PG_"), text != "PG_CATALOG", !qualified(i) {
      found.append("unqualified catalog name \(text)")
    }
    guard symbol(i + 1, "(") else { return found }
    if symbol(i - 1, ".") {
      if !qualified(i) { found.append("function \(text) qualified outside pg_catalog") }
    } else if !notFunctions.contains(text), word(i - 1) != "AS", word(i - 1) != "ORDINALITY",
      !text.hasPrefix("PG_")
    {
      found.append("unqualified function \(text)(")
    }
    return found
  }

  /// `::` at `i`: the type is `pg_catalog.<name>`; a regclass literal names a pg_catalog
  /// relation; a bound regclass is a name lookup.
  private static func castViolations(
    _ tokens: [SQLToken], at i: Int, allowsBoundNameLookup: Bool
  ) -> [String] {
    guard i + 4 < tokens.count, tokens[i + 2].keyword == "PG_CATALOG",
      tokens[i + 3].isSymbol("."),
      tokens[i + 4].kind == .word || tokens[i + 4].kind == .quotedIdentifier
    else { return ["unqualified cast type"] }
    guard tokens[i + 4].keyword == "REGCLASS", i > 0 else { return [] }
    let operand = tokens[i - 1]
    if operand.kind == .string {
      return operand.text.hasPrefix("pg_catalog.") ? [] : ["regclass literal '\(operand.text)'"]
    }
    if i > 1, tokens[i - 2].isSymbol("$"), !allowsBoundNameLookup {
      return ["bound regclass resolves a name through search_path"]
    }
    return []
  }
}
