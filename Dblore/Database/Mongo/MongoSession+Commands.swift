// MongoSession+Commands.swift
// The commands MongoSession sends for each mongosh-subset command. Every command document is
// built as a `MongoValue` and encoded by `MongoBSONMapping.bsonDocument` (byte exact, and the
// O(n) array writer for insertMany), then carries `comment: "dblore:<uuid>"`, `maxTimeMS` (not on
// `createIndexes`) and the connection's implicit `lsid` (without it a getMore fails with code 13
// and the cursor leaks).
//
// Result shapes (`query`):
// - find / aggregate: one row per document, columns from `MongoBSONMapping.columns` (`_id` first;
//   no documents gives just `_id`).
// - countDocuments: one row, column `count` (`long`), from `$match` (+ `$skip`/`$limit`) +
//   `$group` like the drivers.
// - distinct: one row per value, one column named after the field.
// - listCollections: `name`, `type`, sorted by name (`nameOnly`, `authorizedCollections`).
// - explain (of a find or aggregate): one row, column `EXPLAIN` (`object`), the whole reply as
//   indented relaxed Extended JSON.
// Reads are buffered before rows stream, so the columns are known first. The manager already
// caps reads at `maxRows + 1`; the session also stops at `documentCap` (100,001 by default) and
// closes the cursor, so a find without a limit cannot buffer a whole collection. Every cursor is
// closed explicitly (killCursors) on every early exit; `for try await … break` would leak it.
//
// `command` tags: `INSERT n`, `UPDATE n` (updateOne/Many and replaceOne, n = matched, upserts
// included), `DELETE n`; `affectedRows` is n. `$out`/`$merge` aggregates run here with tag
// `AGGREGATE` (no count). Write errors come back in an `ok: 1` reply (duplicate key 11000 does not
// throw in the driver) and are thrown as `MongoSessionError`, as are write concern errors. Admin
// commands (`affectedRows` 0): `CREATE INDEX`, `DROP INDEX`, `HIDE INDEX`, `UNHIDE INDEX`,
// `CREATE COLLECTION`, `CREATE VIEW`, `DROP`, `RENAME` (sent to `admin`), `COLLMOD`.

import BSON
import Foundation
import MongoClient
import MongoKitten

extension MongoSession {
  typealias Field = MongoValue.Field

  // MARK: - DatabaseSession statements

  /// Runs one read command and returns its buffered rows. Binds, text that is not exactly one
  /// command of the subset (the parser's error), and anything the classifier does not mark as a
  /// read (defense in depth for MCP, which holds the raw session) are refused before anything
  /// is sent.
  func query(_ sql: String, binds: [SQLBindValue]) async throws -> SessionRowSource {
    guard binds.isEmpty else { throw MongoSessionError.bindsRefused }
    let command = try MongoshParser.parse(sql)
    guard MongoCommandClassifier.classifyStatement(sql)?.kind == .read else {
      throw MongoSessionError(
        message: "Only read commands return rows here; writes and $out/$merge run as commands.")
    }
    let (columns, rows) = try await read(command)
    let (stream, continuation) = AsyncThrowingStream.makeStream(
      of: [CellValue].self, throwing: Error.self, bufferingPolicy: .unbounded)
    for row in rows { continuation.yield(row) }
    continuation.finish()
    return SessionRowSource(columns: columns, rows: stream)
  }

  /// Runs one write, `$out`/`$merge` aggregate or admin command and returns its tag.
  func command(_ sql: String, binds: [SQLBindValue]) async throws -> CommandResult {
    guard binds.isEmpty else { throw MongoSessionError.bindsRefused }
    let command = try MongoshParser.parse(sql)
    guard let write = Self.writeCommand(command, in: databaseName),
      MongoCommandClassifier.classifyStatement(sql)?.kind != .read
    else {
      throw MongoSessionError(message: "Read commands return rows; run them as a query.")
    }
    let (fields, database) = write
    // An index build on a large collection outlasts any statement timeout: no `maxTimeMS`, and
    // Cancel (killOp by the comment) still stops it.
    let timed: Bool
    if case .admin(.createIndex) = command { timed = false } else { timed = true }
    return try await withStatement { token, connection in
      let reply = try await execute(
        fields, token: token, on: connection, database: database, statementTimeout: timed)
      if case .aggregate = command {
        // `$out`/`$merge` return an empty first batch; close a cursor the server kept anyway.
        if let cursor = reply["cursor"] as? Document, let id = Self.int(cursor["id"]), id != 0 {
          await Self.close(
            makeCursor(id: Int64(id), cursor: cursor, connection: connection, database: database))
        }
      }
      return try Self.commandResult(for: command, reply: try MongoBSONMapping.document(reply))
    }
  }

