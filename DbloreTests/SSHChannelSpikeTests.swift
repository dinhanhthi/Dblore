// SSHChannelSpikeTests.swift
// Phase 2.5 spike: MySQL (mysql-nio fork `connect(over:)`) and MongoDB (MongoKitten channel
// injection) over SSH direct-tcpip channels of the app's `SSHTunnel`, against
// docker/postgresql/docker-compose.ssh.yml (bastion 127.0.0.1:2222, internal-only targets
// mysql-ssh:3306 and mongo-ssh:27017, certificates from the fixture CA data/ssh/ca.crt).
// Each test asserts the observed behavior and prints the evidence ("SPIKE ..." lines, also
// appended to $TMPDIR/dblore-ssh-spike.txt). Opt-in: TEST_RUNNER_SSH_TESTS=1.

import BSON
import Foundation
import Logging
import MongoClient
import MongoKitten
import MySQLNIO
import NIOCore
import NIOPosix
import NIOSSH
import NIOSSL
import Testing

@testable import Dblore

@Suite("SSH channel spike (MySQL, MongoDB)", .requiresSSHPostgres, .serialized)
struct SSHChannelSpikeTests {
  typealias Spike = SSHChannelSpike

  // MARK: - MySQL

  /// On a plain (auto-reading) `openDirectTCPIP` channel the greeting MySQL sends first races
  /// the async hop before `connect(over:)` installs its handlers. Recorded only: timing-bound.
  @Test(
    "MySQL probe: connect(over:) on a plain auto-read openDirectTCPIP channel",
    .timeLimit(.minutes(2)))
  func mysqlProbeAutoReadChannel() async throws {
    try await Spike.withTunnel { tunnel in
      var outcomes: [String] = []
      for _ in 1...10 {
        let channel = try await Spike.withTimeout {
          try await tunnel.openDirectTCPIP(targetHost: Spike.mysqlHost, targetPort: 3306)
        }
        let outcome = await bounded(.seconds(4)) {
          let connection = try await MySQLConnection.connect(
            over: channel, username: Spike.mysqlUser, database: Spike.mysqlDatabase,
            password: Spike.password, tlsConfiguration: nil, allowPublicKeyRetrieval: true,
            logger: Spike.logger
          ).get()
          try await connection.close().get()
        }
        try? await channel.close()
        outcomes.append("\(outcome)")
      }
      let succeeded = outcomes.filter { $0 == "returned" }.count
      Spike.record(
        "SPIKE 2.5 MySQL auto-read openDirectTCPIP + connect(over:) (no TLS): "
          + "succeeded=\(succeeded)/10 outcomes=\(outcomes)")
    }
  }

  @Test(
    "MySQL 1a: connect(over:) on a paused direct-tcpip channel logs in (no TLS)",
    .timeLimit(.minutes(2)))
  func mysqlPausedChannelLogin() async throws {
    try await Spike.withTunnel { tunnel in
      for _ in 1...5 {
        let connection = try await Spike.mysql(over: tunnel)
        let user = try await Spike.scalar(connection, "SELECT CURRENT_USER()")
        let cipher = try await Spike.status(connection, "Ssl_cipher")
        try await connection.close().get()
        #expect(user == "dblore_ssh@%")
        #expect(cipher == "")
      }
      Spike.record(
        "SPIKE 2.5 MySQL paused channel (autoRead off in the child initializer, connect(over:) "
          + "off-loop, then autoRead on + read()): 5/5 logins as dblore_ssh@%, Ssl_cipher empty")
      Spike.record(
        "SPIKE 2.5 MySQL TLS over the SSH child channel: NOT RUN in-process. mysql-nio "
          + "1.9.1-dblore.3 MySQLConnectionHandler.handleHandshake adds NIOSSLClientHandler at "
          + "position .first, before SSHChannelDataAdapter; its ClientHello ByteBuffer hits "
          + "SSHChildChannel.write0 (expects SSHChannelData): NIOAny.forceAs trap, test host crash")
    }
  }

