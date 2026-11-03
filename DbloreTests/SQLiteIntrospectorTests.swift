// SQLiteIntrospectorTests.swift
// SQLiteSchemaIntrospector against a temporary file. The fixture is built here.
// Row estimates are read from sqlite_stat1, never from COUNT(*).

import Foundation
import Testing

@testable import Dblore

@Suite("SQLite schema introspector")
@MainActor
struct SQLiteIntrospectorTests {
  private let introspector = SQLiteSchemaIntrospector()

  @Test("Tables, views, keys, generated columns, and foreign keys match the catalog")
  func catalogShapes() async throws {
    try await withFixture { session in
      let tables = try await introspector.tables(in: session)
      #expect(
        tables.map(Self.qualified) == [
          "main.child", "main.link", "main.notes", "main.pair", "main.parent",
        ])
      #expect(tables.allSatisfy { $0.schema == "main" && $0.rowCount == nil })
      #expect(tables.contains { $0.name.hasPrefix("sqlite_") } == false)

      let views = try await introspector.views(in: session)
      #expect(views.map(Self.qualified) == ["main.child_view"])

      let columns = try await introspector.allColumns(in: session)
      let child = try #require(columns["main.child"])
      #expect(child.map(\.name) == ["id", "email", "n", "double", "stored", "a", "b"])
      let id = try #require(child.first { $0.name == "id" })
      #expect(id.isPrimaryKey)
      #expect(!id.isUnique)
      #expect(!id.isGenerated)
      #expect(!id.isHidden)
      #expect(id.type == "INTEGER")
      let email = try #require(child.first { $0.name == "email" })
      #expect(email.isUnique)
      #expect(!email.isPrimaryKey)
      #expect(email.type == "TEXT")
      let virtualColumn = try #require(child.first { $0.name == "double" })
      #expect(virtualColumn.isGenerated)
      #expect(!virtualColumn.isHidden)
      #expect(!virtualColumn.isPrimaryKey)
      let storedColumn = try #require(child.first { $0.name == "stored" })
      #expect(storedColumn.isGenerated)
      #expect(!storedColumn.isHidden)

      let parent = try #require(columns["main.parent"])
      #expect(parent.map(\.name) == ["a", "b"])
      #expect(parent.allSatisfy { $0.isPrimaryKey && !$0.isNullable && !$0.isUnique })

      let pair = try #require(columns["main.pair"])
      #expect(pair.allSatisfy { !$0.isUnique && !$0.isPrimaryKey })

      let viewColumns = try #require(columns["main.child_view"])
      #expect(viewColumns.map(\.name) == ["id", "email", "double"])
      #expect(viewColumns.allSatisfy { !$0.isGenerated && !$0.isPrimaryKey })

      let foreignKeys = try await introspector.foreignKeys(in: session)
      #expect(foreignKeys.count == 2)
      let childKey = try #require(foreignKeys.first { $0.sourceTable == "child" })
      #expect(childKey.sourceSchema == "main")
      #expect(childKey.targetSchema == "main")
      #expect(childKey.targetTable == "parent")
      #expect(childKey.sourceColumns == ["b", "a"])
      #expect(childKey.targetColumns == ["b", "a"])
      #expect(childKey.onUpdate == .cascade)
      #expect(childKey.onDelete == .setNull)
      let linkKey = try #require(foreignKeys.first { $0.sourceTable == "link" })
      #expect(linkKey.sourceColumns == ["parent_b", "parent_a"])
      #expect(linkKey.targetColumns == ["b", "a"])
      #expect(linkKey.targetTable == "parent")
      #expect(linkKey.onUpdate == .noAction)
      #expect(linkKey.onDelete == .noAction)
    }
  }

  @Test("editTable keys by the declared primary key, including WITHOUT ROWID; keyless by rowid")
  func editTableRequiresDeclaredPrimaryKey() async throws {
    try await withFixture { session in
      let parent = try #require(try await introspector.editTable(named: "parent", in: session))
      #expect(parent.primaryKeyColumns == ["b", "a"])
      #expect(parent.attributeNames == [Int16(0): "a", Int16(1): "b"])
      #expect(parent.qualifiedName == "\"main\".\"parent\"")
      #expect(!parent.updateOnly)
      #expect(parent.oid != 0)

      let child = try #require(try await introspector.editTable(named: "main.child", in: session))
      #expect(child.primaryKeyColumns == ["id"])
      #expect(
        child.attributeNames == [
          Int16(0): "id",
          Int16(1): "email",
          Int16(2): "n",
          Int16(3): "double",
          Int16(4): "stored",
          Int16(5): "a",
          Int16(6): "b",
        ])

      #expect(parent.rowLocator == nil)
      #expect(child.rowLocator == nil)

      // No primary key: rows are named by rowid, plus `IS` on the typed columns
      let notes = try #require(try await introspector.editTable(named: "notes", in: session))
      let pair = try #require(try await introspector.editTable(named: "pair", in: session))
      #expect(notes.primaryKeyColumns.isEmpty)
      #expect(notes.rowLocator == .sqliteRowid(alias: .rowid, matchColumns: ["body"]))
      #expect(pair.rowLocator == .sqliteRowid(alias: .rowid, matchColumns: ["x", "y"]))
      #expect(notes.qualifiedName == "\"main\".\"notes\"")
      let view = try await introspector.editTable(named: "child_view", in: session)
      #expect(view == nil)
    }
  }

  @Test(
    "A keyless table's locator: affinity-filtered columns, shadowed rowid alias, virtual refused")
  func keylessRowidLocator() async throws {
    try await withDatabase { session in
      let statements = [
        """
        CREATE TABLE typed (
          a, b REAL, c TEXT, d BLOB, e VARCHAR(10), f DECIMAL(10,2), g FLOATING POINT,
          h DOUBLE PRECISION, i BOOLEAN
        )
        """,
        "CREATE TABLE shadow_one (\"RowID\" TEXT, v INT)",
        "CREATE TABLE shadow_two (rowid, _ROWID_ TEXT, x)",
        "CREATE TABLE shadow_all (rowid, _rowid_, oid)",
        "CREATE VIRTUAL TABLE docs USING fts5(title, body)",
        "CREATE TABLE keyed (k TEXT PRIMARY KEY, v) WITHOUT ROWID",
        "CREATE TABLE strict_any (a ANY, b TEXT, c INTEGER) STRICT",
      ]
      for sql in statements {
        _ = try await session.command(sql, binds: [])
      }
      // SQLite affinity rules: INT, then CHAR/CLOB/TEXT, then BLOB or no type, then
      // REAL/FLOA/DOUB, else NUMERIC. Untyped and BLOB columns are left out.
      let typed = try #require(try await introspector.editTable(named: "typed", in: session))
      #expect(
        typed.rowLocator
          == .sqliteRowid(alias: .rowid, matchColumns: ["b", "c", "e", "f", "g", "h", "i"]))
      let one = try #require(try await introspector.editTable(named: "shadow_one", in: session))
      #expect(
        one.rowLocator == .sqliteRowid(alias: .underscoredRowid, matchColumns: ["RowID", "v"]))
      let two = try #require(try await introspector.editTable(named: "shadow_two", in: session))
      #expect(two.rowLocator == .sqliteRowid(alias: .oid, matchColumns: ["_ROWID_"]))
      #expect(try await introspector.editTable(named: "shadow_all", in: session) == nil)
      #expect(try await introspector.editTable(named: "docs", in: session) == nil)
      let keyed = try #require(try await introspector.editTable(named: "keyed", in: session))
      #expect(keyed.primaryKeyColumns == ["k"])
      #expect(keyed.rowLocator == nil)
      // A STRICT table's ANY column has no affinity: a text bind never equals a stored number
      let strict = try #require(try await introspector.editTable(named: "strict_any", in: session))
      #expect(strict.rowLocator == .sqliteRowid(alias: .rowid, matchColumns: ["b", "c"]))
    }
  }

  @Test("Hidden virtual-table columns are flagged and are not generated")
  func hiddenColumnsAreFlagged() async throws {
    try await withDatabase { session in
      _ = try await session.command(
        "CREATE VIRTUAL TABLE docs USING fts5(title, body)", binds: [])
      let columns = try await introspector.allColumns(in: session)
      let docs = try #require(columns["main.docs"])
      let title = try #require(docs.first { $0.name == "title" })
      #expect(!title.isHidden)
      #expect(!title.isGenerated)
      let rank = try #require(docs.first { $0.name == "rank" })
      #expect(rank.isHidden)
      #expect(!rank.isGenerated)
    }
  }

  @Test("Row estimates come from sqlite_stat1, not a live row count")
  func rowEstimateComesFromStat1() async throws {
    try await withDatabase { session in
      _ = try await session.command("CREATE TABLE notes (body TEXT)", binds: [])
      _ = try await session.command("INSERT INTO notes (body) VALUES ('one')", binds: [])
      let before = try await introspector.tables(in: session)
      #expect(before.first { $0.name == "notes" }?.rowCount == nil)

      _ = try await session.command("ANALYZE notes", binds: [])
      _ = try await session.command(
        "UPDATE sqlite_stat1 SET stat = '99999' WHERE tbl = 'notes'", binds: [])
      let after = try await introspector.tables(in: session)
      #expect(after.first { $0.name == "notes" }?.rowCount == 99999)
      #expect(after.contains { $0.name == "sqlite_stat1" } == false)
    }
  }

  @Test("Attached databases are listed and are not editable")
  func attachedDatabasesAreListedReadOnly() async throws {
    let mainURL = temporaryDatabaseURL()
    let otherURL = temporaryDatabaseURL()
    defer {
      removeDatabase(at: mainURL)
      removeDatabase(at: otherURL)
    }
    let other = SQLiteSession(config: makeConfig(path: otherURL.path))
    try await other.open()
    _ = try await other.command(
      "CREATE TABLE item (id INTEGER PRIMARY KEY, name TEXT)", binds: [])
    await other.close()

    let session = SQLiteSession(config: makeConfig(path: mainURL.path))
    try await session.open()
    do {
      _ = try await session.command("CREATE TABLE local (id INTEGER PRIMARY KEY)", binds: [])
      // A quoted path: the session refuses a bound ATTACH file name
      let quoted = otherURL.path.replacingOccurrences(of: "'", with: "''")
      _ = try await session.command("ATTACH DATABASE '\(quoted)' AS other", binds: [])
      let tables = try await introspector.tables(in: session)
      let item = try #require(tables.first { $0.schema == "other" && $0.name == "item" })
      #expect(item.rowCount == nil)
      #expect(tables.contains { $0.schema == "main" && $0.name == "local" })
      let attached = try await introspector.editTable(named: "other.item", in: session)
      #expect(attached == nil)
      let local = try #require(try await introspector.editTable(named: "local", in: session))
      #expect(local.primaryKeyColumns == ["id"])
      #expect(!local.updateOnly)
      await session.close()
    } catch {
      await session.close()
      throw error
    }
  }

  @Test("Users, roles, functions, and procedures stay empty")
  func securityCatalogsStayEmpty() async throws {
    try await withFixture { session in
      let functions = try await introspector.functions(in: session)
      let procedures = try await introspector.procedures(in: session)
      let users = try await introspector.users(in: session)
      let roles = try await introspector.roles(in: session)
      #expect(functions.isEmpty)
      #expect(procedures.isEmpty)
      #expect(users.isEmpty)
      #expect(roles.isEmpty)
    }
  }

  @Test("Triggers are listed with timing and event parsed from their header; source is the sql")
  func triggersAreListed() async throws {
    try await withDatabase { session in
      let statements = [
        "CREATE TABLE notes (body TEXT)",
        "CREATE TABLE log (body TEXT)",
        "CREATE VIEW notes_view AS SELECT body FROM notes",
        """
        CREATE TRIGGER "before_delete" AFTER INSERT ON notes
        BEGIN DELETE FROM log; INSERT INTO log VALUES (new.body); END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS main.on_change BEFORE UPDATE OF body ON notes
        BEGIN SELECT 1; END
        """,
        "CREATE TRIGGER plain DELETE ON notes BEGIN INSERT INTO log VALUES (old.body); END",
        """
        CREATE TRIGGER view_insert INSTEAD OF INSERT ON notes_view
        BEGIN INSERT INTO notes VALUES (new.body); END
        """,
      ]
      for sql in statements {
        _ = try await session.command(sql, binds: [])
      }

      let triggers = try await introspector.triggers(in: session)
      #expect(triggers.map(\.name) == ["before_delete", "on_change", "plain", "view_insert"])
      #expect(triggers.allSatisfy { $0.schema == "main" && $0.enabled && $0.oid == nil })
      let shapes = triggers.map { "\($0.table) \($0.timing.rawValue) \($0.events.map(\.rawValue))" }
      #expect(
        shapes == [
          "notes AFTER [\"INSERT\"]",
          "notes BEFORE [\"UPDATE\"]",
          "notes BEFORE [\"DELETE\"]",
          "notes_view INSTEAD OF [\"INSERT\"]",
        ])

      let plain = try #require(triggers.first { $0.name == "plain" })
      let source = try await introspector.definition(of: .trigger(plain), in: session)
      #expect(source == statements[5])
      let function = DatabaseFunction(schema: "main", name: "f", returnType: "int")
      #expect(try await introspector.definition(of: .function(function), in: session) == nil)
    }
  }

  @Test("Timing comes only from the words after the name; UPDATE OF columns are not keywords")
  func triggerColumnsNamedLikeKeywords() async throws {
    try await withDatabase { session in
      let statements = [
        "CREATE TABLE t (after TEXT, instead TEXT, body TEXT)",
        "CREATE TRIGGER a BEFORE UPDATE OF after, instead ON t BEGIN SELECT 1; END",
        "CREATE TRIGGER b UPDATE OF instead ON t BEGIN SELECT 1; END",
        "CREATE TRIGGER c AFTER UPDATE OF body ON t BEGIN SELECT 1; END",
      ]
      for sql in statements {
        _ = try await session.command(sql, binds: [])
      }

      let triggers = try await introspector.triggers(in: session)
      let shapes = triggers.map { "\($0.name) \($0.timing.rawValue) \($0.events.map(\.rawValue))" }
      #expect(
        shapes == [
          "a BEFORE [\"UPDATE\"]",
          "b BEFORE [\"UPDATE\"]",
          "c AFTER [\"UPDATE\"]",
        ])
    }
  }

  @Test("Chunked catalog read matches the one-chunk read on odd names; a broken view is empty")
  func chunkedReadMatchesOneChunk() async throws {
    try await withOddFixture { session in
      let chunked = SQLiteSchemaIntrospector(chunkSize: 2)
      let oneChunk = SQLiteSchemaIntrospector(chunkSize: 10_000)
      let columns = try await chunked.allColumns(in: session)
      let reference = try await oneChunk.allColumns(in: session)
      #expect(Self.signatures(columns) == Self.signatures(reference))
      let keys = try await chunked.foreignKeys(in: session)
      let referenceKeys = try await oneChunk.foreignKeys(in: session)
      #expect(keys.map(Self.signature) == referenceKeys.map(Self.signature))

      #expect(
        Set(columns.keys) == [
          "main.Ünïcode tàble", "main.case child", "main.odd \"quoted\" name", "main.parent",
          "main.with space", "main.broken", "main.odd view",
        ])
      #expect(columns["main.broken"]?.isEmpty == true)

      let odd = try #require(columns["main.odd \"quoted\" name"])
      #expect(
        odd.map(\.name) == ["id", "e mail", "naïve 名前", "n", "double it", "stored", "x", "y"])
      // Single-column, non-partial unique indexes only; the primary key is not "unique"
      #expect(odd.filter(\.isUnique).map(\.name) == ["e mail"])
      #expect(odd.filter(\.isGenerated).map(\.name) == ["double it", "stored"])
      #expect(odd.allSatisfy { !$0.isHidden })
      let space = try #require(columns["main.with space"])
      #expect(
        space.map { "\($0.name) \($0.isPrimaryKey) \($0.isUnique)" } == [
          "k true false", "v false true",
        ])
      let view = try #require(columns["main.odd view"])
      #expect(view.map(\.name) == ["id", "e mail", "double it"])
      #expect(view.allSatisfy { !$0.isGenerated && !$0.isPrimaryKey })

      #expect(
        keys.map(Self.signature) == [
          "main.case child(pb,pa) -> main.PARENT(b,a) noAction cascade",
          "main.Ünïcode tàble(pb,pa) -> main.parent(b,a) noAction noAction",
        ])
    }
  }

  @Test("Cancelling the task between chunks throws CancellationError")
  func cancellingBetweenChunksThrows() async throws {
    let url = temporaryDatabaseURL()
    defer { removeDatabase(at: url) }
    // Query 4 is the first column read: the schema list and the two relation lists come first
    let session = CancellingSession(
      base: SQLiteSession(config: makeConfig(path: url.path)), cancelAt: 4)
    try await session.open()
    do {
      for index in 0..<6 {
        _ = try await session.command("CREATE TABLE t\(index) (id INTEGER)", binds: [])
      }
      let introspector = SQLiteSchemaIntrospector(chunkSize: 2)
      let read = Task { try await introspector.allColumns(in: session) }
      await #expect(throws: CancellationError.self) { try await read.value }
      await session.close()
    } catch {
      await session.close()
      throw error
    }
  }

  /// Quotes, spaces and Unicode in names, a WITHOUT ROWID table, VIRTUAL and STORED generated
  /// columns, a foreign key with no referenced column, one naming its table in another case,
  /// and a view over a dropped table.
  private func withOddFixture(
    _ body: (SQLiteSession) async throws -> Void
  ) async throws {
    try await withDatabase { session in
      let statements = [
        """
        CREATE TABLE parent (
          a INTEGER NOT NULL,
          b TEXT NOT NULL,
          PRIMARY KEY (b, a)
        ) WITHOUT ROWID
        """,
        """
        CREATE TABLE "odd ""quoted"" name" (
          id INTEGER PRIMARY KEY,
          "e mail" TEXT UNIQUE,
          "naïve 名前" TEXT,
          n INTEGER,
          "double it" INTEGER GENERATED ALWAYS AS (n * 2) VIRTUAL,
          stored INTEGER GENERATED ALWAYS AS (n + 1) STORED,
          x INTEGER,
          y INTEGER,
          UNIQUE (x, y)
        )
        """,
        "CREATE UNIQUE INDEX \"partial x\" ON \"odd \"\"quoted\"\" name\" (x) WHERE x > 0",
        "CREATE UNIQUE INDEX lower_name ON \"odd \"\"quoted\"\" name\" (lower(\"naïve 名前\"))",
        """
        CREATE TABLE "Ünïcode tàble" (
          pb TEXT,
          pa INTEGER,
          FOREIGN KEY (pb, pa) REFERENCES parent
        )
        """,
        """
        CREATE TABLE "case child" (
          pb TEXT,
          pa INTEGER,
          FOREIGN KEY (pb, pa) REFERENCES "PARENT" (b, a) ON DELETE CASCADE
        )
        """,
        "CREATE TABLE \"with space\" (k TEXT PRIMARY KEY, v TEXT UNIQUE) WITHOUT ROWID",
        "CREATE TABLE gone (id INTEGER)",
        """
        CREATE VIEW "odd view" AS SELECT id, "e mail", "double it" FROM "odd ""quoted"" name"
        """,
        "CREATE VIEW broken AS SELECT id FROM gone",
        "DROP TABLE gone",
      ]
      for sql in statements {
        _ = try await session.command(sql, binds: [])
      }
      try await body(session)
    }
  }

  private static func signatures(_ columns: [String: [DatabaseColumn]]) -> [String: [String]] {
    columns.mapValues { relation in
      relation.map {
        "\($0.name) \($0.type) \($0.isNullable) \($0.isPrimaryKey) \($0.isUnique) "
          + "\($0.isHidden) \($0.isGenerated)"
      }
    }
  }

  private static func signature(_ key: ForeignKey) -> String {
    "\(key.sourceSchema).\(key.sourceTable)(\(key.sourceColumns.joined(separator: ","))) -> "
      + "\(key.targetSchema).\(key.targetTable)(\(key.targetColumns.joined(separator: ","))) "
      + "\(key.onUpdate) \(key.onDelete)"
  }

  private func withFixture(
    _ body: (SQLiteSession) async throws -> Void
  ) async throws {
    try await withDatabase { session in
      let statements = [
        """
        CREATE TABLE parent (
          a INTEGER NOT NULL,
          b TEXT NOT NULL,
          PRIMARY KEY (b, a)
        ) WITHOUT ROWID
        """,
        """
        CREATE TABLE child (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          email TEXT UNIQUE,
          n INTEGER,
          double INTEGER GENERATED ALWAYS AS (n * 2) VIRTUAL,
          stored INTEGER GENERATED ALWAYS AS (n + 1) STORED,
          a INTEGER,
          b TEXT,
          FOREIGN KEY (b, a) REFERENCES parent (b, a)
            ON UPDATE CASCADE ON DELETE SET NULL
        )
        """,
        "CREATE TABLE notes (body TEXT)",
        "CREATE TABLE pair (x INTEGER, y INTEGER, UNIQUE (x, y))",
        """
        CREATE TABLE link (
          parent_b TEXT,
          parent_a INTEGER,
          FOREIGN KEY (parent_b, parent_a) REFERENCES parent
        )
        """,
        "CREATE VIEW child_view AS SELECT id, email, double FROM child",
      ]
      for sql in statements {
        _ = try await session.command(sql, binds: [])
      }
      try await body(session)
    }
  }

  private func withDatabase(
    _ body: (SQLiteSession) async throws -> Void
  ) async throws {
    let url = temporaryDatabaseURL()
    defer { removeDatabase(at: url) }
    let session = SQLiteSession(config: makeConfig(path: url.path))
    try await session.open()
    do {
      try await body(session)
      await session.close()
    } catch {
      await session.close()
      throw error
    }
  }

  private func makeConfig(path: String) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: .sqlite,
      database: path,
      username: "unused",
      password: "dblore-introspector-password",
      sslMode: .disable
    )
  }

  private func temporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-sqlite-introspector-\(UUID().uuidString).db")
  }

  private func removeDatabase(at url: URL) {
    let fileManager = FileManager.default
    try? fileManager.removeItem(at: url)
    try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
    try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
    try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + "-journal"))
  }

  private static func qualified(_ table: DatabaseTable) -> String {
    table.qualifiedName
  }

  private static func qualified(_ view: DatabaseView) -> String {
    view.qualifiedName
  }
}