  /// Catalog reads of `MongoSchemaIntrospector`: one cursor command (`listCollections`, `find`,
  /// `aggregate`) as a statement (cancellable), at most `cap` documents. `maxTimeMS` replaces
  /// the statement timeout for this command only.
  func catalogDocuments(
    _ fields: [Field], cap: Int, maxTimeMS: Int64? = nil
  ) async throws -> [MongoValue] {
    let database = databaseName
    return try await withStatement { token, connection in
      try await readCursor(
        fields, cap: cap, token: token, connection: connection, database: database,
        maxTimeMS: maxTimeMS)
    }
  }

  /// Catalog command of `MongoSchemaIntrospector` with a single reply (`count`).
  func catalogCommand(_ fields: [Field], maxTimeMS: Int64? = nil) async throws -> MongoValue {
    let database = databaseName
    return try await withStatement { token, connection in
      try MongoBSONMapping.document(
        try await execute(
          fields, token: token, on: connection, database: database, maxTimeMS: maxTimeMS))
    }
  }

  /// `hello` on `admin` (the probe).
  func hello() async throws {
    _ = try await withStatement { token, connection in
      try await execute(
        [Field("hello", .int32(1))], token: token, on: connection, database: "admin")
    }
  }

  // MARK: - Reads

  /// The documents of one find or aggregate as typed BSON, at most `documentCap`, as one
  /// statement (cancellable, the statement timeout shortened by the command's `maxTimeMS`).
  /// Anything else, including an aggregate with `$out`/`$merge`, is refused before anything is
  /// sent (defense in depth: the manager's gate already allowed only reads).
  func readDocuments(_ command: MongoCommand) async throws -> [MongoValue] {
    let isDocumentRead: Bool
    switch command {
    case .find, .aggregate:
      isDocumentRead = MongoCommandClassifier.classifyStatement(command.render())?.kind == .read
    default:
      isDocumentRead = false
    }
    guard isDocumentRead else {
      throw MongoSessionError(
        message: "Only read commands return documents: a find, or an aggregate without "
          + "$out/$merge.")
    }
    let database = databaseName
    let cap = documentCap
    return try await withStatement { token, connection in
      try await readDocuments(
        command, cap: cap, token: token, connection: connection, database: database)
    }
  }

  /// The find / aggregate branch of `read` and `readDocuments`, inside their statement.
  private func readDocuments(
    _ command: MongoCommand, cap: Int, token: String, connection: MongoConnection,
    database: String
  ) async throws -> [MongoValue] {
    try await readCursor(
      Self.readCommand(command), cap: cap, token: token, connection: connection,
      database: database, maxTimeMS: statementMaxTimeMS(Self.userMaxTimeMS(command)))
  }

  private func read(_ command: MongoCommand) async throws -> ([ColumnInfo], [[CellValue]]) {
    let database = databaseName
    let cap = documentCap
    return try await withStatement { token, connection in
      switch command {
      case .find, .aggregate:
        let documents = try await readDocuments(
          command, cap: cap, token: token, connection: connection, database: database)
        let columns = MongoBSONMapping.columns(for: documents)
        return (columns, documents.map { MongoBSONMapping.row(for: $0, columns: columns) })
      case .countDocuments(let collection, let filter, let options):
        let documents = try await readCursor(
          Self.countCommand(collection: collection, filter: filter, options: options), cap: 1,
          token: token, connection: connection, database: database,
          maxTimeMS: statementMaxTimeMS(
            options.flatMap { Self.intValue(Self.field("maxTimeMS", of: $0)) }))
        return Self.countResult(documents)
      case .distinct(_, let field, _):
        let reply = try await execute(
          Self.readCommand(command), token: token, on: connection, database: database)
        guard let array = reply["values"] as? Document,
          case .array(let values) = try MongoBSONMapping.document(array)
        else { throw Self.unexpectedReply }
        return Self.distinctResult(field: field, values: Array(values.prefix(cap)))
      case .listCollections:
        let documents = try await readCursor(
          Self.readCommand(command), cap: cap, token: token, connection: connection,
          database: database)
        return Self.collectionsResult(documents)
      case .explain(let inner, let verbosity):
        guard let fields = Self.explainCommand(inner, verbosity: verbosity) else {
          throw MongoSessionError(message: "Only a find or an aggregate can be explained.")
        }
        let reply = try await execute(
          fields, token: token, on: connection, database: database,
          maxTimeMS: statementMaxTimeMS(Self.userMaxTimeMS(inner)))
        return Self.explainResult(try MongoBSONMapping.document(reply))
      default:
        throw MongoSessionError(message: "Read commands return rows; run them as a query.")
      }
    }
  }

