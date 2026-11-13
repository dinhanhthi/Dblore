// RedisIntegrationTests.swift
// Live Redis tests through `RedisSession` and the real Redis plugin, written for CI and never run
// locally. They need both opt-ins: `TEST_RUNNER_REDIS_TESTS=1` with a Redis test server, and
// `TEST_RUNNER_ENGINE_PLUGIN_TESTS=1` with the notarized dev bundle in .plugin-dev/redis/
// (scripts/release-plugin.sh --plugin redis --install-dev). Server: `TEST_REDIS_HOST/PORT/USER/
// PASSWORD` (forwarded by xcodebuild from the `TEST_RUNNER_` copies), default 127.0.0.1:6379 over
// plain TCP with no user and no password. Every test works on its own random key names, removes
// them, and never flushes anything, so a shared server is safe.

import Darwin
import Foundation
import Testing

@testable import Dblore

nonisolated enum TestRedisServer {
  private static let env = ProcessInfo.processInfo.environment

  static let host = env["TEST_REDIS_HOST"] ?? "127.0.0.1"
  static let port = Int(env["TEST_REDIS_PORT"] ?? "6379") ?? 6379
  static let username = env["TEST_REDIS_USER"] ?? ""
  static let password = env["TEST_REDIS_PASSWORD"] ?? ""

  static var config: ConnectionConfig {
    ConnectionConfig(
      databaseType: .redis, host: host, port: port, database: "0", username: username,
      password: password, sslMode: .disable, timeoutSeconds: 10)
  }
}

/// The dev Redis bundle behind a runtime of its own plugin id (never `redis`, the id the app's
/// own runtime uses), loaded once per test process with the app's signature checks (Team ID and
/// the dev catalog's cdhash). A non-notarized bundle is never loaded.
nonisolated enum RedisTestPlugin {
  static let pluginID = "redis-live-test"

  private struct DevCatalog: Decodable {
    let cdhash: String
    let bundleName: String
    let notarized: Bool
  }

  struct Refused: Error, CustomStringConvertible { let description: String }

  private typealias ProtocolFunction = @convention(c) () -> Int32
  private typealias RequestFunction =
    @convention(c) (UnsafePointer<CChar>, UnsafeMutableRawPointer?, EngineEntryPoint.Emit) -> Void

  private static let pluginDev = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent(".plugin-dev/redis", isDirectory: true)

  private static let installed: String = {
    EnginePluginRuntime.install(
      EnginePluginRuntime(pluginID: pluginID, loader: { try entryPoint() }))
    return pluginID
  }()

  /// The plugin id to open a `RedisSession` with
  static func install() -> String { installed }

  /// Unpacks the notarized zip with ditto into a temporary folder (kept: the code stays mapped
  /// for the process) and loads it as the app's loader does.
  private static func entryPoint() throws -> EngineEntryPoint {
    let data = try Data(contentsOf: pluginDev.appendingPathComponent("dev-catalog.json"))
    let catalog = try JSONDecoder().decode(DevCatalog.self, from: data)
    guard catalog.notarized else { throw Refused(description: "dev Redis plugin not notarized") }
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("redis-live-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let ditto = Process()
    ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    ditto.arguments = [
      "-x", "-k", pluginDev.appendingPathComponent("DbloreRedis.zip").path, dir.path,
    ]
    try ditto.run()
    ditto.waitUntilExit()
    guard ditto.terminationStatus == 0 else {
      throw Refused(description: "ditto exited \(ditto.terminationStatus)")
    }
    let bundle = try PluginLoader.loadBundle(
      at: dir.appendingPathComponent(catalog.bundleName, isDirectory: true),
      expectedTeamID: PluginLoader.teamIdentifier, expectedCDHash: catalog.cdhash)
    guard let path = bundle.executableURL?.path,
      let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL | RTLD_NOLOAD),
      let protocolSymbol = dlsym(handle, "dblore_engine_protocol"),
      let requestSymbol = dlsym(handle, "dblore_engine_request")
    else { throw Refused(description: "the Redis bundle has no engine entry points") }
    let protocolVersion = unsafeBitCast(protocolSymbol, to: ProtocolFunction.self)
    let request = unsafeBitCast(requestSymbol, to: RequestFunction.self)
    return EngineEntryPoint(
      protocolVersion: { protocolVersion() },
      send: { json, context, emit in json.withCString { request($0, context, emit) } })
  }
}

@Suite("RedisIntegrationTests", .requiresRedis, .requiresEnginePlugin, .serialized)
struct RedisIntegrationTests {
  /// A key prefix no other run shares
  private static func prefix(_ name: String) -> Data {
    Data("dblore:test:\(name):\(UUID().uuidString):".utf8)
  }

