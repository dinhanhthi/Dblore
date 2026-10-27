// SQLiteAttachTests.swift
// ATTACH of a second SQLite file through SQLiteSession's open paths (read-write: READWRITE |
// CREATE | NOMUTEX; read-only file: READONLY | URI | NOMUTEX with a `mode=ro` URI): transactions,
// quoted paths, read-only inheritance and `file:` URI handling pin the engine contract the
// attached-databases feature builds on (each test says what it means for that feature); then
// the configured attachments made at open, their warnings and their locks, and the authorizer
// that refuses a typed ATTACH of a locked file. Typed ATTACH quotes its path: the authorizer
// refuses a bound file name (it cannot see it).

import Foundation
import SQLite3
import Testing

@testable import Dblore

@Suite("SQLite attach")
@MainActor
struct SQLiteAttachTests {
  // MARK: - Transactions

  /// Observed: ATTACH succeeds inside an open write transaction, DETACH of a database that
  /// transaction wrote to fails ("database aux is locked"), and the attachment survives ROLLBACK
  /// while the attached database's writes roll back with it. Implication: attachments are not
  /// transactional, so the app tracks them apart from the edit transaction and detaches only
  /// outside a write transaction.
  @Test("ATTACH works inside a transaction and outlives ROLLBACK; DETACH waits for it to end")
  func attachInsideTransaction() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let main = try await makeDatabase(folder, "main.sqlite")
    let aux = try await makeDatabase(folder, "aux.sqlite")

