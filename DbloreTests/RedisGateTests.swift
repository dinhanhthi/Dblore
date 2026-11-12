// RedisGateTests.swift
// `executeGatedRedisCommand` on fake sessions: every Redis command passes the lock, the
// connection epoch, the db range, the editor refusals, the protection policy and the destructive
// confirmation before anything is sent, and the bytes sent are the bytes classified. Also
// `RedisReply` rebuilt from the plugin's `[path, type, value]` rows, and a source scan that keeps
// `RedisCommandSending` reachable only through the gate.

import Foundation
import Testing

@testable import Dblore

@Suite("Redis command gate")
struct RedisGateTests {
  private let open = ProtectionPolicy(protectionLevel: .none)

  private static func command(_ words: String..., db: Int = 0) -> RedisCommand {
    RedisCommand(args: words.map { Data($0.utf8) }, db: db)
  }

  private func connect(
    level: ConnectionProtectionLevel = .none, lockSource: LockRegistry = LockRegistry()
  ) async throws -> (DatabaseConnectionManager, FakeDatabaseSessionFactory) {
    let factory = FakeDatabaseSessionFactory(capabilities: DatabaseType.redis.capabilities)
    let manager = DatabaseConnectionManager(sessionFactory: factory, lockSource: lockSource)
    try await manager.connect(
      config: ConnectionConfig(
        databaseType: .redis, host: "fake", port: 6379, database: "0", username: "",
        sslMode: .disable, protectionLevel: level, safeMode: .silent))
    return (manager, factory)
  }

  /// Runs `command` and returns the error it throws, or nil when it was sent.
  private func refusal(
    _ manager: DatabaseConnectionManager, _ command: RedisCommand,
    policy: ProtectionPolicy? = nil, epoch: UInt64? = nil, userInitiated: Bool = true,
    confirmed: Bool = false
  ) async -> Error? {
    let current = await manager.connectionEpoch
    do {
      _ = try await manager.executeGatedRedisCommand(
        command, policy: policy ?? open, connectionEpoch: epoch ?? current,
        userInitiated: userInitiated, confirmed: confirmed)
      return nil
    } catch {
      return error
    }
  }

  private func blockedKind(_ error: Error?) -> StatementKind? {
    guard case .blockedByProtection(0, let kind, _)? = error as? DatabaseError else { return nil }
    return kind
  }

