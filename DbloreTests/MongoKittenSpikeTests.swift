// MongoKittenSpikeTests.swift
// Phase 2.4 spike: what MongoKitten 7.16.3 / BSON 8.2.2 actually do against the docker fixtures
// (mongo:8.0 standalone on 27018, requireTLS copy on 27019, users in `admin`). Each test asserts
// the observed behavior and records the numbers behind it ("SPIKE ..." lines, also appended to
// $TMPDIR/dblore-mongo-spike.txt because xcodebuild drops test host stdout). Opt-in:
// TEST_RUNNER_MONGO_TESTS=1, plus TEST_RUNNER_MONGO_TLS_TESTS=1 for the TLS cases and
// TEST_RUNNER_MONGO_SRV_SPIKE=1 (with TEST_MONGO_SRV_URI) for the SRV lookup. Collections use
// `spike_` and are dropped at the end of each test. Plain imports on purpose: this target compiles
// MongoKitten and BSON under Swift 6 strict concurrency without @preconcurrency (Q2).

import BSON
import Darwin
import Foundation
import Logging
import MongoClient
import MongoKitten
import NIOCore
import NIOPosix
import NIOSSL
import Testing

@Suite(.serialized, .timeLimit(.minutes(10)))
struct MongoKittenSpikeTests {
  typealias Spike = MongoSpike

  // MARK: - Q2 Sendable story

  /// Compiles only if every listed type is Sendable (Swift 6, strict concurrency complete).
  @Test(
    "Q2 the MongoKitten and BSON types a session holds or passes across tasks are Sendable",
    .requiresMongo)
  func sendableTypes() async throws {
    func sendable<T: Sendable>(_: T.Type) -> String { String(describing: T.self) }
    let names = [
      sendable(Document.self), sendable(ObjectId.self), sendable(Binary.self),
      sendable(Decimal128.self), sendable(Timestamp.self), sendable(RegularExpression.self),
      sendable(MinKey.self), sendable(MaxKey.self), sendable(Null.self),
      sendable(JavaScriptCode.self), sendable(ConnectionSettings.self),
      sendable(MongoCluster.self), sendable(MongoDatabase.self), sendable(MongoCollection.self),
      sendable(MongoConnection.self), sendable(MongoSingleConnectionPool.self),
      sendable(MongoClientContext.self), sendable(MongoCursor.self),
      sendable(FindQueryBuilder.self), sendable(FinalizedCursor<FindQueryBuilder>.self),
      sendable(MongoCursorResponse.self), sendable(MongoServerReply.self),
      sendable(InsertReply.self), sendable(UpdateReply.self), sendable(DeleteReply.self),
      sendable(MongoWriteError.self), sendable(MongoAuthenticationError.self),
      sendable(MongoServerError.self), sendable(MongoGenericErrorReply.self),
    ]
    Spike.record("SPIKE Q2 Sendable: \(names.joined(separator: ", "))")
    // A live round-trip from a detached task: the database object crosses isolation domains.
    let ok = try await Spike.withDatabase { db in
      try await Task.detached { try await Spike.command(db, ["ping": 1]) }.value["ok"]
    }
    #expect(Spike.int(ok) == 1)
  }

  // MARK: - Q3 SCRAM

  @Test("Q3 SCRAM-SHA-256 and SCRAM-SHA-1 log in with authSource=admin", .requiresMongo)
  func scramLogins() async throws {
    let password = TestMongoDatabase.fixturePassword
    let cases: [(String, ConnectionSettings.Authentication)] = [
      ("sha256 explicit", .scramSha256(username: TestMongoDatabase.username, password: password)),
      ("sha256 auto", .auto(username: TestMongoDatabase.username, password: password)),
      ("sha1 explicit", .scramSha1(username: TestMongoDatabase.sha1Username, password: password)),
      ("sha1 auto", .auto(username: TestMongoDatabase.sha1Username, password: password)),
    ]
    for (label, auth) in cases {
      let status = try await Spike.withDatabase(Spike.settings(auth)) { db in
        try await Spike.adminCommand(db, ["connectionStatus": 1])
      }
      let users = Spike.value(status, "authInfo", "authenticatedUsers") as? Document
      let user = (users?.values.first as? Document)?["user"] as? String
      Spike.record("SPIKE Q3 \(label): authenticated as \(user ?? "nil")")
      #expect(Spike.int(status["ok"]) == 1)
      #expect(user != nil)
    }
    // The mechanism is really used: SHA-1 against the SHA-256-only user is refused.
    let refused = await Spike.error {
      try await Spike.withDatabase(
        Spike.settings(.scramSha1(username: TestMongoDatabase.username, password: password))
      ) { _ in }
    }
    Spike.record("SPIKE Q3 sha1 against a sha256-only user: \(Spike.describe(refused))")
    #expect(Spike.int((refused as? MongoServerError)?.document["code"]) == 334)
  }

  // MARK: - Q4 TLS

  @Test("Q4 TLS: the custom CA is injectable via tlsCAFile or sslCaCertificate", .requiresMongoTLS)
  func tlsCustomCA() async throws {
    let caPath = TestMongoDatabase.caCertificate.path
    let user = TestMongoDatabase.username
    let password = TestMongoDatabase.password
    let port = TestMongoDatabase.tlsPort

    // URI form: tls=true&tlsCAFile=<path> (ConnectionSettings.swift:293-295).
    let uri =
      "mongodb://\(user):\(password)@localhost:\(port)/\(TestMongoDatabase.database)"
      + "?authSource=admin&tls=true&tlsCAFile=\(caPath)"
    let viaURI = try await Spike.withDatabase(try ConnectionSettings(uri)) { db in
      try await Spike.command(db, ["ping": 1])
    }
    Spike.record("SPIKE Q4 tlsCAFile URI: ping ok=\(Spike.int(viaURI["ok"]) ?? -1)")
    #expect(Spike.int(viaURI["ok"]) == 1)

    // Settings form: an in-memory NIOSSLCertificate (no file path needed at connect time).
    var settings = Spike.settings(Spike.testAuth, host: "localhost", port: port)
    settings.useSSL = true
    settings.sslCaCertificate = try NIOSSLCertificate.fromPEMFile(caPath).first
    #expect(settings.sslCaCertificate != nil)
    let viaCert = try await Spike.withDatabase(settings) { db in
      try await Spike.command(db, ["ping": 1])
    }
    Spike.record("SPIKE Q4 sslCaCertificate: ping ok=\(Spike.int(viaCert["ok"]) ?? -1)")
    #expect(Spike.int(viaCert["ok"]) == 1)

    // Without the CA the system trust store rejects the fixture chain.
    var untrusted = Spike.settings(Spike.testAuth, host: "localhost", port: port)
    untrusted.useSSL = true
    let noCA = await Spike.error { try await Spike.withDatabase(untrusted) { _ in } }
    Spike.record("SPIKE Q4 no CA (system trust): \(Spike.describe(noCA))")
    #expect(noCA != nil)

    // verifySSLCertificates=false (URI sslVerify=false) is never read on macOS
    // (Connection.swift:205-216 only sets trustRoots), so it still fails.
    untrusted.verifySSLCertificates = false
    let noVerify = await Spike.error { try await Spike.withDatabase(untrusted) { _ in } }
    Spike.record("SPIKE Q4 no CA + verifySSLCertificates=false: \(Spike.describe(noVerify))")
    #expect(noVerify != nil)

    // An IP host goes straight into NIOSSL's serverHostname (SNI).
    var byIP = Spike.settings(Spike.testAuth, host: TestMongoDatabase.host, port: port)
    byIP.useSSL = true
    byIP.sslCaCertificatePath = caPath
    let ipError = await Spike.error { try await Spike.withDatabase(byIP) { _ in } }
    Spike.record("SPIKE Q4 host 127.0.0.1 with CA: \(Spike.describe(ipError))")
  }