  @Test(
    "MySQL 1: connect(over:) on a paused direct-tcpip channel logs in with verified TLS",
    .disabled(
      "mysql-nio 1.9.1-dblore.3 adds NIOSSLClientHandler at .first, before SSHChannelDataAdapter: NIOAny trap in SSHChildChannel.write0 (fork MySQLConnectionHandler.swift:143)"
    ),
    .timeLimit(.minutes(2)))
  func mysqlVerifiedTLS() async throws {
    try await Spike.withTunnel { tunnel in
      let tls = try Spike.verifiedTLS()
      let connection = try await Spike.mysql(over: tunnel, tls: tls)
      let cipher = try await Spike.status(connection, "Ssl_cipher")
      let version = try await Spike.status(connection, "Ssl_version")
      let user = try await Spike.scalar(connection, "SELECT CURRENT_USER()")
      Spike.record(
        "SPIKE 2.5 MySQL verified TLS (serverHostname=mysql-ssh, fullVerification, fixture CA): "
          + "user=\(user ?? "nil") cipher=\(cipher ?? "nil") version=\(version ?? "nil") "
          + "child remoteAddress=\(String(describing: connection.channel.remoteAddress))")
      #expect(user == "dblore_ssh@%")
      #expect(cipher?.isEmpty == false)
      try await connection.close().get()

      let wrong = await Spike.error {
        let connection = try await Spike.mysql(
          over: tunnel, tls: tls, serverHostname: "mysql-wrong")
        try await connection.close().get()
      }
      Spike.record("SPIKE 2.5 MySQL serverHostname=mysql-wrong: \(Spike.describe(wrong))")
      #expect(wrong != nil)
      #expect(!(wrong is Spike.TimeoutError))
    }
  }

  @Test(
    "MySQL 2: KILL QUERY over a second tunnel channel stops SELECT SLEEP(10)",
    .timeLimit(.minutes(2)))
  func mysqlKillQueryOverSecondChannel() async throws {
    try await Spike.withTunnel { tunnel in
      let first = try await Spike.mysql(over: tunnel)
      let control = try await Spike.mysql(over: tunnel)
      let id = try #require(try await Spike.scalar(first, "SELECT CONNECTION_ID()"))
      let start = ContinuousClock.now
      let sleeping = Task { try await Spike.scalar(first, "SELECT SLEEP(10)") }
      let running = await Spike.eventually {
        let info = try? await Spike.scalar(
          control, "SELECT INFO FROM information_schema.PROCESSLIST WHERE ID = \(id)")
        return info?.hasPrefix("SELECT SLEEP") == true
      }
      #expect(running)
      _ = try await control.simpleQuery("KILL QUERY \(id)").get()
      let slept = try await Spike.withTimeout(seconds: 8) { try await sleeping.value }
      let elapsed = start.duration(to: .now)
      let after = try await Spike.scalar(first, "SELECT 1")
      Spike.record(
        "SPIKE 2.5 MySQL KILL QUERY \(id) via second channel: SLEEP(10) returned \(slept ?? "nil") "
          + "after \(elapsed); first connection SELECT 1 -> \(after ?? "nil")")
      #expect(slept == "1")
      #expect(elapsed < .seconds(5))
      #expect(after == "1")
      try await first.close().get()
      try await control.close().get()
    }
  }

  @Test(
    "MySQL 3: closing connections, then the tunnel, leaves nothing open",
    .timeLimit(.minutes(2)))
  func mysqlCloseOrder() async throws {
    try await Spike.withTunnel { tunnel in
      let first = try await Spike.mysql(over: tunnel)
      let second = try await Spike.mysql(over: tunnel)
      let ids = [
        try await Spike.scalar(first, "SELECT CONNECTION_ID()"),
        try await Spike.scalar(second, "SELECT CONNECTION_ID()"),
      ].compactMap { $0 }
      try await Spike.withTimeout { try await first.close().get() }
      try await Spike.withTimeout { try await second.close().get() }
      try await Spike.withTimeout { try await first.channel.closeFuture.get() }
      try await Spike.withTimeout { try await second.channel.closeFuture.get() }

      // The server drops both sessions once sshd closes its side of each channel.
      let observer = try await Spike.mysql(over: tunnel)
      let gone = await Spike.eventually {
        let count = try? await Spike.scalar(
          observer,
          "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE ID IN (\(ids.joined(separator: ",")))"
        )
        return count == "0"
      }
      try await observer.close().get()
      let start = ContinuousClock.now
      try await Spike.withTimeout(seconds: 10) { await tunnel.close() }
      let closeTime = start.duration(to: .now)
      Spike.record(
        "SPIKE 2.5 MySQL close order connections->tunnel: server sessions \(ids) gone=\(gone), "
          + "tunnel.close() \(closeTime), parent active=\(tunnel.parentChannel.isActive)")
      #expect(ids.count == 2)
      #expect(gone)
      #expect(!first.channel.isActive && !second.channel.isActive && !observer.channel.isActive)
      #expect(!tunnel.parentChannel.isActive)
      #expect(tunnel.isClosed)
    }
  }