  /// The `maxTimeMS` option of a find or an aggregate, nil for any other command.
  private static func userMaxTimeMS(_ command: MongoCommand) -> Int? {
    switch command {
    case .find(_, _, _, _, _, _, let options), .aggregate(_, _, let options): options.maxTimeMS
    default: nil
    }
  }

  /// The `maxTimeMS` of a read with a user `maxTimeMS`: the statement timeout is a brake the user
  /// can shorten but never lengthen. 0 means "no limit" to the server, so it (like nil) keeps the
  /// statement timeout.
  private func statementMaxTimeMS(_ user: Int?) -> Int64? {
    guard let user, user > 0 else { return nil }
    return min(Int64(user), maxTimeMS)
  }

  /// Runs a cursor command and buffers at most `cap` documents. The cursor is closed whenever
  /// the server still holds it (cap reached, error, cancel).
  private func readCursor(
    _ fields: [Field], cap: Int, token: String, connection: MongoConnection, database: String,
    maxTimeMS: Int64? = nil
  ) async throws -> [MongoValue] {
    let reply = try await execute(
      fields, token: token, on: connection, database: database, maxTimeMS: maxTimeMS)
    guard let cursorReply = reply["cursor"] as? Document, let id = Self.int(cursorReply["id"]),
      let batch = cursorReply["firstBatch"] as? Document,
      case .array(let first) = try MongoBSONMapping.document(batch)
    else { throw Self.unexpectedReply }
    var documents = Array(first.prefix(cap))
    guard id != 0 else { return documents }
    let cursor = makeCursor(
      id: Int64(id), cursor: cursorReply, connection: connection, database: database)
    do {
      // The cursor starts with an empty batch: the first one was decoded above.
      _ = try await cursor.getMore(batchSize: 0)
      while !cursor.isDrained, documents.count < cap {
        let batch = try await cursor.getMore(batchSize: min(cap - documents.count, 10_000))
        for document in batch.prefix(cap - documents.count) {
          documents.append(try MongoBSONMapping.document(document))
        }
      }
    } catch {
      await Self.close(cursor)
      throw error
    }
    await Self.close(cursor)
    return documents
  }

  /// `MongoCursor` over a reply's cursor id and namespace (`db.collection`), with an empty first
  /// batch and the connection's implicit session (the one the command was sent with).
  private func makeCursor(
    id: Int64, cursor: Document, connection: MongoConnection, database: String
  ) -> MongoCursor {
    let namespace = cursor["ns"] as? String ?? ""
    let parts = namespace.split(separator: ".", maxSplits: 1)
    let mongoNamespace =
      parts.count == 2
      ? MongoNamespace(to: String(parts[1]), inDatabase: String(parts[0]))
      : MongoNamespace(to: namespace, inDatabase: database)
    return MongoCursor(
      reply: MongoCursorResponse.Cursor(id: id, namespace: namespace, firstBatch: []),
      in: mongoNamespace, connection: connection, session: connection.implicitSession,
      transaction: nil)
  }

  /// killCursors when the server still holds the cursor. Best effort: the statement's own
  /// outcome is what the caller reports.
  private static func close(_ cursor: MongoCursor) async {
    guard cursor.id != 0 else { return }
    try? await cursor.close()
  }