  /// NIOSSL accepts a certificate whose IP SAN matches the channel's remote address whatever
  /// serverHostname says (IdentityVerification.swift:150-170), and the fixture certificate names
  /// IP:127.0.0.1. So the name check is exercised through a loopback forwarder on ::1 (an address
  /// the certificate does not carry), which is also the SSH-forwarder fallback shape.
  @Test("Q4 TLS hostname override through an injected channel", .requiresMongoTLS)
  func tlsHostnameOverride() async throws {
    var tls = TLSConfiguration.makeClientConfiguration()
    tls.trustRoots = .file(TestMongoDatabase.caCertificate.path)
    let sslContext = try NIOSSLContext(configuration: tls)

    // Direct to 127.0.0.1: the IP SAN matches, so even a wrong serverHostname passes.
    let direct = await Spike.tlsLoginError(
      sslContext, host: TestMongoDatabase.host, port: TestMongoDatabase.tlsPort,
      serverHostname: "mongo.invalid")
    Spike.record(
      "SPIKE Q4 injected TLS to 127.0.0.1, serverHostname=mongo.invalid: \(Spike.describe(direct))")

    try await Spike.withForwarder(toPort: TestMongoDatabase.tlsPort) { port in
      let right = await Spike.tlsLoginError(
        sslContext, host: "::1", port: port, serverHostname: "localhost")
      let wrong = await Spike.tlsLoginError(
        sslContext, host: "::1", port: port, serverHostname: "mongo.invalid")
      let none = await Spike.tlsLoginError(sslContext, host: "::1", port: port, serverHostname: nil)
      Spike.record(
        "SPIKE Q4 via [::1]:\(port) forwarder: serverHostname=localhost -> \(Spike.describe(right)); "
          + "mongo.invalid -> \(Spike.describe(wrong)); nil -> \(Spike.describe(none))")
      #expect(right == nil)
      #expect(wrong != nil)
      #expect(none != nil)
    }
  }

  // MARK: - Q5 SRV

  @Test(
    "Q5 SRV and TXT lookup through MongoKitten's DNSClient",
    .requiresMongo,
    .enabled(
      if: ["1", "true", "yes"].contains(
        (ProcessInfo.processInfo.environment["MONGO_SRV_SPIKE"]
          ?? ProcessInfo.processInfo.environment["TEST_RUNNER_MONGO_SRV_SPIKE"] ?? "").lowercased()),
      "Set TEST_RUNNER_MONGO_SRV_SPIKE=1 and TEST_MONGO_SRV_URI (mongodb+srv://...) to run"))
  func srvLookup() async throws {
    let uri = try #require(ProcessInfo.processInfo.environment["TEST_MONGO_SRV_URI"])
    let settings = try ConnectionSettings(uri)
    let cluster = try await MongoCluster(connectingTo: settings, eventLoopGroup: Spike.group)
    Spike.record("SPIKE Q5 SRV resolved hosts: \(cluster.settings.hosts)")
    #expect(!cluster.settings.hosts.isEmpty)
    await cluster.disconnect()
  }

  // MARK: - Q6 getMore and killCursors