  // MARK: - MySQL through a loopback forwarder (pre-approved fallback)

  /// Each forwarded connection gets its own auto-reading `openDirectTCPIP` channel, glued once
  /// the async open returns. Recorded only: shows whether the greeting race survives here.
  @Test(
    "MySQL forwarder probe: greeting race with plain openDirectTCPIP channels",
    .timeLimit(.minutes(2)))
  func mysqlForwarderGreetingRace() async throws {
    try await Spike.withTunnel { tunnel in
      let forwarder = try await Spike.LoopbackForwarder.start(tunnel: tunnel, paused: false)
      var outcomes: [String] = []
      for _ in 1...10 {
        let outcome = await bounded(.seconds(4)) {
          let connection = try await forwarder.mysql(tls: try Spike.verifiedTLS())
          try await connection.close().get()
        }
        outcomes.append("\(outcome)")
      }
      try await forwarder.close()
      let succeeded = outcomes.filter { $0 == "returned" }.count
      Spike.record(
        "SPIKE 2.5 MySQL forwarder, auto-read openDirectTCPIP children, verified TLS: "
          + "succeeded=\(succeeded)/10 outcomes=\(outcomes)")
    }
  }

  @Test(
    "MySQL forwarder: verified TLS, wrong hostname, KILL QUERY, close order",
    .timeLimit(.minutes(2)))
  func mysqlForwarderVerifiedTLS() async throws {
    try await Spike.withTunnel { tunnel in
      let forwarder = try await Spike.LoopbackForwarder.start(tunnel: tunnel, paused: true)
      let tls = try Spike.verifiedTLS()

      // Verified TLS through 127.0.0.1:<port>, hostname checked against the DNS-only SAN.
      let first = try await forwarder.mysql(tls: tls)
      let cipher = try await Spike.status(first, "Ssl_cipher")
      let user = try await Spike.scalar(first, "SELECT CURRENT_USER()")
      Spike.record(
        "SPIKE 2.5 MySQL forwarder 127.0.0.1:\(forwarder.port) connect(to:) verified TLS "
          + "(serverHostname=mysql-ssh): user=\(user ?? "nil") cipher=\(cipher ?? "nil")")
      #expect(user == "dblore_ssh@%")
      #expect(cipher?.isEmpty == false)

      let wrong = await Spike.error {
        let connection = try await forwarder.mysql(tls: tls, serverHostname: "mysql-wrong")
        try await connection.close().get()
      }
      Spike.record("SPIKE 2.5 MySQL forwarder serverHostname=mysql-wrong: \(Spike.describe(wrong))")
      #expect(wrong != nil)
      #expect(!(wrong is Spike.TimeoutError))

      // KILL QUERY from a second connection through the same forwarder.
      let control = try await forwarder.mysql(tls: tls)
      let id = try #require(try await Spike.scalar(first, "SELECT CONNECTION_ID()"))
      let start = ContinuousClock.now
      let sleeping = Task { try await Spike.scalar(first, "SELECT SLEEP(10)") }
      let running = await Spike.eventually {
        let info = try? await Spike.scalar(
          control, "SELECT INFO FROM information_schema.PROCESSLIST WHERE ID = \(id)")
        return info?.hasPrefix("SELECT SLEEP") == true
      }
      #expect(running)
      _ = try await control.simpleQuery("KILL QUERY \(id)").get()
      let slept = try await Spike.withTimeout(seconds: 8) { try await sleeping.value }
      let elapsed = start.duration(to: .now)
      let after = try await Spike.scalar(first, "SELECT 1")
      Spike.record(
        "SPIKE 2.5 MySQL forwarder KILL QUERY \(id): SLEEP(10) returned \(slept ?? "nil") "
          + "after \(elapsed); first connection SELECT 1 -> \(after ?? "nil")")
      #expect(slept == "1")
      #expect(elapsed < .seconds(5))
      #expect(after == "1")

      // Close order: connections, then the listener and its children, then the tunnel.
      try await Spike.withTimeout { try await first.close().get() }
      try await Spike.withTimeout { try await control.close().get() }
      try await Spike.withTimeout(seconds: 10) { try await forwarder.close() }
      let closeStart = ContinuousClock.now
      try await Spike.withTimeout(seconds: 10) { await tunnel.close() }
      let closeTime = closeStart.duration(to: .now)
      let channels = forwarder.channels.all
      Spike.record(
        "SPIKE 2.5 MySQL forwarder close order connections->listener+children->tunnel: "
          + "\(channels.count) forwarded channels all inactive="
          + "\(channels.allSatisfy { !$0.isActive }), listener active=\(forwarder.listener.isActive), "
          + "tunnel.close() \(closeTime), parent active=\(tunnel.parentChannel.isActive)")
      #expect(!first.channel.isActive && !control.channel.isActive)
      #expect(!forwarder.listener.isActive)
      #expect(channels.count == 6)
      #expect(channels.allSatisfy { !$0.isActive })
      #expect(!tunnel.parentChannel.isActive)
    }
  }