  /// Sends `fields` plus `comment`, `maxTimeMS` (the statement timeout unless given; none at all
  /// when `statementTimeout` is false) and `lsid`; throws the error of an `ok: 0` reply.
  func execute(
    _ fields: [Field], token: String, on connection: MongoConnection, database: String,
    maxTimeMS: Int64? = nil, statementTimeout: Bool = true
  ) async throws -> Document {
    let timeout = maxTimeMS ?? self.maxTimeMS
    let document = try MongoBSONMapping.bsonDocument(
      .document(
        fields + [Field("comment", .string(token))]
          + (statementTimeout ? [Field("maxTimeMS", .int64(timeout))] : []))
    )
    let reply = try await connection.execute(
      document, namespace: MongoNamespace(to: "$cmd", inDatabase: database),
      sessionId: connection.implicitSessionId
    ).getDocument()
    try Self.checkOK(reply)
    return reply
  }

  /// The database every command runs in (`test` when the connection names none).
  var databaseName: String {
    config.database.isEmpty ? Self.defaultDatabase : config.database
  }

  private static let unexpectedReply = MongoSessionError(
    message: "The server sent an unexpected reply.")

  // MARK: - Command documents

  /// find, aggregate, distinct and listCollections. A negative find limit is mongosh's "at most
  /// abs(n) documents in one batch": sent as `limit` and `batchSize` abs(n) (capped at 10,000),
  /// never `singleBatch`, which a find on a view (run as an aggregate) refuses with code 168.
  /// `readCursor` closes any cursor the server keeps. `limit(0)` means no limit. Never a
  /// `maxTimeMS` field: `execute` adds it to every command, and a second one is a duplicate key.
  static func readCommand(_ command: MongoCommand) -> [Field] {
    switch command {
    case .find(
      let collection, let filter, let projection, let sort, let skip, let limit, let options):
      var fields = [Field("find", .string(collection))]
      if let filter { fields.append(Field("filter", filter)) }
      if let projection { fields.append(Field("projection", projection)) }
      if let sort { fields.append(Field("sort", sort)) }
      if let skip { fields.append(Field("skip", .int64(Int64(skip)))) }
      if let limit, limit != 0 {
        let count = Int64(clamping: limit.magnitude)
        fields.append(Field("limit", .int64(count)))
        if limit < 0 { fields.append(Field("batchSize", .int64(min(count, 10_000)))) }
      }
      if let collation = options.collation { fields.append(Field("collation", collation)) }
      if let hint = options.hint { fields.append(Field("hint", hint)) }
      return fields
    case .aggregate(let collection, let pipeline, let options):
      return aggregateCommand(collection: collection, pipeline: pipeline, options: options)
    case .distinct(let collection, let field, let filter):
      var fields = [Field("distinct", .string(collection)), Field("key", .string(field))]
      if let filter { fields.append(Field("query", filter)) }
      return fields
    case .listCollections:
      return [
        Field("listCollections", .int32(1)), Field("nameOnly", .bool(true)),
        Field("authorizedCollections", .bool(true)), Field("cursor", .document([])),
      ]
    default:
      return []
    }
  }

  /// countDocuments as the drivers run it: `$match`, then `$skip` and `$limit` from the options,
  /// then `$group` with `$sum: 1`; `collation` and `hint` go on the aggregate. A limit of 0 means
  /// no limit (the server refuses `$limit: 0`). The options' `maxTimeMS` is never a field here
  /// (`execute` adds one): `read` passes it to `execute`.
  static func countCommand(
    collection: String, filter: MongoValue?, options: MongoValue? = nil
  ) -> [Field] {
    var pipeline: [MongoValue] = []
    if let filter { pipeline.append(.document([Field("$match", filter)])) }
    let option = { (key: String) in options.flatMap { field(key, of: $0) } }
    if let skip = intValue(option("skip")), skip > 0 {
      pipeline.append(.document([Field("$skip", .int64(Int64(skip)))]))
    }
    if let limit = intValue(option("limit")), limit > 0 {
      pipeline.append(.document([Field("$limit", .int64(Int64(limit)))]))
    }
    pipeline.append(
      .document([
        Field(
          "$group",
          .document([
            Field("_id", .int32(1)), Field("n", .document([Field("$sum", .int32(1))])),
          ]))
      ]))
    var fields = aggregateCommand(collection: collection, pipeline: pipeline)
    if let collation = option("collation") { fields.append(Field("collation", collation)) }
    if let hint = option("hint") { fields.append(Field("hint", hint)) }
    return fields
  }