  @Test("Q6 an early cursor stop releases the server cursor (1M documents)", .requiresMongo)
  func cursorEarlyStop() async throws {
    let name = "spike_cursor"
    try await Spike.withDatabase { db in
      let collection = db[name]
      try? await collection.drop()
      do {
        // insertMany of 20,000-document batches stalled (60,000 documents in 10 minutes): BSON's
        // Document.append(_:) names each array element String(self.count), and count walks the
        // whole buffer, so building the documents array (BSONEncoder or by hand) is O(n^2).
        // Time it per batch size against appendValue(_:forKey:) with the index as the key.
        let total = 1_000_000
        var next = 0
        func documents(_ count: Int) -> [Document] {
          defer { next += count }
          return (next..<next + count).map { ["_id": $0, "v": Int32($0 % 97)] }
        }
        for size in [1000, 2000, 4000] {
          let batch = documents(size)
          var clock = Date()
          _ = try BSONEncoder().encode(InsertCommand(documents: batch, inCollection: name))
          let encodeTime = -clock.timeIntervalSinceNow
          clock = Date()
          let reply = try await collection.insertMany(batch)
          let insertTime = -clock.timeIntervalSinceNow
          #expect(reply.insertCount == size)

          let appendBatch = documents(size)
          clock = Date()
          var appended = Document(isArray: true)
          for document in appendBatch { appended.append(document) }
          let appendTime = -clock.timeIntervalSinceNow
          let appendedReply = try await Spike.command(db, ["insert": name, "documents": appended])
          #expect(Spike.int(appendedReply["n"]) == size)

          let keyedBatch = documents(size)
          clock = Date()
          let keyed = try await Spike.insert(db, name, keyedBatch)
          let keyedTime = -clock.timeIntervalSinceNow
          #expect(keyed == size)
          Spike.record(
            "SPIKE Q6 insert \(size) docs: BSONEncoder(InsertCommand) \(Spike.seconds(encodeTime)), "
              + "insertMany \(Spike.seconds(insertTime)), Document.append x\(appended.count) "
              + "\(Spike.seconds(appendTime)), appendValue(forKey:) + insert command \(Spike.seconds(keyedTime))"
          )
          #expect(keyedTime < insertTime)
        }

        // Fill to 1M through the fast path, 10,000 documents per insert command.
        let fillStart = Date()
        var inserted = 0
        while next < total {
          inserted += try await Spike.insert(db, name, documents(min(10_000, total - next)))
        }
        let count = try await collection.count()
        Spike.record(
          "SPIKE Q6 collection holds \(count) docs (\(inserted) in batches of 10,000 in "
            + "\(Spike.seconds(-fillStart.timeIntervalSinceNow)))")
        #expect(count == total)

        // Idle cursors left on this namespace by an earlier interrupted run.
        _ = try await Spike.killIdleCursors(db, collection: name, sessionId: nil)
        let baseline = try await Spike.openCursors(db)

        // Raw path (what the app will use: find with comment + batchSize, then MongoCursor).
        let connection = try await db.pool.next(for: .basic)
        let reply = try await connection.execute(
          ["find": name, "batchSize": Int32(1000), "comment": "dblore:q6"],
          namespace: db.commandNamespace,
          // Without the lsid the server binds the cursor to no session and the getMore (sent
          // with connection.implicitSession by MongoCursor) fails with code 13 Unauthorized.
          sessionId: connection.implicitSessionId)
        try reply.assertOK()
        let response = try FastBSONDecoder().decode(
          MongoCursorResponse.self, from: try reply.getDocument())
        let cursor = MongoCursor(
          reply: response.cursor, in: MongoNamespace(to: name, inDatabase: db.name),
          connection: connection, session: connection.implicitSession, transaction: nil)
        var fetched = 0
        for _ in 0..<4 {
          fetched += try await cursor.getMore(batchSize: 1000).count
        }
        let openRaw = try await Spike.openCursors(db)
        try await cursor.close()
        let afterRaw = try await Spike.openCursors(db)
        Spike.record(
          "SPIKE Q6 raw: id=\(response.cursor.id) fetched=\(fetched) open baseline=\(baseline) "
            + "during=\(openRaw) after close()=\(afterRaw)")
        #expect(fetched == 4000)
        #expect(openRaw == baseline + 1)
        #expect(afterRaw == baseline)

        // Builder path: FindQueryBuilder.execute() + FinalizedCursor.close().
        let builder = collection.find()
        builder.command.batchSize = 1000
        let finalized = try await builder.execute()
        fetched = 0
        for _ in 0..<4 {
          fetched += try await finalized.nextBatch(batchSize: 1000).count
        }
        let openBuilder = try await Spike.openCursors(db)
        try await finalized.close()
        let afterBuilder = try await Spike.openCursors(db)
        Spike.record(
          "SPIKE Q6 builder: fetched=\(fetched) during=\(openBuilder) after close()=\(afterBuilder)"
        )
        #expect(openBuilder == baseline + 1)
        #expect(afterBuilder == baseline)

        // Pitfall: breaking out of `for try await` leaves the server cursor open (no killCursors
        // in the iterator or in MongoCursor.deinit).
        let leaking = collection.find()
        leaking.command.batchSize = 1000
        var seen = 0
        for try await _ in leaking {
          seen += 1
          if seen == 2500 { break }
        }
        let afterBreak = try await Spike.openCursors(db)
        Spike.record("SPIKE Q6 for-await + break after \(seen): open=\(afterBreak) (leak)")
        #expect(afterBreak == baseline + 1)

        // Pitfall: a raw find without lsid, then MongoCursor.getMore (which sends the implicit
        // session) is refused, and that cursor stays open too.
        let noSession = try await connection.execute(
          ["find": name, "batchSize": Int32(1000)], namespace: db.commandNamespace)
        let orphan = MongoCursor(
          reply: try FastBSONDecoder().decode(
            MongoCursorResponse.self, from: try noSession.getDocument()
          ).cursor,
          in: MongoNamespace(to: name, inDatabase: db.name), connection: connection,
          session: connection.implicitSession, transaction: nil)
        _ = try await orphan.getMore(batchSize: 1000)
        let mismatch = await Spike.error { _ = try await orphan.getMore(batchSize: 1000) }
        let afterMismatch = try await Spike.openCursors(db)
        Spike.record(
          "SPIKE Q6 find without lsid, getMore with implicit session: \(Spike.describe(mismatch)); "
            + "open=\(afterMismatch)")
        #expect(Spike.int((mismatch as? MongoServerError)?.document["code"]) == 13)
        #expect(afterMismatch == baseline + 2)

        // Dropping the collection does not close them (mongod 8.0 keeps idle cursors on a dropped
        // namespace until they time out), so find them with $currentOp and kill them by id.
        try await collection.drop()
        let afterDrop = try await Spike.openCursors(db)
        let withoutSession = try await Spike.killIdleCursors(db, collection: name, sessionId: nil)
        let afterPlainKill = try await Spike.openCursors(db)
        let withSession = try await Spike.killIdleCursors(
          db, collection: name, sessionId: connection.implicitSessionId)
        let afterSessionKill = try await Spike.openCursors(db)
        Spike.record(
          "SPIKE Q6 after drop: open=\(afterDrop); killCursors without lsid: \(withoutSession) "
            + "-> open=\(afterPlainKill); with the implicit lsid: \(withSession) -> open=\(afterSessionKill)"
        )
        #expect(afterDrop == baseline + 2)
        #expect(afterSessionKill == baseline)
      } catch {
        try? await collection.drop()
        throw error
      }
    }
  }

  // MARK: - Q7 killOp by comment

  @Test(
    "Q7 killOp by comment interrupts a $where sleep with 11601 and keeps the session",
    .requiresMongo)
  func killOpByComment() async throws {
    let name = "spike_killop"
    try await Spike.withDatabase { db in
      let collection = db[name]
      try? await collection.drop()
      do {
        try await collection.insert(["_id": 1])
        let token = "dblore:\(UUID().uuidString)"
        let start = Date()
        let slow = Task {
          try await Spike.command(
            db,
            [
              "find": name, "filter": ["$where": "sleep(10000) || true"] as Document,
              "comment": token,
            ])
        }

        // Control connection: its own cluster, as the app's interrupt path would.
        let killed: Document = try await Spike.withDatabase { control in
          var opid: Primitive?
          for _ in 0..<50 where opid == nil {
            try await Task.sleep(for: .milliseconds(100))
            let current = try await Spike.adminCommand(
              control, ["currentOp": 1, "$ownOps": true, "command.comment": token])
            let ops = current["inprog"] as? Document
            opid = (ops?.values.first as? Document)?["opid"]
          }
          let op = try #require(opid)
          Spike.record("SPIKE Q7 currentOp found opid=\(op) (\(type(of: op)))")
          return try await Spike.adminCommand(control, ["killOp": 1, "op": op])
        }
        #expect(Spike.int(killed["ok"]) == 1)

        let result = try await slow.value
        let elapsed = -start.timeIntervalSinceNow
        Spike.record(
          "SPIKE Q7 interrupted find after \(String(format: "%.2f", elapsed)) s: ok=\(result["ok"] ?? "nil") "
            + "code=\(result["code"] ?? "nil") codeName=\(result["codeName"] ?? "nil") "
            + "errmsg=\(result["errmsg"] ?? "nil")")
        #expect(Spike.int(result["ok"]) == 0)
        #expect(Spike.int(result["code"]) == 11601)
        #expect(elapsed < 9)

        // The same database object (same pooled connection) still works.
        let ping = try await Spike.command(db, ["ping": 1])
        let count = try await collection.count()
        Spike.record("SPIKE Q7 after kill: ping ok=\(Spike.int(ping["ok"]) ?? -1) count=\(count)")
        #expect(Spike.int(ping["ok"]) == 1)
        #expect(count == 1)
        try await collection.drop()
      } catch {
        try? await collection.drop()
        throw error
      }
    }
  }

  // MARK: - Q8 channel injection