    try await withSession(main) { session in
      _ = try await session.command("BEGIN IMMEDIATE", binds: [])
      _ = try await session.command("INSERT INTO t VALUES (2)", binds: [])
      _ = try await session.command(attachSQL(aux, as: "aux"), binds: [])
      _ = try await session.command("INSERT INTO aux.t VALUES (2)", binds: [])
      let locked = try await commandError(session, "DETACH aux")
      #expect(locked.extendedCode == SQLITE_ERROR)
      #expect(locked.message == "database aux is locked")
      _ = try await session.command("ROLLBACK", binds: [])

      #expect(try await databaseNames(session) == ["main", "aux"])
      #expect(try await collect(session, "SELECT count(*) FROM aux.t") == [[.int(1)]])
      #expect(try await collect(session, "SELECT count(*) FROM main.t") == [[.int(1)]])

      // A deferred transaction that only read: ATTACH and DETACH both run inside it
      _ = try await session.command("DETACH aux", binds: [])
      _ = try await session.command("BEGIN", binds: [])
      _ = try await collect(session, "SELECT count(*) FROM t")
      _ = try await session.command(attachSQL(aux, as: "aux"), binds: [])
      _ = try await session.command("DETACH aux", binds: [])
      _ = try await session.command("COMMIT", binds: [])
      #expect(try await databaseNames(session) == ["main"])
    }
  }

  // MARK: - Quoted and bound paths

  /// Observed: a path with a quote or a space attaches as a quoted string literal (quote
  /// doubled) under a quoted schema name, and as a bound `?` when configured. Implication: the
  /// configured attachments bind the path and quote the name; neither is pasted into SQL text.
  @Test("A path with a quote and a space attaches quoted (typed) and bound (configured)")
  func quotedPathAttach() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let main = try await makeDatabase(folder, "main.sqlite")
    let aux = try await makeDatabase(folder, "o'brien notes.sqlite")

    try await withSession(main, attached: [AttachedDatabase(name: "bound", path: aux)]) {
      session in
      #expect(try await collect(session, "SELECT count(*) FROM bound.t") == [[.int(1)]])
      _ = try await session.command(attachSQL(aux, as: "other db"), binds: [])
      _ = try await session.command(#"INSERT INTO "other db".t VALUES (2)"#, binds: [])
      #expect(
        try await collect(session, #"SELECT count(*) FROM "other db".t"#) == [[.int(2)]])
      let files = try await collect(session, "PRAGMA database_list")
      let attached = files.compactMap { row -> String? in
        guard case .string("other db")? = row.dropFirst().first,
          case .string(let file)? = row.last
        else { return nil }
        return file
      }
      #expect(attached == [aux] || attached == ["/private" + aux])
    }
  }

  // MARK: - Read-only main

  /// Observed: on a read-only main (READONLY | URI, `mode=ro`) a plain-path attach is read-only
  /// too (SQLITE_READONLY "attempt to write a readonly database"), a `mode=ro` URI attach is
  /// read-only, a `mode=rw` URI is refused ("access mode not allowed: rw"), and DETACH plus a
  /// plain re-ATTACH stays read-only. Implication: read-only inherits from the main open flags,
  /// so a read-only main is a real boundary for attached files.
  @Test("A read-only main attaches every file read-only and cannot be escalated")
  func readOnlyMainInherits() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let main = try await makeDatabase(folder, "main.sqlite")
    let aux = try await makeDatabase(folder, "aux.sqlite")

    try await withSession(main, readOnlyFile: true) { session in
      _ = try await session.command(attachSQL(aux, as: "aux"), binds: [])
      #expect(try await collect(session, "SELECT count(*) FROM aux.t") == [[.int(1)]])
      try await expectReadOnly(session, "aux")

      _ = try await session.command(attachSQL(try fileURI(aux, mode: "ro"), as: "uri"), binds: [])
      #expect(try await collect(session, "SELECT count(*) FROM uri.t") == [[.int(1)]])
      try await expectReadOnly(session, "uri")

      let refused = try await commandError(
        session, attachSQL(try fileURI(aux, mode: "rw"), as: "rw"))
      #expect(refused.message == "access mode not allowed: rw")

      _ = try await session.command("DETACH aux", binds: [])
      _ = try await session.command(attachSQL(aux, as: "aux"), binds: [])
      try await expectReadOnly(session, "aux")
    }
  }

  /// Observed: on a read-write main, a `mode=ro` URI attach is read-only, but DETACH plus a
  /// plain re-ATTACH of the same path makes it writable. Implication: a read-only attach on a
  /// read-write main is advisory against user SQL. ATTACH and DETACH are utility statements, and
  /// the app's gate refuses them only on Read-only / Schema-only connections; elsewhere a
  /// read-only security-scoped bookmark has to be the stop.
  @Test("A read-only attach on a read-write main can be re-attached writable by SQL")
  func readOnlyAttachOnReadWriteMainIsAdvisory() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let main = try await makeDatabase(folder, "main.sqlite")
    let aux = try await makeDatabase(folder, "aux.sqlite")

    try await withSession(main) { session in
      _ = try await session.command(attachSQL(try fileURI(aux, mode: "ro"), as: "aux"), binds: [])
      try await expectReadOnly(session, "aux")
      _ = try await session.command("DETACH aux", binds: [])
      _ = try await session.command(attachSQL(aux, as: "aux"), binds: [])
      let inserted = try await session.command("INSERT INTO aux.t VALUES (2)", binds: [])
      #expect(inserted.affectedRows == 1)
    }
  }

  // MARK: - file: URIs without SQLITE_OPEN_URI

  /// Observed: the system SQLite is built with SQLITE_USE_URI=1, so `file:` text is parsed as a
  /// URI even though the read-write open does not pass SQLITE_OPEN_URI: an attached
  /// `file:<path>?mode=ro` is read-only, not a file literally named `file:...`. Implication:
  /// adding the flag changes nothing on this platform; attach paths from an open panel start
  /// with "/" and are never parsed as URIs.
  @Test("file: text is a URI on a read-write main without SQLITE_OPEN_URI")
  func fileTextIsURIWithoutOpenFlag() async throws {
    try #require(sqlite3_compileoption_used("USE_URI") == 1)
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let main = try await makeDatabase(folder, "main.sqlite")
    let aux = try await makeDatabase(folder, "aux.sqlite")

    try await withSession(main) { session in
      _ = try await session.command(attachSQL("file:\(aux)?mode=ro", as: "aux"), binds: [])
      #expect(try await collect(session, "SELECT count(*) FROM aux.t") == [[.int(1)]])
      try await expectReadOnly(session, "aux")
    }
    #expect(try entries(folder) == ["aux.sqlite", "main.sqlite"])

    // The raw handle with the same flags agrees
    var handle: OpaquePointer?
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
    #expect(sqlite3_open_v2(main, &handle, flags, nil) == SQLITE_OK)
    defer { sqlite3_close_v2(handle) }
    #expect(sqlite3_exec(handle, "ATTACH 'file:\(aux)?mode=ro' AS aux", nil, nil, nil) == SQLITE_OK)
    #expect(sqlite3_db_readonly(handle, "aux") == 1)
    #expect(sqlite3_db_readonly(handle, "main") == 0)
  }

  /// Observed: a main path that starts with `file:` is parsed as a URI (the file created is the
  /// URI's path, query stripped), while an absolute path that merely contains `file:`, `?` or
  /// `#` stays literal on the read-write open, the read-only open (its URI is percent-encoded)
  /// and as a bound ATTACH path. Implication: absolute paths are always literal; only text that
  /// starts with `file:` needs care, and the read-only open already encodes it.
  @Test("Absolute paths containing file:, ? and # stay literal; a leading file: is a URI")
  func literalPathsStayLiteral() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let odd = try await makeDatabase(folder, "file:odd?x=1#y.sqlite")
    #expect(try entries(folder) == ["file:odd?x=1#y.sqlite"])

    try await withSession(odd, readOnlyFile: true) { session in
      let rows = try await collect(session, "SELECT count(*) FROM t")
      #expect(rows == [[.int(1)]])
    }
    let main = try await makeDatabase(folder, "main.sqlite")
    try await withSession(main) { session in
      _ = try await session.command(attachSQL(odd, as: "odd"), binds: [])
      #expect(try await collect(session, "SELECT count(*) FROM odd.t") == [[.int(1)]])
    }

    // A main path that starts with `file:` is parsed as a URI only with SQLITE_USE_URI
    try #require(sqlite3_compileoption_used("USE_URI") == 1)
    let uriPath = folder.appendingPathComponent("uri-main.sqlite").path
    try await withSession("file:\(uriPath)?cache=private") { session in
      _ = try await session.command("CREATE TABLE u (a INTEGER)", binds: [])
    }
    #expect(
      try entries(folder) == ["file:odd?x=1#y.sqlite", "main.sqlite", "uri-main.sqlite"])
  }

  // MARK: - Sidecars

  /// Observed (container temp dir, no sandbox denial): a WAL write to an attached file creates
  /// `<file>-wal` and `<file>-shm` next to it. Implication: a read-write attach needs the same
  /// sidecar presenters (or folder grant) as a main file; the sandboxed case is checked in the VM.
  @Test("A WAL write to an attached file creates its -wal and -shm sidecars")
  func attachedWALSidecars() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let main = try await makeDatabase(folder, "main.sqlite")
    let aux = try await makeDatabase(folder, "aux.sqlite")

    try await withSession(main) { session in
      _ = try await session.command(attachSQL(aux, as: "aux"), binds: [])
      #expect(try await collect(session, "PRAGMA aux.journal_mode = WAL") == [[.string("wal")]])
      _ = try await session.command("INSERT INTO aux.t VALUES (2)", binds: [])
      #expect(
        try entries(folder) == ["aux.sqlite", "aux.sqlite-shm", "aux.sqlite-wal", "main.sqlite"])
    }
  }

  // MARK: - Configured attachments

  /// Configured attachments are attached at open, before any BEGIN; a write transaction makes
  /// DETACH fail and ROLLBACK keeps them (the app never detaches while one is open)
  @Test("Configured attachments survive ROLLBACK; DETACH is refused in a write transaction")
  func configuredAttachmentsOutliveRollback() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let main = try await makeDatabase(folder, "main.sqlite")
    let aux = try await makeDatabase(folder, "aux.sqlite")

    try await withSession(main, attached: [AttachedDatabase(name: "aux", path: aux)]) {
      session in
      #expect(session.attachWarnings.isEmpty)
      #expect(try await databaseNames(session) == ["main", "aux"])
      _ = try await session.command("BEGIN IMMEDIATE", binds: [])
      _ = try await session.command("INSERT INTO aux.t VALUES (2)", binds: [])
      let locked = try await commandError(session, "DETACH aux")
      #expect(locked.message == "database aux is locked")
      _ = try await session.command("ROLLBACK", binds: [])
      #expect(try await databaseNames(session) == ["main", "aux"])
      #expect(try await collect(session, "SELECT count(*) FROM aux.t") == [[.int(1)]])
    }
  }

  /// A read-only connection attaches with the main file's READONLY flags: writes to the
  /// attached file fail, and a DETACH plus a typed re-ATTACH stays read-only
  @Test("A read-only connection refuses writes to its configured attachments")
  func readOnlyConnectionAttachesReadOnly() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let main = try await makeDatabase(folder, "main.sqlite")
    let aux = try await makeDatabase(folder, "aux.sqlite")

    try await withSession(
      main, readOnlyFile: true, attached: [AttachedDatabase(name: "aux", path: aux)]
    ) { session in
      #expect(try await collect(session, "SELECT count(*) FROM aux.t") == [[.int(1)]])
      try await expectReadOnly(session, "aux")
      _ = try await session.command("DETACH aux", binds: [])
      _ = try await session.command(attachSQL(aux, as: "aux"), binds: [])
      try await expectReadOnly(session, "aux")
    }
  }

  /// A missing file is never created, a file that is not a database and an invalid name are
  /// left out; each is named in a warning and the connection opens with the rest
  @Test("A missing or unreadable attachment warns and the connection still opens")
  func failedAttachmentsWarn() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let main = try await makeDatabase(folder, "main.sqlite")
    let good = try await makeDatabase(folder, "good.sqlite")
    let junk = folder.appendingPathComponent("junk.txt").path
    try Data(repeating: 0x41, count: 4096).write(to: URL(fileURLWithPath: junk))
    let missing = folder.appendingPathComponent("gone.sqlite").path

    try await withSession(
      main,
      attached: [
        AttachedDatabase(name: "gone", path: missing), AttachedDatabase(name: "junk", path: junk),
        AttachedDatabase(name: "main", path: good), AttachedDatabase(name: "good", path: good),
      ]
    ) { session in
      // The name check's warning first, then the session's in order
      let warnings = session.attachWarnings
      try #require(warnings.count == 3)
      #expect(warnings[0].contains(#"the name "main" is already used"#))
      #expect(warnings[1] == #"Attached database "gone" skipped: "gone.sqlite" was not found."#)
      #expect(warnings[2].hasPrefix(#"Attached database "junk" skipped: file is not a database"#))
      #expect(try await databaseNames(session) == ["main", "good"])
      #expect(try await collect(session, "SELECT count(*) FROM t") == [[.int(1)]])
    }
    #expect(try entries(folder) == ["good.sqlite", "junk.txt", "main.sqlite"])
  }

  /// A locked attachment the session was not unlocked for is never attached (the session's own
  /// check, then the manager's, which also skips it on connect); the connection opens, and a
  /// reconnect after the unlock attaches it
  @Test("A locked attachment without a grant is never attached; the connection opens")
  func lockedAttachmentIsSkipped() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let main = try await makeDatabase(folder, "main.sqlite")
    let aux = try await makeDatabase(folder, "aux.sqlite")
    let registry = LockRegistry()
    let identity = LockIdentity(ConnectionConfig(databaseType: .sqlite, database: aux))
    registry.setLockedConnections([identity])
    let attached = [AttachedDatabase(name: "aux", path: aux)]
    let locked = #"Attached database "aux" skipped: its file is locked."#

    try await withSession(main, attached: attached, registry: registry) { session in
      let names = try await databaseNames(session)
      #expect(names == ["main"])
      #expect(session.attachWarnings == [locked])
    }

    let manager = DatabaseConnectionManager(lockSource: registry)
    var config = ConnectionConfig(databaseType: .sqlite, database: main, sslMode: .disable)
    config.attachedDatabases = attached
    try await manager.connect(config: config)
    #expect(await manager.attachWarnings == [locked])
    #expect(try await managerDatabaseNames(manager) == ["main"])

    registry.grant(identity)
    try await manager.connect(config: config)
    #expect(await manager.attachWarnings.isEmpty)
    #expect(try await managerDatabaseNames(manager) == ["main", "aux"])

    // A name check's warning comes once, from the manager: the session gets only what it kept
    config.attachedDatabases = [AttachedDatabase(name: "temp", path: aux)]
    try await manager.connect(config: config)
    #expect(await manager.attachWarnings.count == 1)
    #expect(try await managerDatabaseNames(manager) == ["main"])
    await manager.disconnect()
  }

  /// A bookmarked attachment whose file was renamed, then deleted: the connection opens and the
  /// warning names it
  @Test("An attachment whose bookmarked file was deleted warns and the connection opens")
  func deletedBookmarkedAttachmentWarns() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let main = try await makeDatabase(folder, "main.sqlite")
    let aux = try await makeDatabase(folder, "aux.sqlite")
    let bookmark = try #require(
      SecurityScopedAccess.bookmarkIfPossible(for: URL(fileURLWithPath: aux)))
    let renamed = folder.appendingPathComponent("renamed.sqlite").path
    try FileManager.default.moveItem(atPath: aux, toPath: renamed)
    try FileManager.default.removeItem(atPath: renamed)
    let manager = DatabaseConnectionManager(lockSource: LockRegistry())
    var config = ConnectionConfig(databaseType: .sqlite, database: main, sslMode: .disable)
    config.attachedDatabases = [AttachedDatabase(name: "aux", path: aux, bookmark: bookmark)]

    try await manager.connect(config: config)
    let warnings = await manager.attachWarnings
    #expect(warnings.count == 1)
    #expect(warnings.first?.hasPrefix(#"Attached database "aux" skipped: "#) == true, "\(warnings)")
    #expect(try await managerDatabaseNames(manager) == ["main"])
    await manager.disconnect()

    // The workspace's connect: the warning is still there when it returns, and it is the toast
    let suite = "SQLiteAttachTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let registry = LockRegistry()
    let workspace = WorkspaceManager(
      workspace: Workspace(connectionConfig: config), restoreTabs: false,
      connectionManager: DatabaseConnectionManager(lockSource: registry), defaults: defaults,
      passwords: RecordingConnectionPasswordStore(), sanitizesFileConfig: false,
      lockCenter: LockCenter(
        registry: registry, lockVault: .lockPassword(store: InMemoryPasswordStore())))
    WorkspaceWindowManager.shared.dismissToast()
    try await workspace.connect(config: config)
    // Read the shared toast before any other await: parallel suites use the same singleton
    #expect(WorkspaceWindowManager.shared.toastState.currentToast?.message == warnings.first)
    #expect(workspace.connectionState == .connected)
    #expect(await workspace.connectionManager.attachWarnings == warnings)
    await workspace.connectionManager.disconnect()
  }

  /// A file attached while unlocked (configured, or by a typed ATTACH) stops every gated
  /// statement of the connection once relocked; a reconnect leaves it out and runs again
  @Test("A relocked attached file refuses gated statements until a reconnect skips it")
  func relockedAttachmentRefusesStatements() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let main = try await makeDatabase(folder, "main.sqlite")
    let aux = try await makeDatabase(folder, "aux.sqlite")
    let registry = LockRegistry()
    let identity = LockIdentity(ConnectionConfig(databaseType: .sqlite, database: aux))
    registry.setLockedConnections([identity])
    registry.grant(identity)
    let open = ProtectionPolicy(protectionLevel: .none)
    let manager = DatabaseConnectionManager(lockSource: registry)
    var config = ConnectionConfig(databaseType: .sqlite, database: main, sslMode: .disable)
    config.attachedDatabases = [AttachedDatabase(name: "aux", path: aux)]

    try await manager.connect(config: config)
    _ = try await manager.execute(userSQL: "SELECT count(*) FROM aux.t", policy: open)
    registry.relockAll()
    await expectLocked { _ = try await manager.execute(userSQL: "SELECT 1", policy: open) }
    try await manager.connect(config: config)
    #expect(await manager.attachWarnings.count == 1)
    #expect(try await managerDatabaseNames(manager) == ["main"])
    _ = try await manager.execute(userSQL: "SELECT 1", policy: open)

    // Typed: attached while unlocked, then relocked
    config.attachedDatabases = []
    try await manager.connect(config: config)
    registry.grant(identity)
    _ = try await manager.execute(userSQL: attachSQL(aux, as: "typed"), policy: open)
    #expect(try await managerDatabaseNames(manager) == ["main", "typed"])
    registry.relockAll()
    await expectLocked { _ = try await manager.execute(userSQL: "SELECT 1", policy: open) }
    await manager.disconnect()
  }

  /// MCP never serves a locked file: an MCP manager skips an attachment whose lock is set even
  /// after the user unlocked it in the app, and its typed ATTACH of that file is refused
  @Test("An MCP manager skips a locked attachment even when it was unlocked in the app")
  func mcpManagerSkipsLockedAttachment() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let main = try await makeDatabase(folder, "main.sqlite")
    let aux = try await makeDatabase(folder, "aux.sqlite")
    let registry = LockRegistry()
    let identity = LockIdentity(ConnectionConfig(databaseType: .sqlite, database: aux))
    registry.setLockedConnections([identity])
    registry.grant(identity)
    let manager = DatabaseConnectionManager(lockSource: registry, servesMCP: true)
    var config = ConnectionConfig(databaseType: .sqlite, database: main, sslMode: .disable)
    config.attachedDatabases = [AttachedDatabase(name: "aux", path: aux)]

    try await manager.connect(config: config)
    #expect(
      await manager.attachWarnings == [#"Attached database "aux" skipped: its file is locked."#])
    #expect(try await managerDatabaseNames(manager) == ["main"])
    let open = ProtectionPolicy(protectionLevel: .none)
    // The authorizer's refusal: SQLITE_AUTH (23) with its locked message
    do {
      _ = try await manager.execute(userSQL: attachSQL(aux, as: "typed"), policy: open)
      Issue.record("A typed ATTACH of a locked file ran")
    } catch DatabaseError.queryFailed(let message, _) {
      #expect(message.contains("the database file is locked"))
      #expect(message.hasSuffix("(\(SQLITE_AUTH))"))
    }
    #expect(try await managerDatabaseNames(manager) == ["main"])
    await manager.disconnect()
  }

  // MARK: - Authorizer

  /// The authorizer sees a quoted file name at prepare, and only that: a locked file is refused
  /// by every spelling (path, `file:` URIs, a hard link), a bound or computed name is refused
  /// whatever it names, and an unlocked file attaches
  @Test("Typed ATTACH of a locked file is refused, quoted or bound; an unlocked file attaches")
  func typedAttachOfLockedFileIsRefused() async throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let main = try await makeDatabase(folder, "main.sqlite")
    let locked = try await makeDatabase(folder, "locked.sqlite")
    let open = try await makeDatabase(folder, "open.sqlite")
    let link = folder.appendingPathComponent("link.sqlite").path
    try FileManager.default.linkItem(atPath: locked, toPath: link)
    let registry = LockRegistry()
    registry.setLockedConnections(
      [LockIdentity(ConnectionConfig(databaseType: .sqlite, database: locked))])

    let readOnlyURI = try fileURI(locked, mode: "ro")
    try await withSession(main, registry: registry) { session in
      for name in [
        locked, "file:\(locked)", "file://localhost\(locked)?mode=ro", readOnlyURI, link,
      ] {
        let refused = try await commandError(session, attachSQL(name, as: "l"))
        #expect(refused.extendedCode & 0xFF == SQLITE_AUTH, "\(name)")
        #expect(refused.message.contains("locked"), "\(name)")
      }
      for (sql, path) in [("ATTACH ? AS l", locked), ("ATTACH ? AS o", open)] {
        let refused = try await commandError(session, sql, binds: [.text(path)])
        #expect(refused.extendedCode & 0xFF == SQLITE_AUTH)
        #expect(refused.message.contains("quoted string"))
      }
      let computed = try await commandError(
        session, "ATTACH '\(folder.path)/' || 'locked.sqlite' AS l")
      #expect(computed.extendedCode & 0xFF == SQLITE_AUTH)
      #expect(try await databaseNames(session) == ["main"])

      _ = try await session.command(attachSQL(open, as: "o"), binds: [])
      #expect(try await collect(session, "SELECT count(*) FROM o.t") == [[.int(1)]])
      #expect(try await databaseNames(session) == ["main", "o"])
    }
  }

  // MARK: - Helpers

  /// `ATTACH '<path>' AS "<name>"`, the path as a string literal (quotes doubled)
  private func attachSQL(_ path: String, as name: String) -> String {
    "ATTACH '\(path.replacingOccurrences(of: "'", with: "''"))' AS \"\(name)\""
  }

  private func expectLocked(_ body: () async throws -> Void) async {
    do {
      try await body()
      Issue.record("Expected DatabaseError.connectionLocked")
    } catch DatabaseError.connectionLocked {
    } catch {
      Issue.record("Unexpected error \(error)")
    }
  }

  private func managerDatabaseNames(_ manager: DatabaseConnectionManager) async throws -> [String] {
    let session = try #require(await manager.session as? SQLiteSession)
    return try await databaseNames(session)
  }

  /// Every write to `schema` fails with SQLITE_READONLY.
  private func expectReadOnly(_ session: SQLiteSession, _ schema: String) async throws {
    let error = try await commandError(session, "INSERT INTO \(schema).t VALUES (9)")
    #expect(error.extendedCode & 0xFF == SQLITE_READONLY, "\(schema): \(error)")
    #expect(error.message == "attempt to write a readonly database", "\(schema)")
  }

  /// The `file:` URI shape of SQLiteSession's read-only open, with another `mode`.
  private func fileURI(_ path: String, mode: String) throws -> String {
    var components = URLComponents()
    components.scheme = "file"
    components.path = path
    components.queryItems = [URLQueryItem(name: "mode", value: mode)]
    return try #require(components.string)
  }

  private func databaseNames(_ session: SQLiteSession) async throws -> [String] {
    try await collect(session, "PRAGMA database_list").compactMap { row in
      guard case .string(let name)? = row.dropFirst().first else { return nil }
      return name
    }
  }

  private func commandError(
    _ session: SQLiteSession, _ sql: String, binds: [SQLBindValue] = []
  ) async throws -> SQLiteSessionError {
    try #require(
      await #expect(throws: SQLiteSessionError.self, "\(sql)") {
        _ = try await session.command(sql, binds: binds)
      })
  }

  /// A file with `t(a)` holding one row, created through the read-write open path.
  private func makeDatabase(_ folder: URL, _ name: String) async throws -> String {
    let path = folder.appendingPathComponent(name).path
    try await withSession(path) { session in
      _ = try await session.command("CREATE TABLE t (a INTEGER)", binds: [])
      _ = try await session.command("INSERT INTO t VALUES (1)", binds: [])
    }
    return path
  }

  private func withSession(
    _ path: String, readOnlyFile: Bool = false, attached: [AttachedDatabase] = [],
    registry: LockRegistry = LockRegistry(), _ body: (SQLiteSession) async throws -> Void
  ) async throws {
    var config = ConnectionConfig(
      databaseType: .sqlite, database: path, sslMode: .disable, readOnlyFile: readOnlyFile)
    config.attachedDatabases = attached
    let session = SQLiteSession(config: config, lockSource: registry)
    try await session.open()
    do {
      try await body(session)
      await session.close()
    } catch {
      await session.close()
      throw error
    }
  }

  /// Fully drained, so no statement stays open across a later DETACH.
  private func collect(_ session: SQLiteSession, _ sql: String) async throws -> [[CellValue]] {
    let source = try await session.query(sql, binds: [])
    var rows: [[CellValue]] = []
    for try await row in source.rows { rows.append(row) }
    return rows
  }

  private func entries(_ folder: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
  }

  private func makeFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-sqlite-attach-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }
}
