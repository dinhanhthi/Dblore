// MongoSessionTests.swift
// MongoSession: connection planning (URI, authSource, directConnection, +srv through a fake
// resolver, the IP + TLS refusal), the refusals in `query`/`command`, write tags, result shapes
// and error text without a server; then, against the docker fixtures (mongo:8.0 on 27018,
// requireTLS copy on 27019), connect and probe through the manager, reads, writes, maxTimeMS,
// killOp cancel, cursor cleanup, the direct-connection pool, close events and TLS. Live cases
// are opt-in (`.requiresMongo`, `.requiresMongoTLS`) and serialized (the cursor test reads the
// server-wide open-cursor count).

import BSON
import Foundation
import MongoClient
import MongoKitten
import NIOCore
import Testing

@testable import Dblore

@Suite(.serialized, .timeLimit(.minutes(5))) @MainActor
struct MongoSessionTests {
  // MARK: - Fixtures

  static let plainURI =
    "mongodb://\(TestMongoDatabase.host):\(TestMongoDatabase.port)/\(TestMongoDatabase.database)"
    + "?authSource=\(TestMongoDatabase.authSource)"

  static func config(
    uri: String? = plainURI, host: String = TestMongoDatabase.host,
    port: Int = TestMongoDatabase.port, database: String = TestMongoDatabase.database,
    username: String = TestMongoDatabase.username, password: String = TestMongoDatabase.password,
    sslMode: SSLMode = .disable
  ) -> ConnectionConfig {
    var config = ConnectionConfig(
      databaseType: .mongodb, host: host, port: port, database: database, username: username,
      password: password, sslMode: sslMode, rememberConnection: false, timeoutSeconds: 10)
    config.mongoURI = uri
    return config
  }

  /// Records SRV/TXT lookups and answers with fixed records.
  final class FakeResolver: MongoSRVResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    let srv: [MongoSRVRecord]
    let txt: [String]

    init(srv: [MongoSRVRecord], txt: [String] = []) {
      self.srv = srv
      self.txt = txt
    }

    var lookups: [String] { lock.withLock { names } }

    func srvRecords(_ name: String) async throws -> [MongoSRVRecord] {
      lock.withLock { names.append("SRV " + name) }
      return srv
    }