  /// `explain` of a find or aggregate (nil for any other command): the inner command exactly as
  /// `readCommand` builds it (no row cap), with the user `maxTimeMS` inside it. `execute` adds
  /// the outer `maxTimeMS` and `comment`.
  static func explainCommand(_ command: MongoCommand, verbosity: String) -> [Field]? {
    var inner: [Field]
    switch command {
    case .find(_, _, _, _, _, _, let options), .aggregate(_, _, let options):
      inner = readCommand(command)
      if let maxTimeMS = options.maxTimeMS, maxTimeMS > 0 {
        inner.append(Field("maxTimeMS", .int64(Int64(maxTimeMS))))
      }
    default:
      return nil
    }
    return [Field("explain", .document(inner)), Field("verbosity", .string(verbosity))]
  }

  /// `collation` and `hint` from `options` when set; never `maxTimeMS` (see `readCommand`).
  private static func aggregateCommand(
    collection: String, pipeline: [MongoValue], options: MongoCommand.CursorOptions = .none
  ) -> [Field] {
    var fields = [
      Field("aggregate", .string(collection)), Field("pipeline", .array(pipeline)),
      Field("cursor", .document([])),
    ]
    if let collation = options.collation { fields.append(Field("collation", collation)) }
    if let hint = options.hint { fields.append(Field("hint", hint)) }
    return fields
  }

  /// The write command of `command` (and the aggregate of `$out`/`$merge`, and the admin
  /// command) with the database it runs in: `database`, or `admin` for a rename; nil for reads.
  static func writeCommand(
    _ command: MongoCommand, in database: String = MongoSession.defaultDatabase
  ) -> (fields: [Field], database: String)? {
    let fields: [Field]
    switch command {
    case .insertOne(let collection, let document):
      fields = insertCommand(collection, [document])
    case .insertMany(let collection, let documents):
      fields = insertCommand(collection, documents)
    case .updateOne(let collection, let filter, let update, let upsert):
      fields = updateCommand(collection, filter, update, upsert: upsert, multi: false)
    case .updateMany(let collection, let filter, let update, let upsert):
      fields = updateCommand(collection, filter, update, upsert: upsert, multi: true)
    case .replaceOne(let collection, let filter, let replacement, let upsert):
      fields = updateCommand(collection, filter, replacement, upsert: upsert, multi: false)
    case .deleteOne(let collection, let filter):
      fields = deleteCommand(collection, filter, limit: 1)
    case .deleteMany(let collection, let filter):
      fields = deleteCommand(collection, filter, limit: 0)
    case .aggregate(let collection, let pipeline, let options):
      fields = aggregateCommand(collection: collection, pipeline: pipeline, options: options)
    case .admin(let admin):
      return admin.commandDocument(in: database)
    case .find, .countDocuments, .distinct, .listCollections, .explain:
      return nil
    }
    return (fields, database)
  }

  private static func insertCommand(_ collection: String, _ documents: [MongoValue]) -> [Field] {
    [
      Field("insert", .string(collection)), Field("documents", .array(documents)),
      Field("ordered", .bool(true)),
    ]
  }

  private static func updateCommand(
    _ collection: String, _ filter: MongoValue, _ update: MongoValue, upsert: Bool, multi: Bool
  ) -> [Field] {
    let statement = MongoValue.document([
      Field("q", filter), Field("u", update), Field("upsert", .bool(upsert)),
      Field("multi", .bool(multi)),
    ])
    return [
      Field("update", .string(collection)), Field("updates", .array([statement])),
      Field("ordered", .bool(true)),
    ]
  }

  private static func deleteCommand(
    _ collection: String, _ filter: MongoValue, limit: Int32
  ) -> [Field] {
    let statement = MongoValue.document([Field("q", filter), Field("limit", .int32(limit))])
    return [
      Field("delete", .string(collection)), Field("deletes", .array([statement])),
      Field("ordered", .bool(true)),
    ]
  }

  // MARK: - Results