  @Test("Q8 a caller-built NIO channel runs MongoKitten (public channel injection)", .requiresMongo)
  func channelInjection() async throws {
    // Direct: MongoConnection(channel:context:) + authenticate, used as the pool.
    let connection = try await Spike.injectedConnection(port: TestMongoDatabase.port)
    try await connection.authenticate(clientDetails: nil, using: Spike.testAuth, to: "admin")
    let db = connection[TestMongoDatabase.database]
    let name = "spike_inject"
    try? await db[name].drop()
    let inserted = try await db[name].insert(["_id": 1, "via": "injected channel"])
    let found = try await db[name].findOne(["_id": 1])
    try await db[name].drop()
    await connection.close()
    Spike.record(
      "SPIKE Q8 injected: insertCount=\(inserted.insertCount) found=\(found?["via"] ?? "nil")")
    #expect(inserted.insertCount == 1)
    #expect(found?["via"] as? String == "injected channel")

    // MongoSingleConnectionPool: rebuilds (and re-authenticates) after the channel closes.
    let builds = Spike.Counter()
    let pool = MongoSingleConnectionPool(authenticationSource: "admin", credentials: Spike.testAuth)
    {
      builds.increment()
      return try await Spike.injectedConnection(port: TestMongoDatabase.port)
    }
    let pooled = pool[TestMongoDatabase.database]
    let first = try await Spike.command(pooled, ["ping": 1])
    try await pool.next(for: .basic).close()
    let second = try await Spike.command(pooled, ["ping": 1])
    try await pool.next(for: .basic).close()
    Spike.record("SPIKE Q8 single pool: builds=\(builds.value) after one close")
    #expect(Spike.int(first["ok"]) == 1)
    #expect(Spike.int(second["ok"]) == 1)
    #expect(builds.value == 2)
  }

  // MARK: - Q9 direct connection

  @Test(
    "Q9 directConnection: URI option ignored, a MongoConnection pool does no discovery",
    .requiresMongo)
  func directConnection() async throws {
    let uri =
      "mongodb://\(TestMongoDatabase.username):\(TestMongoDatabase.password)@"
      + "\(TestMongoDatabase.host):\(TestMongoDatabase.port)/\(TestMongoDatabase.database)"
      + "?authSource=admin&directConnection=true"
    let settings = try ConnectionSettings(uri)
    Spike.record(
      "SPIKE Q9 directConnection kept as an unused query parameter: "
        + "\(settings.queryParameters["directConnection"] ?? "nil")")
    #expect(settings.queryParameters["directConnection"] == "true")

    let cluster = try await MongoCluster(connectingTo: settings, eventLoopGroup: Spike.group)
    let hello = try await Spike.adminCommand(
      cluster[settings.targetDatabase ?? "admin"], ["hello": 1])
    let state = cluster.connectionState
    await cluster.disconnect()
    Spike.record(
      "SPIKE Q9 cluster on standalone: state=\(state) setName=\(hello["setName"] ?? "nil") "
        + "hosts=\(hello["hosts"] ?? "nil")")
    #expect(hello["setName"] == nil)
    if case .connected(let count) = state {
      #expect(count == 1)
    } else {
      Issue.record("unexpected cluster state \(state)")
    }

    // A single MongoConnection is itself a MongoConnectionPool: no SDAM, no extra hosts.
    let connection = try await Spike.injectedConnection(port: TestMongoDatabase.port)
    try await connection.authenticate(clientDetails: nil, using: Spike.testAuth, to: "admin")
    let viaConnection = try await Spike.command(connection[TestMongoDatabase.database], ["ping": 1])
    await connection.close()
    #expect(Spike.int(viaConnection["ok"]) == 1)
  }

  // MARK: - Q10 event loop group lifecycle

  @Test(
    "Q10 a caller-owned event loop group shuts down cleanly; the default one leaks",
    .requiresMongo)
  func eventLoopGroupLifecycle() async throws {
    let before = Spike.nioThreadCount()

    // Default: MongoCluster creates MultiThreadedEventLoopGroup(1) and never shuts it down.
    let defaultCluster = try await MongoCluster(connectingTo: Spike.settings(Spike.testAuth))
    await defaultCluster.disconnect()
    let afterDefault = Spike.nioThreadCount()

    // Owned: pass the group, disconnect, then shut it down.
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let cluster = try await MongoCluster(
      connectingTo: Spike.settings(Spike.testAuth), eventLoopGroup: group)
    let ping = try await Spike.command(cluster[TestMongoDatabase.database], ["ping": 1])
    let during = Spike.nioThreadCount()
    await cluster.disconnect()
    let closed = cluster.connectionState
    try await group.shutdownGracefully()
    var afterOwned = Spike.nioThreadCount()
    for _ in 0..<20 where afterOwned != afterDefault {
      try await Task.sleep(for: .milliseconds(100))
      afterOwned = Spike.nioThreadCount()
    }
    Spike.record(
      "SPIKE Q10 NIO-ELT threads: before=\(before) after default connect+disconnect=\(afterDefault) "
        + "owned during=\(during) after shutdown=\(afterOwned); state after disconnect=\(closed)")
    #expect(Spike.int(ping["ok"]) == 1)
    #expect(afterDefault == before + 1)
    #expect(during == afterDefault + 1)
    #expect(afterOwned == afterDefault)
    if case .closed = closed {
    } else {
      Issue.record("state after disconnect: \(closed)")
    }
  }

  // MARK: - Q11 type fidelity