  private static func args(_ parts: Any...) -> [Data] {
    parts.map { part in (part as? Data) ?? Data(String(describing: part).utf8) }
  }

  /// Opens a session, runs `body`, then runs `cleanup` and closes, whatever `body` threw
  private func withSession(
    cleanup: [[Data]], _ body: (RedisSession) async throws -> Void
  ) async throws {
    let session = RedisSession(
      pluginID: RedisTestPlugin.install(), config: TestRedisServer.config,
      hostKeyValidator: RejectUnknownSSHHostKeys())
    do {
      try await session.open()
      try await body(session)
    } catch {
      for command in cleanup { _ = try? await reply(session, command) }
      await session.close()
      throw error
    }
    for command in cleanup { _ = try? await reply(session, command) }
    await session.close()
  }

  /// The whole reply of `args` in database 0
  private func reply(_ session: RedisSession, _ args: [Data]) async throws -> RedisReply {
    let source = try await session.send(RedisCommand(args: args, db: 0))
    var rows: [[CellValue]] = []
    for try await row in source.rows { rows.append(row) }
    return try RedisReply(rows: rows)
  }

  @Test("A binary key and value with CR LF, NUL and a command name round-trip byte for byte")
  func binaryKeyRoundTrip() async throws {
    let prefix = Self.prefix("binary")
    let payload = Data([0xFF, 0x00, 0x0D, 0x0A]) + Data("FLUSHALL".utf8)
    let key = prefix + payload
    let sentinel = Self.prefix("sentinel") + Data("kept".utf8)
    try await withSession(cleanup: [Self.args("UNLINK", key, sentinel)]) { session in
      #expect(try await reply(session, Self.args("SET", sentinel, "kept")) == .simple(.text("OK")))
      #expect(try await reply(session, Self.args("SET", key, payload)) == .simple(.text("OK")))

      #expect(try await reply(session, Self.args("GET", key)) == .bulk(.bytes(payload)))
      // The server holds the key under its exact bytes: SCAN gives them back unchanged
      var cursor = "0"
      var found: [RedisReply] = []
      repeat {
        let page = try await reply(
          session, Self.args("SCAN", cursor, "MATCH", prefix + Data("*".utf8), "COUNT", 1000))
        guard case .array(let parts) = page, parts.count == 2,
          case .bulk(.text(let next)) = parts[0], case .array(let keys) = parts[1]
        else {
          Issue.record("unexpected SCAN reply \(page)")
          return
        }
        found += keys
        cursor = next
      } while cursor != "0"
      #expect(found == [.bulk(.bytes(key))])
      // The bytes "FLUSHALL" travelled as data, never as a command
      #expect(try await reply(session, Self.args("GET", sentinel)) == .bulk(.text("kept")))

      #expect(try await reply(session, Self.args("UNLINK", key)) == .integer(1))
      #expect(try await reply(session, Self.args("EXISTS", key)) == .integer(0))
    }
  }

  @Test("A cancel in the middle of a large reply keeps the socket: PING answers on it")
  func cancelMidReplyKeepsSocket() async throws {
    let list = Self.prefix("big") + Data("list".utf8)
    let items = 200_000
    let chunk = 1_000
    try await withSession(cleanup: [Self.args("UNLINK", list)]) { session in
      for start in stride(from: 0, to: items, by: chunk) {
        let values = (start..<(start + chunk)).map { Data("item-\($0)".utf8) }
        _ = try await reply(session, [Data("RPUSH".utf8), list] + values)
      }
      #expect(try await reply(session, Self.args("LLEN", list)) == .integer(items))
      let before = try await reply(session, Self.args("CLIENT", "ID"))

      let source = try await session.send(
        RedisCommand(args: Self.args("LRANGE", list, 0, -1), db: 0))
      var rows = source.rows.makeAsyncIterator()
      var read = 0
      while read < 10, try await rows.next() != nil { read += 1 }
      #expect(read == 10)
      await session.interrupt()
      var cancelled = false
      do {
        while try await rows.next() != nil { read += 1 }
      } catch EnginePluginSessionError.cancelled {
        cancelled = true
      }
      #expect(cancelled, "the reply ended after \(read) rows without a cancel")
      #expect(read < items)

      // Same connection (same client id), still in step with the server
      #expect(try await reply(session, Self.args("PING")) == .simple(.text("PONG")))
      #expect(try await reply(session, Self.args("CLIENT", "ID")) == before)
    }
  }
}