  /// The tag of a write reply. Write errors and write concern errors throw.
  static func commandResult(for command: MongoCommand, reply: MongoValue) throws -> CommandResult {
    let written = intValue(field("n", of: reply)) ?? 0
    if case .array(let errors)? = field("writeErrors", of: reply), let first = errors.first {
      var message = stringValue(field("errmsg", of: first)) ?? "The write failed."
      if written > 0 {
        message += " (\(written) written before the error)"
      }
      throw MongoSessionError(
        code: intValue(field("code", of: first)),
        codeName: stringValue(field("codeName", of: first)),
        message: message)
    }
    if let concern = field("writeConcernError", of: reply) {
      throw MongoSessionError(
        code: intValue(field("code", of: concern)),
        codeName: stringValue(field("codeName", of: concern)),
        message: "Write concern error: "
          + (stringValue(field("errmsg", of: concern)) ?? "the write was not acknowledged."))
    }
    switch command {
    case .insertOne, .insertMany:
      return CommandResult(affectedRows: written, tag: "INSERT \(written)")
    case .updateOne, .updateMany, .replaceOne:
      return CommandResult(affectedRows: written, tag: "UPDATE \(written)")
    case .deleteOne, .deleteMany:
      return CommandResult(affectedRows: written, tag: "DELETE \(written)")
    case .aggregate:
      return CommandResult(affectedRows: 0, tag: "AGGREGATE")
    case .find, .countDocuments, .distinct, .listCollections, .explain:
      throw MongoSessionError(message: "Read commands return rows; run them as a query.")
    case .admin(let admin):
      return CommandResult(affectedRows: 0, tag: adminTag(admin))
    }
  }

  /// The tag of an admin command (its reply has no count).
  private static func adminTag(_ command: MongoAdminCommand) -> String {
    switch command {
    case .createIndex: "CREATE INDEX"
    case .dropIndex: "DROP INDEX"
    case .setIndexHidden(_, _, let hidden): hidden ? "HIDE INDEX" : "UNHIDE INDEX"
    case .createCollection: "CREATE COLLECTION"
    case .createView: "CREATE VIEW"
    case .drop: "DROP"
    case .renameCollection: "RENAME"
    case .collMod: "COLLMOD"
    }
  }

  /// One row with the count (0 when nothing matched).
  static func countResult(_ documents: [MongoValue]) -> ([ColumnInfo], [[CellValue]]) {
    let count = documents.first.flatMap { intValue(field("n", of: $0)) } ?? 0
    return ([ColumnInfo(name: "count", type: "long")], [[.int(count)]])
  }

  /// One row per value in a column named after the field (`null` typed when there are none).
  static func distinctResult(field: String, values: [MongoValue]) -> ([ColumnInfo], [[CellValue]]) {
    let column =
      values.isEmpty
      ? ColumnInfo(name: field, type: "null")
      : ColumnInfo(
        name: field,
        type: MongoBSONMapping.columns(for: values.map { .document([Field("v", $0)]) }).first?
          .type ?? "null")
    return ([column], values.map { [MongoBSONMapping.cellValue($0)] })
  }

  /// One row holding the explain reply as indented relaxed Extended JSON.
  static func explainResult(_ reply: MongoValue) -> ([ColumnInfo], [[CellValue]]) {
    let text = MongoRelaxedJSON.render(reply, as: .relaxedExtendedJSON, indented: true)
    return ([ColumnInfo(name: "EXPLAIN", type: "object")], [[.json(text)]])
  }

  /// `name` and `type` of each collection, by name.
  static func collectionsResult(_ documents: [MongoValue]) -> ([ColumnInfo], [[CellValue]]) {
    let columns = [
      ColumnInfo(name: "name", type: "string"), ColumnInfo(name: "type", type: "string"),
    ]
    let sorted = documents.sorted {
      (stringValue(field("name", of: $0)) ?? "") < (stringValue(field("name", of: $1)) ?? "")
    }
    return (columns, sorted.map { MongoBSONMapping.row(for: $0, columns: columns) })
  }

  private static func field(_ key: String, of value: MongoValue) -> MongoValue? {
    guard case .document(let fields) = value else { return nil }
    return fields.first { $0.key == key }?.value
  }

  private static func intValue(_ value: MongoValue?) -> Int? {
    switch value {
    case .int32(let number)?: Int(number)
    case .int64(let number)?: Int(number)
    case .double(let number)? where number.isFinite && number.rounded() == number:
      Int(exactly: number)
    default: nil
    }
  }

  private static func stringValue(_ value: MongoValue?) -> String? {
    if case .string(let text)? = value { return text }
    return nil
  }
}