  @Test("A relock, a stale epoch and a db out of range are refused before anything is sent")
  func refusedBeforeSending() async throws {
    let registry = LockRegistry()
    let (manager, factory) = try await connect(lockSource: registry)
    let epoch = await manager.connectionEpoch
    let stale = await refusal(manager, Self.command("GET", "k"), epoch: epoch &+ 1)
    guard case .sessionChanged? = stale as? DatabaseError else {
      Issue.record("Expected sessionChanged, got \(String(describing: stale))")
      return
    }
    let negative = await refusal(manager, Self.command("GET", "k", db: -1))
    #expect(negative is RedisCommandRefusal)

    registry.setLockedConnections([LockIdentity(try #require(await manager.config))])
    let locked = await refusal(manager, Self.command("GET", "k"))
    guard case .connectionLocked? = locked as? DatabaseError else {
      Issue.record("Expected connectionLocked, got \(String(describing: locked))")
      return
    }
    #expect(factory.redisCommands.isEmpty)
  }

  @Test("Read-only refuses SET and sends INFO keyspace")
  func readOnly() async throws {
    let (manager, factory) = try await connect(level: .readOnly)
    #expect(blockedKind(await refusal(manager, Self.command("SET", "k", "v"))) == .dml)
    #expect(factory.redisCommands.isEmpty)
    let info = Self.command("INFO", "keyspace")
    #expect(await refusal(manager, info) == nil)
    #expect(factory.redisCommands == [info])
  }

  @Test(
    "Schema-only blocks admin, destructive, script and unknown commands and sends HSET and EVAL_RO")
  func schemaOnly() async throws {
    let (manager, factory) = try await connect(level: .schemaOnly)
    let blocked: [(RedisCommand, StatementKind)] = [
      (Self.command("FLUSHDB"), .utility),
      // Admin without the destructive flag: the shared policy blocks `.utility` on its own
      (Self.command("INFO", "all"), .utility),
      (Self.command("EVAL", "return 1", "0"), .unknown),
      (Self.command("NOTACOMMAND", "x"), .unknown),
    ]
    for (command, kind) in blocked {
      // Confirmed, so only the policy can refuse it
      #expect(blockedKind(await refusal(manager, command, confirmed: true)) == kind)
    }
    #expect(factory.redisCommands.isEmpty)
    let allowed = [
      Self.command("HSET", "h", "f", "v"), Self.command("EVAL_RO", "return 1", "0"),
    ]
    for command in allowed {
      #expect(await refusal(manager, command) == nil)
    }
    #expect(factory.redisCommands == allowed)
  }

  @Test("A destructive command needs confirmed; an editor-refused command is never sent")
  func confirmationAndEditorRefusal() async throws {
    let (manager, factory) = try await connect()
    let flush = Self.command("FLUSHDB")
    #expect(blockedKind(await refusal(manager, flush)) == .utility)
    let select = await refusal(manager, Self.command("SELECT", "1"), confirmed: true)
    let expected = try #require(
      RedisCommandClassifier.classify(Self.command("SELECT", "1").args).refusal)
    guard case .blockedByProtection(0, .unknown, let reason)? = select as? DatabaseError else {
      Issue.record("Expected blockedByProtection, got \(String(describing: select))")
      return
    }
    #expect(reason == expected)
    #expect(factory.redisCommands.isEmpty)

    #expect(await refusal(manager, flush, confirmed: true) == nil)
    #expect(factory.redisCommands == [flush])
  }

  @Test("The arguments sent are the classified ones, byte for byte, with their db")
  func bytesSentAsClassified() async throws {
    let (manager, factory) = try await connect()
    let key = Data([0x6B, 0x0D, 0x0A, 0xFF, 0x00])
    let value = Data([0xFF, 0xFE, 0x0D, 0x0A])
    let command = RedisCommand(args: [Data("SET".utf8), key, value], db: 3)
    #expect(RedisCommandClassifier.classify(command.args).statement.kind == .dml)
    #expect(await refusal(manager, command) == nil)
    #expect(factory.redisCommands == [command])
    #expect(factory.redisCommands.first?.args == [Data("SET".utf8), key, value])
    #expect(factory.redisCommands.first?.db == 3)
  }

  @Test("A server error never carries the arguments it echoes")
  func errorEchoStripped() async throws {
    let (manager, factory) = try await connect()
    let session = try #require(factory.sessions.first)
    // The server's own echo, in any case: the plugin strips it too, this is the app's own cut
    session.failNextRedisSend(
      with: EnginePluginError.server(
        EngineEvent.Failure(
          code: .query, message: "ERR unknown command 'FOO', With Args Beginning With: 's3cret' ",
          serverCode: "ERR")))
    let error = await refusal(manager, Self.command("FOO", "s3cret"))
    guard case .queryFailed(let message, _)? = error as? DatabaseError else {
      Issue.record("Expected queryFailed, got \(String(describing: error))")
      return
    }
    #expect(message == "ERR unknown command 'FOO'")
  }

  @Test("A reply of more rows than the cap is refused, not collected")
  func replyRowCap() async throws {
    let (manager, factory) = try await connect()
    let session = try #require(factory.sessions.first)
    let leaf: [CellValue] = [.string("0.0"), .string("integer"), .int(0)]
    session.answerRedisSends(with: Array(repeating: leaf, count: 100_001))
    let error = await refusal(manager, Self.command("LRANGE", "k", "0", "-1"))
    guard case .queryFailed? = error as? DatabaseError else {
      Issue.record("Expected queryFailed, got \(String(describing: error))")
      return
    }
    session.answerRedisSends(with: Array(repeating: leaf, count: 100_000))
    #expect(await refusal(manager, Self.command("LRANGE", "k", "0", "-1")) == nil)
  }

  @Test("Only a user-initiated command counts as in flight", .timeLimit(.minutes(1)))
  func inFlightOnlyWhenUserInitiated() async throws {
    let (manager, factory) = try await connect()
    let session = try #require(factory.sessions.first)
    for userInitiated in [true, false] {
      session.holdNextRedisSend()
      let running = Task {
        await refusal(manager, Self.command("GET", "k"), userInitiated: userInitiated)
      }
      let held = await boundedWait("Redis send held") {
        while session.heldRedisSendCount == 0, !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(5))
        }
        return true
      }
      #expect(held == true)
      #expect(await manager.runningStatementStatus().inFlight == userInitiated)
      session.releaseHeldRedisSends()
      #expect(await running.value == nil)
      #expect(await manager.runningStatementStatus().inFlight == false)
    }
  }
}