/// Forwards to a SQLite session and cancels the calling task when its `cancelAt`-th query starts
private final class CancellingSession: DatabaseSession, @unchecked Sendable {
  private let base: SQLiteSession
  private let cancelAt: Int
  private let lock = NSLock()
  private var queries = 0

  init(base: SQLiteSession, cancelAt: Int) {
    self.base = base
    self.cancelAt = cancelAt
  }

  var capabilities: DatabaseCapabilities { base.capabilities }
  var closeEvents: AsyncStream<SessionCloseReason> { base.closeEvents }

  func open() async throws { try await base.open() }

  func close() async { await base.close() }

  func query(_ sql: String, binds: [SQLBindValue]) async throws -> SessionRowSource {
    let count = lock.withLock {
      queries += 1
      return queries
    }
    if count == cancelAt {
      withUnsafeCurrentTask { $0?.cancel() }
    }
    return try await base.query(sql, binds: binds)
  }

  func command(_ sql: String, binds: [SQLBindValue]) async throws -> CommandResult {
    try await base.command(sql, binds: binds)
  }

  func openCursor(_ sql: String, binds: [SQLBindValue]) async throws -> SessionCursor {
    try await base.openCursor(sql, binds: binds)
  }

  func fetch(_ cursor: SessionCursor, maxRows: Int) async throws -> SessionRowSource {
    try await base.fetch(cursor, maxRows: maxRows)
  }

  func closeCursor(_ cursor: SessionCursor) async throws {
    try await base.closeCursor(cursor)
  }

  func applySessionSettings(
    statementTimeoutSeconds: Int, lockTimeoutSeconds: Int, idleTimeoutSeconds: Int
  ) async throws {
    try await base.applySessionSettings(
      statementTimeoutSeconds: statementTimeoutSeconds, lockTimeoutSeconds: lockTimeoutSeconds,
      idleTimeoutSeconds: idleTimeoutSeconds)
  }

  func interrupt() async { await base.interrupt() }

  func formatError(_ error: Error) -> String { base.formatError(error) }
}