  // MARK: - MongoDB

  @Test(
    "Mongo 4: MongoConnection injected on a direct-tcpip channel: ping, insert, findOne",
    .timeLimit(.minutes(2)))
  func mongoChannelInjection() async throws {
    try await Spike.withTunnel { tunnel in
      let connection = try await Spike.mongo(over: tunnel).connection
      try await connection.authenticate(clientDetails: nil, using: Spike.mongoAuth, to: "admin")
      let db = connection[Spike.mongoDatabase]
      let ping = try await Spike.command(db, ["ping": 1])
      let name = "spike_ssh_inject"
      try? await db[name].drop()
      let inserted = try await db[name].insert(["_id": 1, "via": "ssh direct-tcpip"])
      let found = try await db[name].findOne(["_id": 1])
      try await db[name].drop()
      await connection.close()
      Spike.record(
        "SPIKE 2.5 Mongo injected over SSH: ping ok=\(Spike.int(ping["ok"]) ?? -1) "
          + "insertCount=\(inserted.insertCount) found=\(found?["via"] ?? "nil")")
      #expect(Spike.int(ping["ok"]) == 1)
      #expect(inserted.insertCount == 1)
      #expect(found?["via"] as? String == "ssh direct-tcpip")
    }
  }

  @Test(
    "Mongo 5: TLS (NIOSSLClientHandler) over the direct-tcpip channel, hostname verified",
    .timeLimit(.minutes(2)))
  func mongoTLSOverChannel() async throws {
    try await Spike.withTunnel { tunnel in
      let tls = try NIOSSLContext(configuration: try Spike.verifiedTLS())
      let mongo = try await Spike.mongo(over: tunnel, tls: tls, serverHostname: Spike.mongoHost)
      let connection = mongo.connection
      try await connection.authenticate(clientDetails: nil, using: Spike.mongoAuth, to: "admin")
      let ping = try await Spike.command(connection[Spike.mongoDatabase], ["ping": 1])
      let version = try await mongo.channel.nioSSL_tlsVersion().get()
      let peer = try await mongo.channel.nioSSL_peerCertificate().get()
      await connection.close()
      Spike.record(
        "SPIKE 2.5 Mongo TLS over SSH (serverHostname=mongo-ssh, fullVerification, fixture CA): "
          + "ping ok=\(Spike.int(ping["ok"]) ?? -1) tls=\(String(describing: version)) "
          + "peer=\(peer.map { "\($0)" } ?? "nil")")
      #expect(Spike.int(ping["ok"]) == 1)
      #expect(version != nil)
      #expect(peer != nil)

      let recorder = Spike.ErrorRecorder()
      let wrong = await Spike.error {
        let connection = try await Spike.mongo(
          over: tunnel, tls: tls, serverHostname: "mongo-wrong", errors: recorder
        ).connection
        do {
          try await connection.authenticate(
            clientDetails: nil, using: Spike.mongoAuth, to: "admin")
          await connection.close()
        } catch {
          await connection.close()
          throw error
        }
      }
      // MongoKitten reports only the closed channel; the TLS cause is seen in the pipeline.
      let cause = recorder.first
      Spike.record(
        "SPIKE 2.5 Mongo TLS serverHostname=mongo-wrong: surfaced \(Spike.describe(wrong)); "
          + "pipeline error \(Spike.describe(cause))")
      #expect(wrong != nil)
      #expect(!(wrong is Spike.TimeoutError))
      #expect((cause as? NIOSSLExtraError) == .failedToValidateHostname)
    }
  }