// Nested, so `-only-testing:DbloreTests/RedisGateTests` runs them too
extension RedisGateTests {
  @Suite("Redis reply tree")
  struct ReplyTree {
    private static func row(_ path: String, _ type: String, _ value: CellValue) -> [CellValue] {
      [.string(path), .string(type), value]
    }

    @Test("Nested map and array rows rebuild the tree, bytes included")
    func nested() throws {
      let rows = [
        Self.row("0", "map", .int(4)),
        Self.row("0.0", "bulk", .string("name")),
        Self.row("0.1", "bulk", .data(Data([0xFF, 0x00]))),
        Self.row("0.2", "simple", .string("list")),
        Self.row("0.3", "array", .int(3)),
        Self.row("0.3.0", "integer", .int(7)),
        Self.row("0.3.1", "null", .null),
        Self.row("0.3.2", "set", .int(1)),
        Self.row("0.3.2.0", "boolean", .string("true")),
      ]
      let reply = try RedisReply(rows: rows)
      #expect(
        reply
          == .map([
            RedisReplyPair(key: .bulk(.text("name")), value: .bulk(.bytes(Data([0xFF, 0x00])))),
            RedisReplyPair(
              key: .simple(.text("list")),
              value: .array([.integer(7), .null, .set([.boolean(true)])])),
          ]))
      #expect(
        try RedisReply(rows: [Self.row("0", "error", .string("ERR no"))]) == .error(.text("ERR no"))
      )
    }

    @Test("Malformed rows throw, never a guessed tree")
    func malformed() {
      let cases: [[[CellValue]]] = [
        [],
        // A child missing
        [Self.row("0", "array", .int(2)), Self.row("0.0", "integer", .int(1))],
        // A child at the wrong path
        [Self.row("0", "array", .int(1)), Self.row("0.1", "integer", .int(1))],
        // A row after the reply ended
        [Self.row("0", "integer", .int(1)), Self.row("1", "integer", .int(2))],
        // A map with an odd child count
        [Self.row("0", "map", .int(1)), Self.row("0.0", "bulk", .string("k"))],
        // An unknown type, a wrong value type, a missing cell
        [Self.row("0", "stream", .string("x"))],
        [Self.row("0", "integer", .string("seven"))],
        [[.string("0"), .string("bulk")]],
        // A negative child count
        [Self.row("0", "array", .int(-1))],
      ]
      for rows in cases {
        #expect(throws: RedisReplyDecodingError.self) { try RedisReply(rows: rows) }
      }
    }

    @Test("A reply past the node cap is refused, 100,000 nodes by default")
    func nodeCap() throws {
      let rows =
        [Self.row("0", "array", .int(3))]
        + (0..<3).map { Self.row("0.\($0)", "integer", .int($0)) }
      #expect(
        try RedisReply(rows: rows, maxNodes: 4) == .array([.integer(0), .integer(1), .integer(2)]))
      #expect(throws: RedisReplyDecodingError.self) { try RedisReply(rows: rows, maxNodes: 3) }

      func flat(_ children: Int) -> [[CellValue]] {
        [Self.row("0", "array", .int(children))]
          + (0..<children).map { Self.row("0.\($0)", "null", .null) }
      }
      #expect(throws: Never.self) { try RedisReply(rows: flat(99_999)) }
      #expect(throws: RedisReplyDecodingError.self) { try RedisReply(rows: flat(100_000)) }
    }

    @Test("Aggregates nested 128 levels deep are read, 129 are refused")
    func depthCap() throws {
      /// `levels` arrays of one child each, the innermost holding an integer
      func nested(_ levels: Int) -> [[CellValue]] {
        var rows: [[CellValue]] = []
        var path = "0"
        for _ in 0..<levels {
          rows.append(Self.row(path, "array", .int(1)))
          path += ".0"
        }
        return rows + [Self.row(path, "integer", .int(1))]
      }
      #expect(throws: Never.self) { try RedisReply(rows: nested(128)) }
      #expect(throws: RedisReplyDecodingError.self) { try RedisReply(rows: nested(129)) }
    }
  }

  @Suite("Redis send seam source scan")
  struct SendSeamScan {
    /// The gate: the only file that may cast a session to `RedisCommandSending` and send
    private static let gate = "Dblore/Database/DatabaseConnectionManager+RedisCommands.swift"
    /// Holds the Test Connection probe (`func probe(`), whose `PING` on its own session is the
    /// documented bypass added in task 8.1: allowed inside that function only, not yet used
    private static let probeFile = "Dblore/Database/DatabaseConnectionManager.swift"
    private static let probeStart = "  private func probe(_ config: ConnectionConfig)"
    /// The protocol's declaration
    private static let declaration = "Dblore/Database/Redis/RedisCommandSending.swift"

    @Test("RedisCommandSending is named only by the gate's two casts, its declaration and conformances")
    func onlyThroughTheGate() throws {
      let mention = try Regex(#"\bRedisCommandSending\b"#)
      // A type declaring its conformance (`final class RedisSession: …, RedisCommandSending`)
      let conformance = try Regex(
        #"^(?:(?:public|internal|private|fileprivate|final|nonisolated)\s+)*(?:class|struct|actor|enum|extension)\s+\w+[^{]*:[^{]*\bRedisCommandSending\b"#
      )
      // A type declaration whose inheritance list goes on past the line's `:` or `,`
      let openDeclaration = try Regex(
        #"^(?:(?:public|internal|private|fileprivate|final|nonisolated)\s+)*(?:class|struct|actor|enum|extension)\s+\w+[^{]*[:,]$"#
      )
      // A wrapped line of that inheritance list (bare type names and commas only)
      let inheritanceLine = try Regex(#"^(?:@\w+\s+)?\w+(?:\s*,\s*(?:@\w+\s+)?\w+)*\s*,?\s*\{?$"#)
      // The gate's casts: `is any RedisCommandSending`, `as? any RedisCommandSending`
      let cast = try Regex(#"\b(?:is|as[?!]?)\s+(?:any\s+)?RedisCommandSending\b"#)
      let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent()
      let sources = root.appendingPathComponent("Dblore")
      let files = try FileManager.default.subpathsOfDirectory(atPath: sources.path)
        .filter { $0.hasSuffix(".swift") }
      // Guards a vacuous pass: the scan must have read the app's sources
      #expect(files.count > 300)
      var gateCasts = 0
      var violations: [String] = []
      for relative in files {
        let path = "Dblore/" + relative
        let text = try String(contentsOf: sources.appendingPathComponent(relative), encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let probe = Self.probeLines(lines, in: path)
        // The previous code line left a type's inheritance list open
        var inInheritanceList = false
        for (index, line) in lines.enumerated() {
          let code = Self.code(line)
          if code.isEmpty || code.hasPrefix("//") || code.hasPrefix("*") || code.hasPrefix("/*") {
            continue
          }
          let continuesList = inInheritanceList && code.wholeMatch(of: inheritanceLine) != nil
          inInheritanceList =
            code.wholeMatch(of: openDeclaration) != nil || (continuesList && code.hasSuffix(","))
          guard code.contains(mention) else { continue }
          if path == Self.gate {
            if code.contains(cast) {
              gateCasts += 1
              continue
            }
          } else if path == Self.declaration || probe.contains(index) || continuesList
            || code.contains(conformance)
          {
            continue
          }
          violations.append("\(path):\(index + 1): \(code)")
        }
      }
      #expect(gateCasts == 2, "the gate checks the session's type, then casts it to send")
      #expect(violations.isEmpty, "RedisCommandSending outside the gate: \(violations)")
    }

    /// `line` trimmed, without the `/* … */` comments it starts with
    private static func code(_ line: Substring) -> String {
      var code = line.trimmingCharacters(in: .whitespaces)
      while code.hasPrefix("/*"), let end = code.dropFirst(2).range(of: "*/") {
        code = code[end.upperBound...].trimmingCharacters(in: .whitespaces)
      }
      return code
    }

    /// The line indexes of the Test Connection probe's body (empty in any other file)
    private static func probeLines(_ lines: [Substring], in path: String) -> Range<Int> {
      guard path == probeFile, let start = lines.firstIndex(where: { $0.hasPrefix(probeStart) }),
        let end = lines[start...].firstIndex(where: { $0 == "  }" })
      else { return 0..<0 }
      return start..<end
    }
  }
}