    func txtRecords(_ name: String) async throws -> [String] {
      lock.withLock { names.append("TXT " + name) }
      return txt
    }
  }

  static func plan(
    _ config: ConnectionConfig, resolver: any MongoSRVResolving = FakeResolver(srv: []),
    material: ClientCertificateMaterial? = nil
  ) async throws -> MongoConnectionPlan {
    try await MongoSession.plan(config: config, material: material, resolver: resolver)
  }

  static func failure(_ body: () async throws -> Void) async -> (any Error)? {
    do {
      try await body()
      return nil
    } catch {
      return error
    }
  }

  static func connectionFailure(_ error: (any Error)?) -> String? {
    guard case DatabaseError.connectionFailed(let message)? = error else { return nil }
    return message
  }

  static func reply(_ fields: (String, MongoValue)...) -> MongoValue {
    .document(fields.map { MongoValue.Field($0.0, $0.1) })
  }

  // MARK: - Connection plan

  @Test("authSource: URI option, else the connection's database, else admin; database test")
  func authSourceDefaults() async throws {
    let explicit = try await Self.plan(Self.config())
    #expect(explicit.authSource == "admin")
    #expect(explicit.database == TestMongoDatabase.database)

    let database = try await Self.plan(
      Self.config(uri: "mongodb://db.example.com/sales", database: "sales"))
    #expect(database.authSource == "sales")
    #expect(database.database == "sales")

    let none = try await Self.plan(Self.config(uri: "mongodb://db.example.com", database: ""))
    #expect(none.authSource == "admin")
    #expect(none.database == "test")
  }

  @Test("Hosts, credentials, mechanism and pool come from the URI and the config")
  func settingsFromURI() async throws {
    let cluster = try await Self.plan(
      Self.config(
        uri: "mongodb://a.example.com:27020,b.example.com/app?authMechanism=SCRAM-SHA-1"
          + "&appName=Report",
        database: "app", username: "ann", password: "secret"))
    #expect(!cluster.isDirect)
    #expect(
      cluster.settings.hosts == [
        ConnectionSettings.Host(hostname: "a.example.com", port: 27020),
        ConnectionSettings.Host(hostname: "b.example.com", port: 27017),
      ])
    #expect(cluster.settings.authentication == .scramSha1(username: "ann", password: "secret"))
    #expect(cluster.settings.applicationName == "Report")
    #expect(!cluster.usesTLS)

    let direct = try await Self.plan(
      Self.config(uri: "mongodb://a.example.com/app?directConnection=true", database: "app"))
    #expect(direct.isDirect)

    let auto = try await Self.plan(Self.config(username: "ann", password: "pw"))
    #expect(auto.settings.authentication == .auto(username: "ann", password: "pw"))
    let anonymous = try await Self.plan(Self.config(username: ""))
    #expect(anonymous.settings.authentication == .unauthenticated)
  }

  @Test("Without a stored URI the host and port of the config are used")
  func hostPortFallback() async throws {
    let plan = try await Self.plan(
      Self.config(uri: nil, host: "mongo.example.com", port: 27100, database: "inventory"))
    #expect(
      plan.settings.hosts == [ConnectionSettings.Host(hostname: "mongo.example.com", port: 27100)])
    #expect(plan.authSource == "inventory")
    #expect(!plan.isDirect)
  }

  @Test("TLS to an IP literal is refused before anything connects")
  func ipLiteralWithTLSRefused() async throws {
    let cases: [ConnectionConfig] = [
      Self.config(uri: nil, host: "127.0.0.1", sslMode: .verifyFull),
      Self.config(uri: "mongodb://db.example.com,10.0.0.7/app?tls=true", sslMode: .verifyFull),
      Self.config(uri: "mongodb://[::1]:27017/app?tls=true", sslMode: .verifyFull),
    ]
    for config in cases {
      let error = await Self.failure { _ = try await Self.plan(config) }
      #expect(Self.connectionFailure(error) == MongoSession.ipTLSMessage)
    }
    #expect(
      MongoSession.ipTLSMessage == "TLS to MongoDB needs the server's host name, not an IP address."
    )
    // The same refusal through open(), and none without TLS.
    let session = MongoSession(config: cases[0])
    let opened = await Self.failure { try await session.open() }
    await session.close()
    #expect(Self.connectionFailure(opened) == MongoSession.ipTLSMessage)
    let plain = try await Self.plan(Self.config(uri: nil, host: "127.0.0.1"))
    #expect(!plain.usesTLS)
  }

  @Test("+srv resolves _mongodb._tcp and TXT through the resolver; the URI wins over TXT")
  func srvThroughResolver() async throws {
    let resolver = FakeResolver(
      srv: [
        MongoSRVRecord(
          priority: 0, weight: 0, port: 27017, target: "shard-00.cluster0.example.com"),
        MongoSRVRecord(
          priority: 0, weight: 0, port: 27018, target: "shard-01.cluster0.example.com"),
      ],
      txt: ["authSource=admin&replicaSet=atlas-0"])
    let config = Self.config(
      uri: "mongodb+srv://cluster0.example.com/shop", database: "shop", sslMode: .verifyFull)
    let plan = try await Self.plan(config, resolver: resolver)
    #expect(
      resolver.lookups == ["SRV _mongodb._tcp.cluster0.example.com", "TXT cluster0.example.com"])
    #expect(
      plan.settings.hosts == [
        ConnectionSettings.Host(hostname: "shard-00.cluster0.example.com", port: 27017),
        ConnectionSettings.Host(hostname: "shard-01.cluster0.example.com", port: 27018),
      ])
    #expect(plan.authSource == "admin")
    #expect(plan.usesTLS)
    #expect(!plan.settings.isSRV)

    let overridden = try await Self.plan(
      Self.config(
        uri: "mongodb+srv://cluster0.example.com/shop?authSource=shop", database: "shop",
        sslMode: .verifyFull),
      resolver: resolver)
    #expect(overridden.authSource == "shop")
  }

  @Test("+srv refuses targets outside the domain, short hosts, extra TXT options and no records")
  func srvValidation() async throws {
    let srv = "mongodb+srv://cluster0.example.com/shop"
    let outside = FakeResolver(
      srv: [MongoSRVRecord(priority: 0, weight: 0, port: 27017, target: "evil.example.org")])
    let notInDomain = await Self.failure {
      _ = try await Self.plan(Self.config(uri: srv, sslMode: .verifyFull), resolver: outside)
    }
    #expect(Self.connectionFailure(notInDomain)?.contains("outside the domain") == true)

    let good = [MongoSRVRecord(priority: 0, weight: 0, port: 1, target: "a.cluster0.example.com")]
    let badTXT = FakeResolver(srv: good, txt: ["ssl=false"])
    let txtError = await Self.failure {
      _ = try await Self.plan(Self.config(uri: srv, sslMode: .verifyFull), resolver: badTXT)
    }
    #expect(Self.connectionFailure(txtError)?.contains("TXT") == true)

    let twoTXT = FakeResolver(srv: good, txt: ["authSource=a", "authSource=b"])
    let twoError = await Self.failure {
      _ = try await Self.plan(Self.config(uri: srv, sslMode: .verifyFull), resolver: twoTXT)
    }
    #expect(Self.connectionFailure(twoError)?.contains("more than one TXT") == true)

    let empty = await Self.failure {
      _ = try await Self.plan(
        Self.config(uri: srv, sslMode: .verifyFull), resolver: FakeResolver(srv: []))
    }
    #expect(Self.connectionFailure(empty)?.contains("No SRV record") == true)

    let short = await Self.failure {
      _ = try await Self.plan(
        Self.config(uri: "mongodb+srv://example.com", sslMode: .verifyFull),
        resolver: FakeResolver(srv: good))
    }
    #expect(Self.connectionFailure(short)?.contains("three parts") == true)
  }

  @Test("SRV and TXT record bytes are parsed; compression pointers are refused")
  func dnsRecordParsing() {
    let srv: [UInt8] =
      [0, 1, 0, 2, 0x69, 0x89] + [5] + Array("shard".utf8) + [7] + Array("example".utf8)
      + [3] + Array("com".utf8) + [0]
    #expect(
      MongoSRV.parseSRV(srv)
        == MongoSRVRecord(priority: 1, weight: 2, port: 27017, target: "shard.example.com"))
    #expect(MongoSRV.parseSRV([0, 0, 0, 0, 0x69, 0x89, 0xC0, 0x0C]) == nil)
    #expect(MongoSRV.parseSRV([0, 1]) == nil)
    let txt: [UInt8] = [11] + Array("authSource=".utf8) + [5] + Array("admin".utf8)
    #expect(MongoSRV.parseTXT(txt) == "authSource=admin")
    #expect(MongoSRV.parseTXT([9, 0x61]) == nil)
  }

  @Test("A custom CA that is not PEM, or a client certificate, is refused")
  func certificateMaterialChecks() async throws {
    let config = Self.config(uri: "mongodb://db.example.com/app?tls=true", sslMode: .verifyFull)
    let badPEM = await Self.failure {
      _ = try await Self.plan(
        config, material: ClientCertificateMaterial(caPEM: "not a certificate"))
    }
    #expect(Self.connectionFailure(badPEM) == "The custom CA certificate could not be read.")

    var withCertificate = config
    withCertificate.clientCertificate = ClientCertificateInfo(
      subject: "client", expiry: nil, hasCA: true)
    let scoped = ClientCertificateStoreFactory.ScopedMaterial(
      account: ClientCertificateStoreFactory.account(for: withCertificate),
      material: ClientCertificateMaterial(certificatePEM: "c", privateKeyPEM: "k", caPEM: "ca"))
    let refused = await ClientCertificateStoreFactory.$operationMaterial.withValue(scoped) {
      await Self.failure { _ = try MongoSession.certificateMaterial(for: withCertificate) }
    }
    #expect(
      Self.connectionFailure(refused)?.contains("Client certificates are not supported") == true)
  }

  // MARK: - Refusals before sending

  @Test("Binds are refused by query and command")
  func bindsRefused() async {
    let session = MongoSession(config: Self.config())
    let query = await Self.failure {
      _ = try await session.query("db.c.find()", binds: [.text("x")])
    }
    let command = await Self.failure {
      _ = try await session.command("db.c.insertOne({a: 1})", binds: [.null])
    }
    #expect(query as? MongoSessionError == .bindsRefused)
    #expect(command as? MongoSessionError == .bindsRefused)
  }

  @Test(
    "query and readDocuments refuse writes and $out/$merge; command refuses reads; bad text throws the parser's error"
  )
  func nonReadRefusedInQuery() async {
    let session = MongoSession(config: Self.config())
    for text in [
      "db.c.insertOne({a: 1})", "db.c.deleteMany({})", "db.c.aggregate([{$out: \"x\"}])",
      "db.c.aggregate([{$match: {}}, {$merge: {into: \"x\"}}])",
    ] {
      let error = await Self.failure { _ = try await session.query(text, binds: []) }
      #expect(
        (error as? MongoSessionError)?.message.contains("Only read commands") == true, "\(text)")
      let documents = await Self.failure {
        _ = try await session.readDocuments(try MongoshParser.parse(text))
      }
      #expect(
        (documents as? MongoSessionError)?.message.contains("Only read commands") == true,
        "\(text)")
    }
    for text in ["db.c.find()", "show collections", "db.c.aggregate([{$match: {}}])"] {
      let error = await Self.failure { _ = try await session.command(text, binds: []) }
      #expect((error as? MongoSessionError)?.message.contains("Read commands") == true, "\(text)")
    }
    let parse = await Self.failure { _ = try await session.query("db.c.frobnicate()", binds: []) }
    #expect((parse as? MongoshParser.ParseError)?.message.contains("not supported") == true)
    let two = await Self.failure {
      _ = try await session.query("db.c.find(); db.c.find()", binds: [])
    }
    #expect(two is MongoshParser.ParseError)
    // A read on a session that never opened reaches the pool and fails closed.
    let closed = await Self.failure { _ = try await session.query("db.c.find()", binds: []) }
    #expect(closed as? MongoSessionError == .closed)
  }

  @Test("Server cursors are not supported")
  func cursorMethodsThrow() async {
    let session = MongoSession(config: Self.config())
    #expect(
      await Self.failure { _ = try await session.openCursor("db.c.find()", binds: []) } != nil)
    let cursor = SessionCursor(name: "c")
    #expect(await Self.failure { _ = try await session.fetch(cursor, maxRows: 1) } != nil)
    #expect(await Self.failure { try await session.closeCursor(cursor) } != nil)
  }

  // MARK: - Commands and results

  @Test("Write tags and affected rows; AGGREGATE has no count for the manager")
  func commandTags() throws {
    let collection = "c"
    let document = MongoValue.document([.init("a", .int32(1))])
    let filter = MongoValue.document([])
    let cases: [(MongoCommand, MongoValue, String, Int, Int?)] = [
      (
        .insertOne(collection: collection, document: document), Self.reply(("n", .int32(1))),
        "INSERT 1", 1, nil
      ),
      (
        .insertMany(collection: collection, documents: [document, document]),
        Self.reply(("n", .int32(2))), "INSERT 2", 2, nil
      ),
      (
        .updateMany(
          collection: collection, filter: filter, update: .document([.init("$set", document)])),
        Self.reply(("n", .int32(3)), ("nModified", .int32(0))), "UPDATE 3", 3, 0
      ),
      // Matched and modified differ: the tag keeps the matched count.
      (
        .updateOne(
          collection: collection, filter: filter, update: .document([.init("$set", document)])),
        Self.reply(("n", .int32(4)), ("nModified", .int64(2))), "UPDATE 4", 4, 2
      ),
      (
        .replaceOne(collection: collection, filter: filter, replacement: document),
        Self.reply(("n", .int64(1)), ("nModified", .int32(1))), "UPDATE 1", 1, 1
      ),
      (
        .deleteMany(collection: collection, filter: filter), Self.reply(("n", .double(5))),
        "DELETE 5", 5, nil
      ),
      (
        .aggregate(collection: collection, pipeline: [.document([.init("$out", .string("x"))])]),
        Self.reply(), "AGGREGATE", 0, nil
      ),
    ]
    for (command, reply, tag, rows, modified) in cases {
      let result = try MongoSession.commandResult(for: command, reply: reply)
      #expect(result == CommandResult(affectedRows: rows, tag: tag, modifiedRows: modified))
    }
    let updated = CommandResult(affectedRows: 3, tag: "UPDATE 3")
    #expect(StatementRoute.commandAffectedRows(updated) == 3)
    #expect(
      StatementRoute.commandAffectedRows(CommandResult(affectedRows: 0, tag: "INSERT 0")) == 0)
    #expect(
      StatementRoute.commandAffectedRows(CommandResult(affectedRows: 0, tag: "AGGREGATE")) == nil)
  }

  @Test("Write errors (duplicate key included) and write concern errors throw")
  func writeErrorsThrow() throws {
    let insert = MongoCommand.insertMany(
      collection: "c", documents: [.document([]), .document([])])
    let duplicate = Self.reply(
      ("n", .int32(1)),
      (
        "writeErrors",
        .array([
          .document([
            .init("index", .int32(1)), .init("code", .int32(11000)),
            .init("errmsg", .string("E11000 duplicate key error collection: dblore_test.c")),
          ])
        ])
      ))
    #expect {
      try MongoSession.commandResult(for: insert, reply: duplicate)
    } throws: { error in
      guard let error = error as? MongoSessionError else { return false }
      return error.code == 11000 && error.message.hasPrefix("E11000 duplicate key")
        && error.message.hasSuffix("(1 written before the error)") && error.written == 1
    }
    let concern = Self.reply(
      ("n", .int32(1)),
      (
        "writeConcernError",
        .document([.init("code", .int32(64)), .init("errmsg", .string("waiting"))])
      ))
    #expect(throws: MongoSessionError.self) {
      try MongoSession.commandResult(for: insert, reply: concern)
    }
  }

  @Test("Read commands: a negative find limit is limit and batchSize abs(n), never singleBatch")
  func readCommandDocuments() throws {
    func keys(_ command: MongoCommand) -> [String] { MongoSession.readCommand(command).map(\.key) }
    let negative = MongoSession.readCommand(
      .find(collection: "c", filter: nil, projection: nil, sort: nil, skip: 2, limit: -5))
    // A find on a view runs as an aggregate, which refuses singleBatch (code 168).
    #expect(negative.map(\.key) == ["find", "skip", "limit", "batchSize"])
    #expect(negative.first { $0.key == "limit" }?.value == .int64(5))
    #expect(negative.first { $0.key == "batchSize" }?.value == .int64(5))
    let huge = MongoSession.readCommand(
      .find(collection: "c", filter: nil, projection: nil, sort: nil, skip: nil, limit: -50_000))
    #expect(huge.first { $0.key == "batchSize" }?.value == .int64(10_000))
    #expect(
      keys(.find(collection: "c", filter: nil, projection: nil, sort: nil, skip: nil, limit: 3))
        == ["find", "limit"])
    #expect(
      keys(.find(collection: "c", filter: nil, projection: nil, sort: nil, skip: nil, limit: 0))
        == ["find"])
    #expect(
      keys(.distinct(collection: "c", field: "f", filter: .document([]))) == [
        "distinct", "key", "query",
      ])
    #expect(
      MongoSession.writeCommand(
        .find(collection: "c", filter: nil, projection: nil, sort: nil, skip: nil, limit: nil))
        == nil)
  }

  @Test(
    "find, aggregate and count options: collation and hint on the command, never a second maxTimeMS"
  )
  func readOptionsDocuments() throws {
    let collation = Self.reply(("locale", .string("fr")))
    let find = MongoSession.readCommand(
      .find(
        collection: "c", filter: nil, projection: nil, sort: nil, skip: nil, limit: 3,
        options: .init(collation: collation, hint: .string("a_1"), maxTimeMS: 500)))
    // execute appends maxTimeMS to every command: a second one is a duplicate key.
    #expect(find.map(\.key) == ["find", "limit", "collation", "hint"])
    #expect(find.first { $0.key == "collation" }?.value == collation)
    #expect(find.first { $0.key == "hint" }?.value == .string("a_1"))
    let aggregate = MongoSession.readCommand(
      .aggregate(
        collection: "c", pipeline: [],
        options: .init(collation: collation, hint: .string("a_1"), maxTimeMS: 500)))
    #expect(aggregate.map(\.key) == ["aggregate", "pipeline", "cursor", "collation", "hint"])
    #expect(aggregate.first { $0.key == "collation" }?.value == collation)

    func stages(_ fields: [MongoValue.Field]) -> [String] {
      guard case .array(let pipeline)? = fields.first(where: { $0.key == "pipeline" })?.value
      else { return [] }
      return pipeline.compactMap { stage in
        guard case .document(let fields) = stage else { return nil }
        return fields.first?.key
      }
    }
    let filter = Self.reply(("a", .int32(1)))
    let count = MongoSession.countCommand(
      collection: "c", filter: filter,
      options: Self.reply(
        ("skip", .int32(3)), ("limit", .int64(10)), ("collation", collation),
        ("hint", .string("a_1")), ("maxTimeMS", .int32(500))))
    #expect(stages(count) == ["$match", "$skip", "$limit", "$group"])
    #expect(count.map(\.key) == ["aggregate", "pipeline", "cursor", "collation", "hint"])
    #expect(count.first { $0.key == "hint" }?.value == .string("a_1"))
    // The server refuses $limit: 0; a count limit of 0 means no limit.
    let zero = MongoSession.countCommand(
      collection: "c", filter: filter,
      options: Self.reply(("skip", .int32(0)), ("limit", .int32(0))))
    #expect(stages(zero) == ["$match", "$group"])
  }

  @Test("explain wraps the read command uncapped, the user maxTimeMS inside, none at the top")
  func explainCommandDocument() throws {
    let find = MongoCommand.find(
      collection: "c", filter: nil, projection: nil, sort: nil, skip: nil, limit: nil,
      options: .init(maxTimeMS: 500))
    let fields = try #require(MongoSession.explainCommand(find, verbosity: "executionStats"))
    #expect(fields.map(\.key) == ["explain", "verbosity"])
    #expect(fields[1].value == .string("executionStats"))
    guard case .document(let inner) = fields[0].value else {
      Issue.record("explain is not a document")
      return
    }
    #expect(inner.map(\.key) == ["find", "maxTimeMS"])
    #expect(inner.last?.value == .int64(500))
    let pipeline = [Self.reply(("$match", Self.reply(("a", .int32(1)))))]
    let aggregate = MongoCommand.aggregate(collection: "c", pipeline: pipeline)
    #expect(
      MongoSession.explainCommand(aggregate, verbosity: "queryPlanner")?.first?.value
        == .document(MongoSession.readCommand(aggregate)))
    let timed = MongoCommand.aggregate(
      collection: "c", pipeline: pipeline, options: .init(maxTimeMS: 500))
    guard
      case .document(let timedInner)? = MongoSession.explainCommand(
        timed, verbosity: "queryPlanner")?.first?.value
    else {
      Issue.record("explain is not a document")
      return
    }
    #expect(timedInner.map(\.key) == ["aggregate", "pipeline", "cursor", "maxTimeMS"])
    #expect(timedInner.last?.value == .int64(500))
    #expect(MongoSession.explainCommand(.listCollections, verbosity: "queryPlanner") == nil)
  }

  @Test("Result shapes of countDocuments, distinct and listCollections")
  func resultShapes() {
    let count = MongoSession.countResult([Self.reply(("_id", .int32(1)), ("n", .int32(7)))])
    #expect(count.0.map(\.name) == ["count"])
    #expect(count.1 == [[.int(7)]])
    #expect(MongoSession.countResult([]).1 == [[.int(0)]])

    let distinct = MongoSession.distinctResult(
      field: "city", values: [.string("Oslo"), .string("Rome")])
    #expect(distinct.0.map(\.name) == ["city"])
    #expect(distinct.0.map(\.type) == ["string"])
    #expect(distinct.1 == [[.string("Oslo")], [.string("Rome")]])
    let mixed = MongoSession.distinctResult(field: "v", values: [.int32(1), .string("a")])
    #expect(mixed.0.map(\.type) == ["mixed"])
    #expect(MongoSession.distinctResult(field: "v", values: []).0.map(\.name) == ["v"])

    let collections = MongoSession.collectionsResult([
      Self.reply(("name", .string("zeta")), ("type", .string("collection"))),
      Self.reply(("name", .string("alpha")), ("type", .string("view"))),
    ])
    #expect(collections.0.map(\.name) == ["name", "type"])
    #expect(
      collections.1 == [
        [.string("alpha"), .string("view")], [.string("zeta"), .string("collection")],
      ])
  }

  // MARK: - Errors

  @Test("Server text is one line capped at 2,000 characters; known codes get clear text")
  func errorFormatting() throws {
    func text(_ error: any Error, tls: Bool = false) -> String {
      MongoSession.message(for: error, usesTLS: tls, statementTimeoutSeconds: 7)
    }
    let long = MongoSessionError(
      code: 2, codeName: "BadValue",
      message: "line one\nline two " + String(repeating: "x", count: 5000))
    #expect(long.message.count == MongoSessionError.maxMessageLength)
    #expect(long.message.hasSuffix("…"))
    #expect(!long.message.contains("\n"))
    #expect(text(long).count <= MongoSessionError.maxMessageLength)
    #expect(text(long).hasPrefix("ERROR 2 (BadValue): line one line two"))

    #expect(
      text(MongoSessionError(code: 18, message: "Authentication failed.")).contains("authSource"))
    #expect(
      text(MongoSessionError(code: 50, codeName: "MaxTimeMSExpired", message: "time limit"))
        .hasPrefix("Statement timed out after 7s"))
    #expect(
      text(MongoSessionError(code: 13, codeName: "Unauthorized", message: "not authorized"))
        .hasPrefix("Not authorized for this action: not authorized"))
    #expect(
      text(MongoSessionError(code: 166, codeName: "CommandNotSupportedOnView", message: "view"))
        .hasPrefix("This is a view"))
    #expect(text(MongoError(.queryTimeout, reason: nil)).contains("client timeout"))
    #expect(text(ChannelError.ioOnClosedChannel, tls: true) == MongoSession.tlsHint)
    #expect(text(ChannelError.ioOnClosedChannel, tls: false) != MongoSession.tlsHint)
    #expect(text(DatabaseError.connectionFailed("x")) == "Connection failed: x")

    let reply: Document = [
      "ok": 0.0, "errmsg": "no such command: 'dbloreNoSuchCommand'", "code": Int32(59),
      "codeName": "CommandNotFound",
    ]
    let generic = try FastBSONDecoder().decode(MongoGenericErrorReply.self, from: reply)
    #expect(text(generic) == "ERROR 59 (CommandNotFound): no such command: 'dbloreNoSuchCommand'")
    #expect(MongoSessionError(reply: reply).code == 59)

    #expect(MongoSession.isInterruption(MongoSessionError(code: 11601, message: "interrupted")))
    #expect(!MongoSession.isInterruption(MongoSessionError(code: 50, message: "time")))
    // An unopened TLS session formats closed-channel errors as the TLS hint.
    let tlsSession = MongoSession(
      config: Self.config(uri: "mongodb://db.example.com/?tls=true", sslMode: .verifyFull))
    #expect(tlsSession.formatError(ChannelError.ioOnClosedChannel) == MongoSession.tlsHint)
  }

  @Test("buildInfo versions parse without their suffix; an unknown version enables every feature")
  func serverVersionFeatures() {
    #expect(MongoServerVersion("4.4.29-rc0") == MongoServerVersion(4, 4, 29))
    #expect(MongoServerVersion("8.0") == MongoServerVersion(8, 0, 0))
    #expect(MongoServerVersion("") == nil)
    #expect(MongoServerVersion("v8") == nil)
    let old = MongoServerFeatures(version: MongoServerVersion(4, 2, 25))
    #expect(!old.hiddenIndexes && !old.timeSeries && !old.clusteredCollections)
    let mid = MongoServerFeatures(version: MongoServerVersion(5, 2, 1))
    #expect(mid.hiddenIndexes && mid.timeSeries && !mid.clusteredCollections)
    #expect(MongoServerFeatures(version: MongoServerVersion(5, 3)).clusteredCollections)
    let unknown = MongoServerFeatures(version: nil)
    #expect(unknown.hiddenIndexes && unknown.timeSeries && unknown.clusteredCollections)
  }

  // MARK: - Live server

  /// An open session on the plain fixture (or `uri`).
  static func openSession(uri: String = plainURI) async throws -> MongoSession {
    let session = MongoSession(config: config(uri: uri))
    do {
      try await session.open()
      try await session.applySessionSettings(
        statementTimeoutSeconds: 30, lockTimeoutSeconds: 5, idleTimeoutSeconds: 600)
    } catch {
      await session.close()
      throw error
    }
    return session
  }

  struct Rows {
    var columns: [String]
    var types: [String]
    var rows: [[CellValue]]
  }

  static func read(_ session: MongoSession, _ text: String) async throws -> Rows {
    let source = try await session.query(text, binds: [])
    var rows: [[CellValue]] = []
    for try await row in source.rows { rows.append(row) }
    return Rows(columns: source.columns.map(\.name), types: source.columns.map(\.type), rows: rows)
  }

  static func drop(_ collection: String) async {
    _ = try? await MongoSpike.withDatabase { db in try await db[collection].drop() }
  }

  /// Runs `body` with an open session and an empty collection, then drops it and closes.
  static func withCollection(
    _ name: String, uri: String = plainURI, _ body: (MongoSession) async throws -> Void
  ) async throws {
    await drop(name)
    let session = try await openSession(uri: uri)
    do {
      try await body(session)
    } catch {
      await session.close()
      await drop(name)
      throw error
    }
    await session.close()
    await drop(name)
  }

  @Test(
    "testConnection through the manager: success, and a wrong password fails clearly",
    .requiresMongo)
  func probeThroughManager() async throws {
    let manager = DatabaseConnectionManager()
    #expect(try await manager.testConnection(config: Self.config()))
    let error = await Self.failure {
      _ = try await manager.testConnection(config: Self.config(password: "wrong-password"))
    }
    let message = try #require(Self.connectionFailure(error))
    #expect(message.hasPrefix("Authentication failed"))
    // The default authSource (the database) has no such user.
    let noAuthSource = await Self.failure {
      _ = try await manager.testConnection(
        config: Self.config(
          uri:
            "mongodb://\(TestMongoDatabase.host):\(TestMongoDatabase.port)/\(TestMongoDatabase.database)"
        ))
    }
    #expect(Self.connectionFailure(noAuthSource)?.hasPrefix("Authentication failed") == true)
  }

  @Test("The manager connects and reads through MongoSession", .requiresMongo)
  func managerConnects() async throws {
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: Self.config())
    let session = try #require(await manager.session as? MongoSession)
    let rows = try await Self.read(session, "show collections")
    #expect(rows.columns == ["name", "type"])
    await manager.disconnect()
  }

  @Test("find, aggregate, countDocuments, distinct and listCollections results", .requiresMongo)
  func reads() async throws {
    let name = "session_reads"
    try await Self.withCollection(name) { session in
      let inserted = try await session.command(
        """
        db.\(name).insertMany([
          {city: "Oslo", n: 1, tags: ["a"]},
          {_id: 2, n: NumberLong(2), city: "Rome", when: ISODate("2024-01-02T03:04:05.678Z")},
          {_id: 3, city: "Oslo", nested: {x: 1}}
        ])
        """, binds: [])
      #expect(inserted == CommandResult(affectedRows: 3, tag: "INSERT 3"))

      // A missing `n` sorts first, so the `_id: 3` document sets the order after `_id`.
      let all = try await Self.read(session, "db.\(name).find().sort({n: 1})")
      #expect(all.columns == ["_id", "city", "nested", "n", "tags", "when"])
      #expect(all.types[0] == "mixed")
      #expect(all.types[3] == "mixed")
      #expect(all.rows.count == 3)
      let rome = try #require(all.rows.first { $0[1] == .string("Rome") })
      #expect(rome[0] == .int(2))
      let when = try #require(all.columns.firstIndex(of: "when"))
      #expect(rome[when] == .date(Date(timeIntervalSince1970: 1_704_164_645.678)))

      let projected = try await Self.read(
        session, "db.\(name).find({city: \"Oslo\"}, {city: 1}).sort({_id: -1}).limit(1)")
      #expect(projected.columns == ["_id", "city"])
      #expect(projected.rows.count == 1)

      let empty = try await Self.read(session, "db.\(name).find({city: \"Paris\"})")
      #expect(empty.columns == ["_id"])
      #expect(empty.rows.isEmpty)

      let grouped = try await Self.read(
        session,
        "db.\(name).aggregate([{$group: {_id: \"$city\", total: {$sum: 1}}}, {$sort: {_id: 1}}])")
      #expect(grouped.columns == ["_id", "total"])
      #expect(grouped.rows == [[.string("Oslo"), .int(2)], [.string("Rome"), .int(1)]])

      let count = try await Self.read(session, "db.\(name).countDocuments({city: \"Oslo\"})")
      #expect(count.columns == ["count"])
      #expect(count.rows == [[.int(2)]])
      let none = try await Self.read(session, "db.\(name).countDocuments({city: \"Paris\"})")
      #expect(none.rows == [[.int(0)]])

      let cities = try await Self.read(session, "db.\(name).distinct(\"city\")")
      #expect(cities.columns == ["city"])
      #expect(cities.rows.count == 2)
      #expect(cities.rows.contains([.string("Oslo")]) && cities.rows.contains([.string("Rome")]))

      let collections = try await Self.read(session, "db.getCollectionNames()")
      #expect(collections.columns == ["name", "type"])
      #expect(collections.rows.contains([.string(name), .string("collection")]))
    }
  }

  @Test("Writes report counts; duplicate keys throw; $out runs as AGGREGATE", .requiresMongo)
  func writes() async throws {
    let name = "session_writes"
    let target = "session_writes_out"
    await Self.drop(target)
    try await Self.withCollection(name) { session in
      func run(_ text: String) async throws -> CommandResult {
        try await session.command(text, binds: [])
      }
      #expect(
        try await run("db.\(name).insertOne({_id: 1, g: 1})")
          == .init(affectedRows: 1, tag: "INSERT 1"))
      #expect(
        try await run("db.\(name).insertMany([{_id: 2, g: 1}, {_id: 3, g: 0}, {_id: 4, g: 0}])")
          == .init(affectedRows: 3, tag: "INSERT 3"))
      #expect(
        try await run("db.\(name).updateMany({g: 1}, {$set: {v: 1}})")
          == .init(affectedRows: 2, tag: "UPDATE 2"))
      // Matched, not modified: the same update again still counts 2.
      #expect(
        try await run("db.\(name).updateMany({g: 1}, {$set: {v: 1}})")
          == .init(affectedRows: 2, tag: "UPDATE 2"))
      #expect(
        try await run("db.\(name).updateOne({_id: 9}, {$set: {g: 5}}, {upsert: true})")
          == .init(affectedRows: 1, tag: "UPDATE 1"))
      #expect(
        try await run("db.\(name).replaceOne({_id: 3}, {g: 7})")
          == .init(affectedRows: 1, tag: "UPDATE 1"))
      #expect(
        try await run("db.\(name).aggregate([{$match: {g: 1}}, {$out: \"\(target)\"}])")
          == .init(affectedRows: 0, tag: "AGGREGATE"))
      let copied = try await Self.read(session, "db.\(target).countDocuments()")
      #expect(copied.rows == [[.int(2)]])
      #expect(
        try await run("db.\(name).deleteOne({g: 0})") == .init(affectedRows: 1, tag: "DELETE 1"))
      #expect(try await run("db.\(name).deleteMany({})") == .init(affectedRows: 4, tag: "DELETE 4"))

      _ = try await run("db.\(name).insertOne({_id: 1})")
      let duplicate = await Self.failure {
        _ = try await run("db.\(name).insertMany([{_id: 5}, {_id: 1}, {_id: 6}])")
      }
      let error = try #require(duplicate as? MongoSessionError)
      #expect(error.code == 11000)
      #expect(error.message.contains("(1 written before the error)"))
      #expect(session.formatError(error).hasPrefix("ERROR 11000"))
    }
    await Self.drop(target)
  }

  @Test("The statement timeout is sent as maxTimeMS", .requiresMongo)
  func maxTimeMS() async throws {
    let name = "session_timeout"
    try await Self.withCollection(name) { session in
      _ = try await session.command("db.\(name).insertOne({_id: 1})", binds: [])
      try await session.applySessionSettings(
        statementTimeoutSeconds: 1, lockTimeoutSeconds: 5, idleTimeoutSeconds: 600)
      #expect(session.maxTimeMS == 1000)
      let start = Date()
      let error = await Self.failure {
        _ = try await Self.read(session, "db.\(name).find({$where: \"sleep(5000) || true\"})")
      }
      #expect(-start.timeIntervalSinceNow < 4)
      #expect((error as? MongoSessionError)?.code == 50)
      #expect(session.formatError(try #require(error)).hasPrefix("Statement timed out after 1s"))
    }
  }

  @Test("interrupt() kills the running find by its comment and keeps the session", .requiresMongo)
  func interruptKeepsSession() async throws {
    let name = "session_cancel"
    try await Self.withCollection(name) { session in
      _ = try await session.command("db.\(name).insertOne({_id: 1})", binds: [])
      let start = Date()
      let slow = Task {
        try await Self.read(session, "db.\(name).find({$where: \"sleep(10000) || true\"})")
      }
      try await Task.sleep(for: .milliseconds(300))
      await session.interrupt()
      let error = await Self.failure { _ = try await slow.value }
      let elapsed = -start.timeIntervalSinceNow
      #expect(elapsed < 5)
      guard case DatabaseError.queryCancelled(let pending, let rolledBack, let kept)? = error else {
        Issue.record("expected queryCancelled, got \(String(describing: error))")
        return
      }
      #expect(pending == 0 && !rolledBack && kept)
      let after = try await Self.read(session, "db.\(name).countDocuments()")
      #expect(after.rows == [[.int(1)]])
      // Nothing running: interrupt is a no-op.
      await session.interrupt()
    }
  }

  @Test("A read stopped at the document cap closes its server cursor", .requiresMongo)
  func cursorClosedAtCap() async throws {
    let name = "session_cursor"
    try await Self.withCollection(name) { session in
      let documents = (0..<600).map { "{_id: \($0)}" }.joined(separator: ", ")
      _ = try await session.command("db.\(name).insertMany([\(documents)])", binds: [])
      let baseline = try await MongoSpike.withDatabase { try await MongoSpike.openCursors($0) }

      session.documentCap = 250
      let capped = try await Self.read(session, "db.\(name).find().sort({_id: 1})")
      #expect(capped.rows.count == 250)
      #expect(capped.rows.last == [.int(249)])
      let afterCap = try await MongoSpike.withDatabase { try await MongoSpike.openCursors($0) }
      #expect(afterCap == baseline)

      session.documentCap = MongoSession.maxBufferedDocuments
      let all = try await Self.read(session, "db.\(name).find()")
      #expect(all.rows.count == 600)
      let aggregated = try await Self.read(session, "db.\(name).aggregate([{$match: {}}])")
      #expect(aggregated.rows.count == 600)
      let afterDrain = try await MongoSpike.withDatabase { try await MongoSpike.openCursors($0) }
      #expect(afterDrain == baseline)
    }
  }

  @Test(
    "A negative find limit works on a view and a collection; no cursor stays open", .requiresMongo)
  func negativeLimitOnView() async throws {
    let name = "session_negative_limit"
    let view = "session_negative_limit_view"
    await Self.drop(view)
    try await Self.withCollection(name) { session in
      do {
        let documents = (0..<5).map { "{_id: \($0)}" }.joined(separator: ", ")
        _ = try await session.command("db.\(name).insertMany([\(documents)])", binds: [])
        let created = try await MongoSpike.withDatabase { db in
          try await MongoSpike.command(
            db, ["create": view, "viewOn": name, "pipeline": [] as Document])
        }
        #expect(MongoSession.int(created["ok"]) == 1)
        let baseline = try await MongoSpike.withDatabase { try await MongoSpike.openCursors($0) }

        let fromView = try await Self.read(session, "db.\(view).find().sort({_id: 1}).limit(-2)")
        #expect(fromView.rows == [[.int(0)], [.int(1)]])
        let fromCollection = try await Self.read(session, "db.\(name).find().limit(-2)")
        #expect(fromCollection.rows.count == 2)
        let after = try await MongoSpike.withDatabase { try await MongoSpike.openCursors($0) }
        #expect(after == baseline)
      } catch {
        await Self.drop(view)
        throw error
      }
      await Self.drop(view)
    }
  }

  @Test("directConnection=true uses the single-connection pool", .requiresMongo)
  func directConnection() async throws {
    let name = "session_direct"
    try await Self.withCollection(name, uri: Self.plainURI + "&directConnection=true") { session in
      _ = try await session.command("db.\(name).insertOne({_id: 1, via: \"direct\"})", binds: [])
      let rows = try await Self.read(session, "db.\(name).find()")
      #expect(rows.rows == [[.int(1), .string("direct")]])
    }
  }

  @Test("closeEvents: connection loss on both pools, closedByApp on close", .requiresMongo)
  func closeEvents() async throws {
    for uri in [Self.plainURI, Self.plainURI + "&directConnection=true"] {
      let session = try await Self.openSession(uri: uri)
      let connection = try await session.nextConnection()
      await connection.close()
      var reasons: [SessionCloseReason] = []
      for await reason in session.closeEvents { reasons.append(reason) }
      #expect(reasons == [.connectionLost], "\(uri)")
      await session.close()
    }
    let session = try await Self.openSession()
    await session.close()
    var reasons: [SessionCloseReason] = []
    for await reason in session.closeEvents { reasons.append(reason) }
    #expect(reasons == [.closedByApp])
  }

  // MARK: - TLS

  static let tlsURI =
    "mongodb://localhost:\(TestMongoDatabase.tlsPort)/\(TestMongoDatabase.database)"
    + "?authSource=\(TestMongoDatabase.authSource)&tls=true"

  /// `body` with `caPEM` as the connection's custom CA (none when nil).
  static func withCA(
    _ caPEM: String?, uri: String = tlsURI, _ body: (ConnectionConfig) async throws -> Void
  ) async throws {
    var config = config(
      uri: uri, host: "localhost", port: TestMongoDatabase.tlsPort, sslMode: .verifyFull)
    guard let caPEM else { return try await body(config) }
    config.clientCertificate = ClientCertificateInfo(subject: nil, expiry: nil, hasCA: true)
    let scoped = ClientCertificateStoreFactory.ScopedMaterial(
      account: ClientCertificateStoreFactory.account(for: config),
      material: ClientCertificateMaterial(caPEM: caPEM))
    try await ClientCertificateStoreFactory.$operationMaterial.withValue(scoped) {
      try await body(config)
    }
  }

  @Test("TLS with the fixture CA connects (cluster and direct)", .requiresMongoTLS)
  func tlsWithCA() async throws {
    let caPEM = try String(contentsOf: TestMongoDatabase.caCertificate, encoding: .utf8)
    for uri in [Self.tlsURI, Self.tlsURI + "&directConnection=true"] {
      try await Self.withCA(caPEM, uri: uri) { config in
        let manager = DatabaseConnectionManager()
        #expect(try await manager.testConnection(config: config))
        let session = MongoSession(config: config)
        do {
          try await session.open()
          let rows = try await Self.read(session, "show collections")
          #expect(rows.columns == ["name", "type"])
        } catch {
          await session.close()
          throw error
        }
        await session.close()
      }
    }
  }

  @Test("TLS without the CA, or with another CA, fails with a TLS message", .requiresMongoTLS)
  func tlsWithoutCA() async throws {
    var cases: [String?] = [nil]
    let otherCA = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("docker/postgresql/data/mtls/ca.crt")
    if let pem = try? String(contentsOf: otherCA, encoding: .utf8) { cases.append(pem) }
    for caPEM in cases {
      for uri in [Self.tlsURI, Self.tlsURI + "&directConnection=true"] {
        try await Self.withCA(caPEM, uri: uri) { config in
          let error = await Self.failure {
            _ = try await DatabaseConnectionManager().testConnection(config: config)
          }
          let message = try #require(Self.connectionFailure(error), "\(uri)")
          #expect(message.contains("TLS"), "\(uri): \(message)")
        }
      }
    }
  }
}