  @Test("Q11 every BSON type of Key decision d round-trips with its exact type", .requiresMongo)
  func typeFidelity() async throws {
    let name = "spike_types"
    try await Spike.withDatabase { db in
      let collection = db[name]
      try? await collection.drop()
      do {
        let oid = ObjectId()
        let date = Date(timeIntervalSince1970: 1_700_000_000.123)
        let bytes: [UInt8] = [0, 1, 2, 254, 255]
        let document: Document = [
          "_id": oid,
          "i32": Int32(42),
          "i64": 9_007_199_254_740_993,
          "dbl": 42.0,
          "bool": true,
          "date": date,
          "bin": Binary(subType: .generic, buffer: ByteBuffer(bytes: bytes)),
          "uuid": Binary(subType: .uuid, buffer: ByteBuffer(bytes: Array(0..<16))),
          "nested": ["a": Int32(1), "b": ["c": "deep"] as Document] as Document,
          "arr": [Int32(1), "two", 3.0, ["k": true] as Document] as Document,
          "null": Null(),
          "regex": RegularExpression(pattern: "^a.*z$", options: "i"),
          "ts": Timestamp(increment: 7, timestamp: 1_700_000_000),
          "min": MinKey(),
          "max": MaxKey(),
          "js": JavaScriptCode("function () { return 1; }"),
          "jsScope": JavaScriptCodeWithScope("function () { return x; }", scope: ["x": Int32(1)]),
          "str": "h\u{E9}llo \u{2713}",
        ]
        try await collection.insert(document)
        let back = try #require(try await collection.findOne(["_id": oid]))
        Spike.record("SPIKE Q11 read back: \(back.debugDescription)")

        #expect(back.typeIdentifier(forKey: "i32") == .int32)
        #expect(back["i32"] as? Int32 == 42)
        #expect(back.typeIdentifier(forKey: "i64") == .int64)
        #expect(back["i64"] as? Int == 9_007_199_254_740_993)
        #expect(back.typeIdentifier(forKey: "dbl") == .double)
        #expect(back["dbl"] as? Double == 42.0)
        #expect(back["dbl"] as? Int == nil)
        #expect(back["bool"] as? Bool == true)
        #expect(back.typeIdentifier(forKey: "date") == .datetime)
        let millis = (back["date"] as? Date).map {
          Int(($0.timeIntervalSince1970 * 1000).rounded())
        }
        #expect(millis == 1_700_000_000_123)
        let bin = back["bin"] as? Binary
        #expect(bin?.data == Data(bytes))
        if case .generic? = bin?.subType {
        } else {
          Issue.record("bin subtype \(String(describing: bin?.subType))")
        }
        let uuid = back["uuid"] as? Binary
        if case .uuid? = uuid?.subType {
        } else {
          Issue.record("uuid subtype \(String(describing: uuid?.subType))")
        }
        #expect(uuid?.data == Data(Array(0..<16)))
        #expect((back["_id"] as? ObjectId) == oid)
        #expect((back["_id"] as? ObjectId)?.hexString.count == 24)
        let nested = back["nested"] as? Document
        #expect(nested?.isArray == false)
        #expect(Spike.value(back, "nested", "b", "c") as? String == "deep")
        #expect(back.typeIdentifier(forKey: "nested") == .document)
        let array = back["arr"] as? Document
        #expect(back.typeIdentifier(forKey: "arr") == .array)
        #expect(array?.isArray == true)
        #expect(array?.typeIdentifier(at: 0) == .int32)
        #expect(array?.typeIdentifier(at: 2) == .double)
        #expect(array?.count == 4)
        #expect(back.typeIdentifier(forKey: "null") == .null)
        #expect(back.containsKey("null"))
        #expect(back["null"] is Null)
        #expect(!back.containsKey("missing"))
        #expect(back.typeIdentifier(forKey: "missing") == nil)
        #expect(back["missing"] == nil)
        let regex = back["regex"] as? RegularExpression
        #expect(regex?.pattern == "^a.*z$")
        #expect(regex?.options == "i")
        let ts = back["ts"] as? Timestamp
        #expect(ts?.increment == 7)
        #expect(ts?.timestamp == 1_700_000_000)
        #expect(back["min"] is MinKey)
        #expect(back["max"] is MaxKey)
        #expect(back.typeIdentifier(forKey: "min") == .minKey)
        #expect(back.typeIdentifier(forKey: "max") == .maxKey)
        #expect((back["js"] as? JavaScriptCode)?.code == "function () { return 1; }")
        #expect((back["jsScope"] as? JavaScriptCodeWithScope)?.scope["x"] as? Int32 == 1)
        #expect(back["str"] as? String == "h\u{E9}llo \u{2713}")

        // The server agrees on every stored type.
        let fields = [
          "i32", "i64", "dbl", "bool", "date", "bin", "uuid", "nested", "arr", "null", "regex",
          "ts", "min", "max", "js", "jsScope", "str", "missing",
        ]
        var projection: Document = ["_id": 0]
        for field in fields { projection[field] = ["$type": "$\(field)"] as Document }
        let pipeline: [Document] = [["$match": ["_id": oid] as Document], ["$project": projection]]
        let types = try #require(try await Spike.aggregate(db, name, pipeline).first)
        Spike.record("SPIKE Q11 server $type: \(types.debugDescription)")
        #expect(types["i32"] as? String == "int")
        #expect(types["i64"] as? String == "long")
        #expect(types["dbl"] as? String == "double")
        #expect(types["null"] as? String == "null")
        #expect(types["missing"] as? String == "missing")
        #expect(types["min"] as? String == "minKey")
        #expect(types["ts"] as? String == "timestamp")
        #expect(types["jsScope"] as? String == "javascriptWithScope")

        // Decimal128: built on the server, read as raw bits, formatted exactly.
        let texts = [
          "1234.5678", "-0.0001", "1.50", "0", "-0", "1E+10", "0.0000001",
          "1234567890123456789012345678901234", "9.999999999999999999999999999999999E+6144",
          "1E-6176", "Infinity", "-Infinity", "NaN",
        ]
        var setStage: Document = [:]
        for (index, text) in texts.enumerated() {
          setStage["d\(index)"] = ["$toDecimal": text] as Document
        }
        let update = try await Spike.command(
          db,
          [
            "update": name,
            "updates": [
              [
                "q": ["_id": "dec"] as Document, "u": [["$set": setStage] as Document] as Document,
                "upsert": true,
              ] as Document
            ] as Document,
          ])
        #expect(Spike.int(update["ok"]) == 1)
        let decimals = try #require(try await collection.findOne(["_id": "dec"]))
        var stringProjection: Document = ["_id": 0]
        for index in texts.indices {
          stringProjection["d\(index)"] = ["$toString": "$d\(index)"] as Document
        }
        let serverTexts = try #require(
          try await Spike.aggregate(
            db, name, [["$match": ["_id": "dec"] as Document], ["$project": stringProjection]]
          ).first)
        var roundTrip: Document = ["_id": "dec2"]
        for (index, text) in texts.enumerated() {
          let key = "d\(index)"
          #expect(decimals.typeIdentifier(forKey: key) == .decimal128)
          let value = try #require(decimals[key] as? Decimal128)
          let formatted = Spike.decimal128String(value)
          let server = serverTexts[key] as? String
          Spike.record(
            "SPIKE Q11 decimal \(text): bits->\(formatted) server $toString=\(server ?? "nil")")
          #expect(formatted == server)
          roundTrip[key] = value
        }
        // Writing the read value back keeps it exact.
        try await collection.insert(roundTrip)
        let echoed = try #require(
          try await Spike.aggregate(
            db, name, [["$match": ["_id": "dec2"] as Document], ["$project": stringProjection]]
          ).first)
        for index in texts.indices {
          #expect(echoed["d\(index)"] as? String == serverTexts["d\(index)"] as? String)
        }
        try await collection.drop()
      } catch {
        try? await collection.drop()
        throw error
      }
    }
  }

  // MARK: - Q12 error shapes

  @Test(
    "Q12 error shapes: auth failure, unknown command, duplicate key, maxTimeMS",
    .requiresMongo)
  func errorShapes() async throws {
    let badAuth = ConnectionSettings.Authentication.scramSha256(
      username: TestMongoDatabase.username, password: "wrong-password")
    let clusterAuth = await Spike.error {
      try await Spike.withDatabase(Spike.settings(badAuth)) { _ in }
    }
    Spike.record("SPIKE Q12 auth failure via MongoCluster: \(Spike.describe(clusterAuth))")
    #expect(Spike.int((clusterAuth as? MongoServerError)?.document["code"]) == 18)
    let directAuth = await Spike.error {
      let connection = try await Spike.injectedConnection(port: TestMongoDatabase.port)
      defer { Task { await connection.close() } }
      try await connection.authenticate(clientDetails: nil, using: badAuth, to: "admin")
    }
    Spike.record(
      "SPIKE Q12 auth failure via MongoConnection.authenticate: \(Spike.describe(directAuth))")
    #expect(Spike.int((directAuth as? MongoServerError)?.document["code"]) == 18)

    let name = "spike_errors"
    try await Spike.withDatabase { db in
      let collection = db[name]
      try? await collection.drop()
      do {
        // Unknown command: the raw reply has ok:0; assertOK() throws MongoGenericErrorReply.
        let connection = try await db.pool.next(for: .basic)
        let unknown = try await connection.execute(
          ["dbloreNoSuchCommand": 1], namespace: db.commandNamespace)
        let unknownDoc = try unknown.getDocument()
        Spike.record("SPIKE Q12 unknown command reply: \(unknownDoc.debugDescription)")
        #expect(Spike.int(unknownDoc["code"]) == 59)
        do {
          try unknown.assertOK()
          Issue.record("assertOK did not throw")
        } catch let error as MongoGenericErrorReply {
          Spike.record(
            "SPIKE Q12 unknown command as MongoGenericErrorReply: code=\(error.code ?? -1) "
              + "codeName=\(error.codeName ?? "nil") message=\(error.errorMessage ?? "nil")")
          #expect(error.code == 59)
          #expect(error.codeName == "CommandNotFound")
        }

        // Duplicate key: ok:1 with writeErrors; insert() does NOT throw.
        try await collection.insert(["_id": 1])
        let duplicate = try await collection.insert(["_id": 1])
        let writeError = duplicate.writeErrors?.first
        Spike.record(
          "SPIKE Q12 duplicate key: ok=\(duplicate.ok) n=\(duplicate.insertCount) "
            + "code=\(writeError?.code ?? -1) message=\(writeError?.message ?? "nil")")
        #expect(duplicate.ok == 1)
        #expect(duplicate.insertCount == 0)
        #expect(writeError?.code == 11000)

        // maxTimeMS: 50 on a slow find.
        try await collection.insertMany([["_id": 2], ["_id": 3]])
        let slowFind: Document = [
          "find": name, "filter": ["$where": "sleep(100) || true"] as Document,
          "maxTimeMS": Int32(50),
        ]
        let timedOut = try await Spike.command(db, slowFind)
        Spike.record("SPIKE Q12 maxTimeMS 50 reply: \(timedOut.debugDescription)")
        #expect(Spike.int(timedOut["code"]) == 50)
        #expect(timedOut["codeName"] as? String == "MaxTimeMSExpired")
        do {
          _ = try await connection.executeCodable(
            slowFind, decodeAs: MongoCursorResponse.self, namespace: db.commandNamespace,
            sessionId: nil)
          Issue.record("executeCodable did not throw")
        } catch let error as MongoServerError {
          // executeCodable (Connection+Execute.swift:42-53) rethrows its own decoded
          // MongoGenericErrorReply from inside a do/catch, so callers always get MongoServerError.
          Spike.record(
            "SPIKE Q12 maxTimeMS via executeCodable: MongoServerError document=\(error.document.debugDescription)"
          )
          #expect(Spike.int(error.document["code"]) == 50)
        }
        try await collection.drop()
      } catch {
        try? await collection.drop()
        throw error
      }
    }
  }

  /// MongoConnection.queryTimeout (30 s, Connection.swift:54) is a hard client-side cap on every
  /// command, and withQueryTimeout(_:) never reaches executeMessage. An actor extension can set it.
  @Test(
    "Q12 the client-side query timeout fails with MongoError.queryTimeout and is settable",
    .requiresMongo)
  func clientQueryTimeout() async throws {
    let name = "spike_timeout"
    let connection = try await Spike.injectedConnection(port: TestMongoDatabase.port)
    try await connection.authenticate(clientDetails: nil, using: Spike.testAuth, to: "admin")
    let db = connection[TestMongoDatabase.database]
    try? await db[name].drop()
    try await db[name].insert(["_id": 1])
    let defaultTimeout = await connection.queryTimeout
    await connection.spikeSetQueryTimeout(.seconds(1))
    let token = "dblore:\(UUID().uuidString)"
    let start = Date()
    let error = await Spike.error {
      _ = try await Spike.command(
        db,
        ["find": name, "filter": ["$where": "sleep(3000) || true"] as Document, "comment": token])
    }
    let elapsed = -start.timeIntervalSinceNow
    Spike.record(
      "SPIKE Q12 default queryTimeout=\(String(describing: defaultTimeout)); with 1 s: "
        + "\(Spike.describe(error)) after \(String(format: "%.2f", elapsed)) s")
    #expect((error as? MongoError)?.kind == .queryTimeout)
    #expect(elapsed < 2.5)
    await connection.spikeSetQueryTimeout(defaultTimeout)
    try await Task.sleep(for: .seconds(3))
    // The late reply is dropped; the connection still answers.
    let ping = try await Spike.command(db, ["ping": 1])
    #expect(Spike.int(ping["ok"]) == 1)
    try await db[name].drop()
    await connection.close()
  }

  // MARK: - Q13 write counts

  @Test("Q13 insertMany, updateMany matched/modified, deleteMany and upsert ids", .requiresMongo)
  func writeCounts() async throws {
    let name = "spike_writes"
    try await Spike.withDatabase { db in
      let collection = db[name]
      try? await collection.drop()
      do {
        let inserted = try await collection.insertMany(
          (0..<5).map { ["_id": $0, "g": $0 % 2, "v": 0] as Document })
        #expect(inserted.insertCount == 5)

        let updated = try await collection.updateMany(
          where: ["g": 1], setting: ["v": 1], unsetting: nil)
        let unchanged = try await collection.updateMany(
          where: ["g": 1], setting: ["v": 1], unsetting: nil)
        #expect(updated.updatableCount == 2)
        #expect(updated.updatedCount == 2)
        #expect(unchanged.updatableCount == 2)
        #expect(unchanged.updatedCount == 0)

        let deleted = try await collection.deleteAll(where: ["g": 0])
        #expect(deleted.deletes == 3)

        let upsertNew = try await collection.upsert(["v": 9], where: ["k": "new"])
        let upsertedId = upsertNew.upserted?.first?["_id"]
        let upsertOwnId = try await collection.upsert(["_id": "u1", "v": 1], where: ["_id": "u1"])
        let upsertExisting = try await collection.upsert(
          ["_id": "u1", "v": 2], where: ["_id": "u1"])
        #expect(upsertedId is ObjectId)
        #expect(upsertNew.updatableCount == 1)
        #expect(upsertNew.updatedCount == 0)
        #expect(upsertOwnId.upserted?.first?["_id"] as? String == "u1")
        #expect(upsertExisting.upserted == nil)
        #expect(upsertExisting.updatableCount == 1)
        #expect(upsertExisting.updatedCount == 1)

        // Raw command replies carry the same fields (n, nModified, upserted[{index,_id}]).
        let raw = try await Spike.command(
          db,
          [
            "update": name,
            "updates": [
              [
                "q": ["_id": "u2"] as Document, "u": ["$set": ["v": 3] as Document] as Document,
                "upsert": true,
              ] as Document
            ] as Document,
          ])
        let rawDelete = try await Spike.command(
          db,
          [
            "delete": name,
            "deletes": [["q": [:] as Document, "limit": 0] as Document] as Document,
          ])
        Spike.record(
          "SPIKE Q13 insertCount=\(inserted.insertCount) updateMany n=\(updated.updatableCount) "
            + "nModified=\(updated.updatedCount) (again: \(unchanged.updatableCount)/\(unchanged.updatedCount)) "
            + "deletes=\(deleted.deletes) upserted=\(upsertedId.map { "\($0)" } ?? "nil") "
            + "own=\(upsertOwnId.upserted?.debugDescription ?? "nil") raw update=\(raw.debugDescription) "
            + "raw delete=\(rawDelete.debugDescription)")
        #expect(Spike.int(raw["n"]) == 1)
        #expect(Spike.value(raw, "upserted") is Document)
        // ids 1 and 3, the generated upsert, u1 and u2.
        #expect(Spike.int(rawDelete["n"]) == 5)
        try await collection.drop()
      } catch {
        try? await collection.drop()
        throw error
      }
    }
  }
}