  @Test(
    "Mongo 6: MongoSingleConnectionPool rebuilds over a fresh tunnel channel after a close",
    .timeLimit(.minutes(2)))
  func mongoSingleConnectionPool() async throws {
    try await Spike.withTunnel { tunnel in
      let channels = Spike.ChannelLog()
      let pool = MongoSingleConnectionPool(
        authenticationSource: "admin", credentials: Spike.mongoAuth
      ) {
        let built = try await Spike.mongo(over: tunnel)
        channels.append(built.channel)
        return built.connection
      }
      let db = pool[Spike.mongoDatabase]
      let first = try await Spike.command(db, ["ping": 1])
      try await pool.next(for: .basic).close()
      let second = try await Spike.command(db, ["ping": 1])
      try await pool.next(for: .basic).close()
      let built = channels.all
      Spike.record(
        "SPIKE 2.5 Mongo single pool over SSH: builds=\(built.count) distinct channels="
          + "\(Set(built.map { ObjectIdentifier($0) }).count) all closed=\(built.allSatisfy { !$0.isActive })"
      )
      #expect(Spike.int(first["ok"]) == 1)
      #expect(Spike.int(second["ok"]) == 1)
      #expect(built.count == 2)
      #expect(Set(built.map { ObjectIdentifier($0) }).count == 2)
    }
  }

  @Test(
    "Mongo 7: closing the connection, then the tunnel, leaves nothing open",
    .timeLimit(.minutes(2)))
  func mongoCloseOrder() async throws {
    try await Spike.withTunnel { tunnel in
      let tls = try NIOSSLContext(configuration: try Spike.verifiedTLS())
      let plain = try await Spike.mongo(over: tunnel)
      let secure = try await Spike.mongo(over: tunnel, tls: tls, serverHostname: Spike.mongoHost)
      for mongo in [plain, secure] {
        try await mongo.connection.authenticate(
          clientDetails: nil, using: Spike.mongoAuth, to: "admin")
      }
      try await Spike.withTimeout { await plain.connection.close() }
      try await Spike.withTimeout { await secure.connection.close() }
      try await Spike.withTimeout { try await plain.channel.closeFuture.get() }
      try await Spike.withTimeout { try await secure.channel.closeFuture.get() }
      let start = ContinuousClock.now
      try await Spike.withTimeout(seconds: 10) { await tunnel.close() }
      let closeTime = start.duration(to: .now)
      Spike.record(
        "SPIKE 2.5 Mongo close order connections->tunnel: tunnel.close() \(closeTime), "
          + "parent active=\(tunnel.parentChannel.isActive)")
      #expect(!plain.channel.isActive && !secure.channel.isActive)
      #expect(!tunnel.parentChannel.isActive)
      #expect(tunnel.isClosed)
    }
  }
}