extension MongoConnection {
  /// queryTimeout has no public setter; an actor extension can still assign it.
  func spikeSetQueryTimeout(_ timeout: TimeAmount?) {
    queryTimeout = timeout
  }
}

nonisolated enum MongoSpike {
  static var group: any EventLoopGroup { MultiThreadedEventLoopGroup.singleton }

  static var testAuth: ConnectionSettings.Authentication {
    .scramSha256(username: TestMongoDatabase.username, password: TestMongoDatabase.password)
  }

  static func settings(
    _ authentication: ConnectionSettings.Authentication,
    host: String = TestMongoDatabase.host,
    port: Int = TestMongoDatabase.port
  ) -> ConnectionSettings {
    ConnectionSettings(
      authentication: authentication, authenticationSource: TestMongoDatabase.authSource,
      hosts: [ConnectionSettings.Host(hostname: host, port: port)],
      targetDatabase: TestMongoDatabase.database)
  }

  /// A MongoCluster on the shared singleton group, disconnected on every path.
  static func withDatabase<T: Sendable>(
    _ settings: ConnectionSettings = settings(testAuth),
    _ body: (MongoDatabase) async throws -> T
  ) async throws -> T {
    let cluster = try await MongoCluster(connectingTo: settings, eventLoopGroup: group)
    do {
      let result = try await body(cluster[settings.targetDatabase ?? TestMongoDatabase.database])
      await cluster.disconnect()
      return result
    } catch {
      await cluster.disconnect()
      throw error
    }
  }

  /// A caller-built channel (plain or TLS) handed to MongoConnection; not authenticated yet.
  static func injectedConnection(
    host: String = TestMongoDatabase.host, port: Int, tls: NIOSSLContext? = nil,
    serverHostname: String? = nil
  ) async throws -> MongoConnection {
    let context = MongoClientContext(logger: Logger(label: "dblore.spike.mongo"))
    let channel = try await ClientBootstrap(group: group)
      .channelInitializer { channel in
        guard let tls else { return MongoConnection.addHandlers(to: channel, context: context) }
        return channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandler(
            NIOSSLClientHandler(context: tls, serverHostname: serverHostname))
        }.flatMap { MongoConnection.addHandlers(to: channel, context: context) }
      }
      .connect(host: host, port: port)
      .get()
    return MongoConnection(channel: channel, context: context)
  }

  /// A TCP forwarder on [::1]:<ephemeral> to 127.0.0.1:<port>, closed after `body`.
  static func withForwarder<T: Sendable>(
    toPort port: Int, _ body: (Int) async throws -> T
  )
    async throws -> T
  {
    let server = try await ServerBootstrap(group: group)
      .childChannelOption(ChannelOptions.autoRead, value: false)
      .childChannelInitializer { inbound in
        ClientBootstrap(group: inbound.eventLoop)
          .connect(host: TestMongoDatabase.host, port: port)
          .flatMapThrowing { outbound in
            let (left, right) = Glue.pair()
            try inbound.pipeline.syncOperations.addHandler(left)
            try outbound.pipeline.syncOperations.addHandler(right)
          }
          .flatMap { inbound.setOption(ChannelOptions.autoRead, value: true) }
      }
      .bind(host: "::1", port: 0)
      .get()
    let localPort = server.localAddress?.port ?? 0
    do {
      let result = try await body(localPort)
      try await server.close()
      return result
    } catch {
      try? await server.close()
      throw error
    }
  }

  /// Copies bytes between two channels on the same event loop.
  final class Glue: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var partner: Glue?
    private var context: ChannelHandlerContext?

    static func pair() -> (Glue, Glue) {
      let left = Glue()
      let right = Glue()
      left.partner = right
      right.partner = left
      return (left, right)
    }

    func handlerAdded(context: ChannelHandlerContext) { self.context = context }

    func handlerRemoved(context: ChannelHandlerContext) {
      self.context = nil
      partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
      guard let partner, let target = partner.context else { return }
      target.write(partner.wrapOutboundOut(unwrapInboundIn(data)), promise: nil)
    }

    func channelReadComplete(context: ChannelHandlerContext) { partner?.context?.flush() }

    func channelInactive(context: ChannelHandlerContext) {
      partner?.context?.close(promise: nil)
      context.fireChannelInactive()
    }
  }

  /// An insert command whose documents array is keyed by index (O(n), unlike Document.append).
  static func insert(
    _ db: MongoDatabase, _ collection: String, _ documents: [Document]
  )
    async throws -> Int
  {
    var array = Document(isArray: true)
    for (index, document) in documents.enumerated() {
      array.appendValue(document, forKey: String(index))
    }
    let reply = try await command(db, ["insert": collection, "documents": array])
    return int(reply["n"]) ?? -1
  }

  static func seconds(_ interval: TimeInterval) -> String {
    String(format: "%.3f s", interval)
  }

  /// Connects through an injected TLS channel and logs in; nil when it worked.
  static func tlsLoginError(
    _ context: NIOSSLContext, host: String, port: Int, serverHostname: String?
  ) async -> (any Error)? {
    await error {
      let connection = try await injectedConnection(
        host: host, port: port, tls: context, serverHostname: serverHostname)
      do {
        try await connection.authenticate(clientDetails: nil, using: testAuth, to: "admin")
        _ = try await command(connection[TestMongoDatabase.database], ["ping": 1])
        await connection.close()
      } catch {
        await connection.close()
        throw error
      }
    }
  }

  static func command(_ db: MongoDatabase, _ command: Document) async throws -> Document {
    let connection = try await db.pool.next(for: .basic)
    return try await connection.execute(command, namespace: db.commandNamespace).getDocument()
  }

  static func adminCommand(_ db: MongoDatabase, _ command: Document) async throws -> Document {
    let connection = try await db.pool.next(for: .basic)
    return try await connection.execute(command, namespace: .administrativeCommand).getDocument()
  }

  static func aggregate(
    _ db: MongoDatabase, _ collection: String, _ pipeline: [Document]
  )
    async throws -> [Document]
  {
    let reply = try await command(
      db, ["aggregate": collection, "pipeline": pipeline, "cursor": [:] as Document])
    let batch = value(reply, "cursor", "firstBatch") as? Document
    return batch?.values.compactMap { $0 as? Document } ?? []
  }

  /// Kills the idle cursors $currentOp lists for one namespace; returns the killCursors reply.
  static func killIdleCursors(
    _ db: MongoDatabase, collection: String, sessionId: SessionIdentifier?
  ) async throws -> String {
    let pipeline: Document = [
      ["$currentOp": ["idleCursors": true] as Document] as Document,
      ["$match": ["type": "idleCursor", "ns": "\(db.name).\(collection)"] as Document] as Document,
    ]
    let reply = try await adminCommand(
      db, ["aggregate": 1, "pipeline": pipeline, "cursor": [:] as Document])
    let ops = (value(reply, "cursor", "firstBatch") as? Document)?.values ?? []
    var ids = Document(isArray: true)
    for op in ops {
      if let id = value(op as? Document ?? [:], "cursor", "cursorId") {
        ids.appendValue(id, forKey: String(ids.keys.count))
      }
    }
    guard !ids.keys.isEmpty else { return "none idle" }
    let connection = try await db.pool.next(for: .basic)
    let killed = try await connection.execute(
      ["killCursors": collection, "cursors": ids], namespace: db.commandNamespace,
      sessionId: sessionId
    ).getDocument()
    return "\(ids.keys.count) idle, reply \(killed.debugDescription)"
  }

  static func openCursors(_ db: MongoDatabase) async throws -> Int {
    let status = try await adminCommand(db, ["serverStatus": 1])
    return int(value(status, "metrics", "cursor", "open", "total")) ?? -1
  }

  static func value(_ document: Document, _ path: String...) -> Primitive? {
    var current: Primitive? = document
    for key in path { current = (current as? Document)?[key] }
    return current
  }

  static func int(_ value: Primitive?) -> Int? {
    switch value {
    case let value as Int32: Int(value)
    case let value as Int: value
    case let value as Double: Int(value)
    default: nil
    }
  }

  static func error(_ body: () async throws -> Void) async -> (any Error)? {
    do {
      try await body()
      return nil
    } catch {
      return error
    }
  }

  static func describe(_ error: (any Error)?) -> String {
    guard let error else { return "no error" }
    return "\(String(reflecting: type(of: error))): \(error)"
  }

  /// Threads of MultiThreadedEventLoopGroups created without a custom name prefix.
  static func nioThreadCount() -> Int {
    let task = mach_task_self_
    var threads: thread_act_array_t?
    var count: mach_msg_type_number_t = 0
    guard task_threads(task, &threads, &count) == KERN_SUCCESS, let threads else { return -1 }
    defer {
      for index in 0..<Int(count) { mach_port_deallocate(task, threads[index]) }
      vm_deallocate(
        task, vm_address_t(UInt(bitPattern: threads)),
        vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
    }
    var matches = 0
    for index in 0..<Int(count) {
      guard let thread = pthread_from_mach_thread_np(threads[index]) else { continue }
      var name = [CChar](repeating: 0, count: 128)
      pthread_getname_np(thread, &name, name.count)
      let bytes = name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
      if String(decoding: bytes, as: UTF8.self).hasPrefix("NIO-ELT-") { matches += 1 }
    }
    return matches
  }

  /// IEEE 754-2008 decimal128 (BID) to the canonical string of the Extended JSON spec, read from
  /// the 16 raw bytes (BSON 8 keeps them internal, so they come from a one-key document).
  static func decimal128String(_ value: Decimal128) -> String {
    var holder = Document()
    holder["v"] = value
    let bytes = Array(holder.makeData())
    // int32 length, type byte, "v\0", then 16 little-endian bytes: low word, high word.
    let low = bytes[7..<15].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    let high = bytes[15..<23].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    let sign = high >> 63 == 1 ? "-" : ""
    let combination = (high >> 58) & 0x1F
    if combination == 0x1F { return "NaN" }
    if combination == 0x1E { return sign + "Infinity" }

    let biased: UInt64
    var parts: [UInt32]
    if (high >> 61) & 0x3 == 0x3 {
      biased = (high >> 47) & 0x3FFF
      parts = [0, 0, 0, 0]  // Non-canonical: the coefficient is above 10^34 - 1, so 0.
    } else {
      biased = (high >> 49) & 0x3FFF
      let significandHigh = high & 0x1_FFFF_FFFF_FFFF
      parts = [
        UInt32(significandHigh >> 32), UInt32(significandHigh & 0xFFFF_FFFF),
        UInt32(low >> 32), UInt32(low & 0xFFFF_FFFF),
      ]
    }
    let exponent = Int(biased) - 6176

    // Base 10^9 chunks by long division of the 128-bit coefficient.
    var chunks: [UInt32] = []
    while parts.contains(where: { $0 != 0 }) {
      var remainder: UInt64 = 0
      for index in parts.indices {
        let current = remainder << 32 | UInt64(parts[index])
        parts[index] = UInt32(current / 1_000_000_000)
        remainder = current % 1_000_000_000
      }
      chunks.append(UInt32(remainder))
    }
    var digits = chunks.reversed().enumerated().map { index, chunk in
      index == 0
        ? String(chunk) : String(repeating: "0", count: 9 - String(chunk).count) + String(chunk)
    }.joined()
    if digits.isEmpty { digits = "0" }
    if digits.count > 34 { digits = "0" }

    let adjusted = exponent + digits.count - 1
    if exponent > 0 || adjusted < -6 {
      var text = String(digits.prefix(1))
      if digits.count > 1 { text += "." + digits.dropFirst() }
      return sign + text + "E" + (adjusted >= 0 ? "+" : "") + String(adjusted)
    }
    if exponent == 0 { return sign + digits }
    let point = digits.count + exponent
    if point > 0 {
      return sign + digits.prefix(point) + "." + digits.dropFirst(point)
    }
    return sign + "0." + String(repeating: "0", count: -point) + digits
  }

  final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
  }

  /// Prints and appends to $TMPDIR/dblore-mongo-spike.txt (xcodebuild drops test host stdout).
  static func record(_ line: String) {
    print(line)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "dblore-mongo-spike.txt")
    let data = Data((line + "\n").utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
      handle.seekToEndOfFile()
      handle.write(data)
      try? handle.close()
    } else {
      try? data.write(to: url)
    }
  }
}