nonisolated enum SSHChannelSpike {
  static let mysqlHost = "mysql-ssh"
  static let mysqlUser = "dblore_ssh"
  static let mysqlDatabase = "dblore_ssh"
  static let mongoHost = "mongo-ssh"
  static let mongoDatabase = "dblore_ssh"
  static let password = "dblore123"
  static let logger = Logger(label: "dblore.spike.ssh")

  static var mongoAuth: ConnectionSettings.Authentication {
    .scramSha256(username: "root", password: password)
  }

  static let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("docker/postgresql/data/ssh", isDirectory: true)

  // MARK: Tunnel

  /// Key auth as dblore on 127.0.0.1:2222, host key pinned to the fixture fingerprint.
  static func connectTunnel() async throws -> SSHTunnel {
    let expected = try String(
      contentsOf: fixtures.appendingPathComponent("host_fingerprint.txt"), encoding: .utf8
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    let key = try SSHPrivateKeyParser.parse(
      Data(contentsOf: fixtures.appendingPathComponent("id_ed25519")), passphrase: nil)
    return try await withTimeout {
      try await SSHTunnel.connect(
        host: "127.0.0.1", port: 2222, username: "dblore",
        authentication: .privateKey(key.privateKey),
        hostKeyValidator: { _, fingerprint in
          guard fingerprint == expected else { throw SSHTunnelError.hostKeyRejected }
        })
    }
  }

  /// Runs `body` with a fresh tunnel and closes the tunnel on every path (close is idempotent,
  /// so `body` may close it first).
  static func withTunnel(_ body: (SSHTunnel) async throws -> Void) async throws {
    let tunnel = try await connectTunnel()
    do {
      try await body(tunnel)
    } catch {
      await tunnel.close()
      throw error
    }
    try await withTimeout(seconds: 10) { await tunnel.close() }
  }

  /// `SSHTunnel.openDirectTCPIP` with `autoRead` off, set in the child initializer (after
  /// swift-nio-ssh copied the parent's autoRead and before activation). Data that arrives
  /// meanwhile stays buffered in the child channel until the first `read()`. The child is not
  /// registered in the tunnel's channel list; closing the tunnel's parent still tears it down.
  static func openPausedDirectTCPIP(
    _ tunnel: SSHTunnel, targetHost: String, targetPort: Int
  ) async throws -> any Channel {
    let parent = tunnel.parentChannel
    let originator = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
    return try await withTimeout {
      try await parent.eventLoop.flatSubmit { () -> EventLoopFuture<any Channel> in
        let promise = parent.eventLoop.makePromise(of: (any Channel).self)
        do {
          let ssh = try parent.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
          let directTCPIP = SSHChannelType.DirectTCPIP(
            targetHost: targetHost, targetPort: targetPort, originatorAddress: originator)
          ssh.createChannel(promise, channelType: .directTCPIP(directTCPIP)) { child, _ in
            child.eventLoop.makeCompletedFuture {
              guard let options = child.syncOptions else { throw ChannelError.operationUnsupported }
              try options.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
              try options.setOption(ChannelOptions.autoRead, value: false)
              try child.pipeline.syncOperations.addHandler(SSHChannelDataAdapter())
            }
          }
        } catch {
          promise.fail(error)
        }
        return promise.futureResult
      }.get()
    }
  }

  // MARK: MySQL

  static func verifiedTLS() throws -> TLSConfiguration {
    var configuration = TLSConfiguration.makeClientConfiguration()
    configuration.trustRoots = .certificates(
      try NIOSSLCertificate.fromPEMFile(fixtures.appendingPathComponent("ca.crt").path))
    configuration.certificateVerification = .fullVerification
    return configuration
  }

  /// Opens a paused channel, calls `connect(over:)` from off the loop (the fork submits the
  /// handler setup to the loop), then turns autoRead on and reads: the loop runs those in
  /// submission order, so the buffered greeting reaches the MySQL handlers.
  /// Without TLS, caching_sha2_password full auth needs the RSA key path
  /// (allowPublicKeyRetrieval) while the server cache is cold.
  static func mysql(
    over tunnel: SSHTunnel, tls: TLSConfiguration? = nil, serverHostname: String = mysqlHost
  ) async throws -> MySQLConnection {
    let channel = try await openPausedDirectTCPIP(
      tunnel, targetHost: mysqlHost, targetPort: 3306)
    do {
      let login = MySQLConnection.connect(
        over: channel, username: mysqlUser, database: mysqlDatabase, password: password,
        tlsConfiguration: tls, serverHostname: serverHostname,
        allowPublicKeyRetrieval: tls == nil, logger: logger)
      try await channel.setOption(ChannelOptions.autoRead, value: true).get()
      channel.read()
      return try await withTimeout { try await login.get() }
    } catch {
      try? await channel.close()
      throw error
    }
  }

  static func scalar(_ connection: MySQLConnection, _ sql: String) async throws -> String? {
    let rows = try await connection.simpleQuery(sql).get()
    guard var buffer = rows.first?.values.first ?? nil else { return nil }
    return buffer.readString(length: buffer.readableBytes)
  }

  static func status(_ connection: MySQLConnection, _ name: String) async throws -> String? {
    let rows = try await connection.simpleQuery("SHOW SESSION STATUS LIKE '\(name)'").get()
    guard let row = rows.first, row.values.count > 1, var buffer = row.values[1] else {
      return nil
    }
    return buffer.readString(length: buffer.readableBytes)
  }

  // MARK: Loopback forwarder

  /// A listener on 127.0.0.1:<ephemeral>. Each accepted TCP connection (auto-read off until
  /// glued) gets, once active, its own direct-tcpip channel to mysql-ssh:3306 and two `Pipe`s
  /// copying bytes both ways; either side closing closes the other. `paused` opens the SSH
  /// child with autoRead off (see `openPausedDirectTCPIP`) and turns it on only after the glue
  /// is in place. The open must wait for channelActive: inside the child initializer the
  /// accepted channel is not registered yet, so the greeting written to it would be dropped.
  final class LoopbackForwarder: @unchecked Sendable {
    let listener: any Channel
    let channels: ChannelLog
    var port: Int { listener.localAddress?.port ?? 0 }

    private init(listener: any Channel, channels: ChannelLog) {
      self.listener = listener
      self.channels = channels
    }

    static func start(tunnel: SSHTunnel, paused: Bool) async throws -> LoopbackForwarder {
      let channels = ChannelLog()
      let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .childChannelOption(ChannelOptions.autoRead, value: false)
        .childChannelInitializer { inbound in
          inbound.eventLoop.makeCompletedFuture {
            try inbound.pipeline.syncOperations.addHandler(
              Connector(tunnel: tunnel, paused: paused, channels: channels))
          }
        }
        .bind(host: "127.0.0.1", port: 0)
        .get()
      return LoopbackForwarder(listener: listener, channels: channels)
    }

    func mysql(
      tls: TLSConfiguration?, serverHostname: String = SSHChannelSpike.mysqlHost
    ) async throws -> MySQLConnection {
      let address = try SocketAddress(ipAddress: "127.0.0.1", port: port)
      return try await SSHChannelSpike.withTimeout {
        try await MySQLConnection.connect(
          to: address, username: SSHChannelSpike.mysqlUser,
          database: SSHChannelSpike.mysqlDatabase, password: SSHChannelSpike.password,
          tlsConfiguration: tls, serverHostname: serverHostname,
          allowPublicKeyRetrieval: tls == nil, logger: SSHChannelSpike.logger,
          on: MultiThreadedEventLoopGroup.singleton.next()
        ).get()
      }
    }

    /// Closes the listener, then every forwarded channel, and waits for all of them.
    func close() async throws {
      try? await listener.close()
      for channel in channels.all {
        channel.close(promise: nil)
        try? await channel.closeFuture.get()
      }
    }
  }

  /// Opens and glues the SSH side once the accepted TCP channel is active.
  final class Connector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let tunnel: SSHTunnel
    private let paused: Bool
    private let channels: ChannelLog

    init(tunnel: SSHTunnel, paused: Bool, channels: ChannelLog) {
      self.tunnel = tunnel
      self.paused = paused
      self.channels = channels
    }

    func channelActive(context: ChannelHandlerContext) {
      let inbound = context.channel
      let (tunnel, paused, channels) = (self.tunnel, self.paused, self.channels)
      channels.append(inbound)
      Task {
        do {
          let outbound =
            paused
            ? try await openPausedDirectTCPIP(tunnel, targetHost: mysqlHost, targetPort: 3306)
            : try await tunnel.openDirectTCPIP(targetHost: mysqlHost, targetPort: 3306)
          channels.append(outbound)
          try await outbound.pipeline.addHandler(Pipe(partner: inbound)).get()
          try await inbound.pipeline.addHandler(Pipe(partner: outbound)).get()
          if paused {
            try await outbound.setOption(ChannelOptions.autoRead, value: true).get()
            outbound.read()
          }
          try await inbound.setOption(ChannelOptions.autoRead, value: true).get()
        } catch {
          inbound.close(promise: nil)
        }
      }
      context.fireChannelActive()
    }
  }

  /// Copies inbound bytes to `partner` (thread-safe Channel API: the two sides may run on
  /// different event loops) and closes `partner` when this side goes inactive or fails.
  final class Pipe: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let partner: any Channel

    init(partner: any Channel) { self.partner = partner }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
      partner.writeAndFlush(unwrapInboundIn(data), promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
      partner.close(promise: nil)
      context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
      context.close(promise: nil)
    }
  }

  // MARK: MongoDB

  /// A MongoConnection on a plain `openDirectTCPIP` channel (Mongo speaks first, so the
  /// auto-reading channel loses nothing). With `tls`, NIOSSLClientHandler sits between the
  /// SSH data adapter and the Mongo handlers. Not authenticated yet.
  /// `MongoConnection.channel` is internal, so the channel is returned next to it.
  struct MongoOverSSH: Sendable {
    let connection: MongoConnection
    let channel: any Channel
  }

  static func mongo(
    over tunnel: SSHTunnel, tls: NIOSSLContext? = nil, serverHostname: String? = nil,
    errors: ErrorRecorder? = nil
  ) async throws -> MongoOverSSH {
    let channel = try await withTimeout {
      try await tunnel.openDirectTCPIP(targetHost: mongoHost, targetPort: 27017)
    }
    let context = MongoClientContext(logger: logger)
    do {
      try await channel.eventLoop.flatSubmit { () -> EventLoopFuture<Void> in
        if let tls {
          do {
            try channel.pipeline.syncOperations.addHandler(
              NIOSSLClientHandler(context: tls, serverHostname: serverHostname))
            if let errors { try channel.pipeline.syncOperations.addHandler(errors) }
          } catch {
            return channel.eventLoop.makeFailedFuture(error)
          }
        }
        return MongoConnection.addHandlers(to: channel, context: context)
      }.get()
    } catch {
      try? await channel.close()
      throw error
    }
    return MongoOverSSH(
      connection: MongoConnection(channel: channel, context: context), channel: channel)
  }

  static func command(_ db: MongoDatabase, _ command: Document) async throws -> Document {
    let connection = try await db.pool.next(for: .basic)
    return try await connection.execute(command, namespace: db.commandNamespace).getDocument()
  }

  static func int(_ value: Primitive?) -> Int? {
    switch value {
    case let value as Int32: Int(value)
    case let value as Int: value
    case let value as Double: Int(value)
    default: nil
    }
  }

  /// Records the first error passing through the pipeline and forwards every error.
  final class ErrorRecorder: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let lock = NSLock()
    private var stored: (any Error)?
    var first: (any Error)? { lock.withLock { stored } }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
      lock.withLock { if stored == nil { stored = error } }
      context.fireErrorCaught(error)
    }
  }

  final class ChannelLog: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [any Channel] = []
    var all: [any Channel] { lock.withLock { channels } }
    func append(_ channel: any Channel) { lock.withLock { channels.append(channel) } }
  }

  // MARK: Utilities

  struct TimeoutError: Error {}

  /// Fails instead of hanging xcodebuild; NIO futures ignore task cancellation, so this
  /// returns on timeout without waiting for `body`.
  static func withTimeout<T: Sendable>(
    seconds: Double = 15, _ body: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    let gate = ResumeOnce<T>()
    return try await withCheckedThrowingContinuation { continuation in
      gate.set(continuation)
      Task { gate.resume(with: await Result(catching: body)) }
      Task {
        try? await Task.sleep(for: .seconds(seconds))
        gate.resume(with: .failure(TimeoutError()))
      }
    }
  }

  final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?

    func set(_ continuation: CheckedContinuation<T, any Error>) {
      lock.withLock { self.continuation = continuation }
    }

    func resume(with result: Result<T, any Error>) {
      let pending = lock.withLock {
        defer { continuation = nil }
        return continuation
      }
      pending?.resume(with: result)
    }
  }

  /// The error `body` throws (bounded by `withTimeout`), or nil when it succeeds.
  static func error(_ body: @escaping @Sendable () async throws -> Void) async -> (any Error)? {
    do {
      try await withTimeout(body)
      return nil
    } catch {
      return error
    }
  }

  static func describe(_ error: (any Error)?) -> String {
    guard let error else { return "no error" }
    return "\(String(reflecting: type(of: error))): \(error)"
  }

  /// Polls `condition` every 100 ms for up to `seconds`.
  static func eventually(
    within seconds: Double = 5, _ condition: () async -> Bool
  ) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return await condition()
  }

  static func record(_ line: String) {
    print(line)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "dblore-ssh-spike.txt")
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
