// OutsideMCPServerStore.swift
// The outside MCP servers, saved as JSON in the app defaults (never a token), and their Bearer
// tokens, one generic-password Keychain item per server (service `ace.thi.dblore.mcp-client`,
// account = server id, this device only, listed in SecretInventory). The test host gets the
// in-memory token store. Keychain reads and writes run off the main actor. Tokens are never
// logged. On load, tokens whose server is gone (a failed delete) are deleted, but only when the
// saved list was read whole: a list that was cut or did not decode keeps every token.

import Foundation
import Observation
import Security

nonisolated protocol OutsideMCPTokenStore: AnyObject, Sendable {
  /// Nil when there is no token; throws when one cannot be read.
  func load(serverID: UUID) throws -> String?
  @discardableResult func save(_ token: String, serverID: UUID) -> Bool
  func delete(serverID: UUID)
  /// Ids of the stored tokens, read from attributes only
  func serverIDs() -> [UUID]
}

nonisolated final class KeychainOutsideMCPTokenStore: OutsideMCPTokenStore, Sendable {
  static let serviceName = "ace.thi.dblore.mcp-client"

  private static let vault = KeychainVault(
    service: serviceName, accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)

  func load(serverID: UUID) throws -> String? {
    switch Self.vault.read(account: serverID.uuidString) {
    case .notFound:
      return nil
    case .failed:
      throw OutsideMCPServerStoreError.tokenNotRead
    case .found(let data):
      guard let token = String(data: data, encoding: .utf8) else {
        throw OutsideMCPServerStoreError.tokenNotRead
      }
      return token
    }
  }

  @discardableResult
  func save(_ token: String, serverID: UUID) -> Bool {
    Self.vault.write(account: serverID.uuidString, data: Data(token.utf8)) == errSecSuccess
  }

  func delete(serverID: UUID) {
    Self.vault.delete(account: serverID.uuidString)
  }

  func serverIDs() -> [UUID] {
    Self.vault.accounts().compactMap(UUID.init(uuidString:))
  }
}

/// Test-host storage avoids Keychain prompts in XCTest.
nonisolated final class InMemoryOutsideMCPTokenStore: OutsideMCPTokenStore, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [UUID: String] = [:]

  func load(serverID: UUID) -> String? {
    lock.withLock { values[serverID] }
  }

  @discardableResult
  func save(_ token: String, serverID: UUID) -> Bool {
    lock.withLock { values[serverID] = token }
    return true
  }

  func delete(serverID: UUID) {
    lock.withLock { values[serverID] = nil }
  }

  func serverIDs() -> [UUID] {
    lock.withLock { Array(values.keys) }
  }
}

nonisolated enum OutsideMCPTokenStoreFactory {
  static let shared: any OutsideMCPTokenStore = makeDefault()

  /// Keychain in the app, in-memory under the test host
  static func makeDefault() -> any OutsideMCPTokenStore {
    SessionManager.isRunningAsTestHost
      ? InMemoryOutsideMCPTokenStore() : KeychainOutsideMCPTokenStore()
  }
}

nonisolated enum OutsideMCPServerStoreError: Error, Equatable, Sendable, LocalizedError {
  case blankName
  case tooManyServers
  case tokenNotSaved
  case tokenNotRead
  /// Every server was removed while this one was being added
  case removedWhileAdding

  var errorDescription: String? {
    switch self {
    case .blankName: "Enter a name for the server."
    case .tooManyServers: "Up to \(OutsideMCPServerStore.maxServers) servers can be added."
    case .tokenNotSaved: "The token could not be saved in the Keychain."
    case .tokenNotRead: "Could not read the token from the Keychain."
    case .removedWhileAdding: "Every server was removed while this one was being added."
    }
  }
}

@MainActor @Observable
final class OutsideMCPServerStore {
  static let shared = OutsideMCPServerStore(
    defaults: AppSettings.sharedDefaults, tokens: OutsideMCPTokenStoreFactory.shared)

  nonisolated static let defaultsKey = "ace.thi.dblore.outsideMCPServers"
  nonisolated static let maxServers = 20
  /// Larger saved data reads as no servers
  nonisolated static let maxStoredBytes = 1_000_000

  /// In the order they were added
  private(set) var servers: [OutsideMCPServer]

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let tokens: any OutsideMCPTokenStore
  /// Servers whose token is saved but which are not in `servers` yet
  @ObservationIgnored private var addingIDs = Set<UUID>()
  /// Whether the saved list was absent or read with no entry dropped
  @ObservationIgnored private let loadedWhole: Bool
  /// Bumped by `removeAll`: an add that saw another value aborts and deletes its token
  @ObservationIgnored private var removeAllCount = 0

  init(defaults: UserDefaults, tokens: any OutsideMCPTokenStore) {
    self.defaults = defaults
    self.tokens = tokens
    let loaded = Self.decode(defaults.data(forKey: Self.defaultsKey))
    servers = loaded.servers
    loadedWhole = loaded.isWhole
    Task { [weak self] in await self?.removeOrphanTokens() }
  }

  /// Checks the name, URL and token, saves the token, then the server: off, no tool allowed.
  /// An empty token adds a server that is sent no Authorization header.
  @discardableResult
  func add(name: String, url: String, token: String) async throws -> OutsideMCPServer {
    guard let name = OutsideMCPServer.normalizedName(name) else {
      throw OutsideMCPServerStoreError.blankName
    }
    let endpoint = try MCPClient.endpoint(url)
    let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard token.isEmpty || MCPClient.isValidToken(token) else {
      throw MCPClientError.invalidToken
    }
    guard servers.count < Self.maxServers else { throw OutsideMCPServerStoreError.tooManyServers }
    let server = OutsideMCPServer(name: name, url: endpoint.absoluteString)
    addingIDs.insert(server.id)
    defer { addingIDs.remove(server.id) }
    if !token.isEmpty {
      let removals = removeAllCount
      guard await Self.save(token, serverID: server.id, in: tokens) else {
        throw OutsideMCPServerStoreError.tokenNotSaved
      }
      guard removeAllCount == removals else {
        await Self.delete(serverID: server.id, in: tokens)
        throw OutsideMCPServerStoreError.removedWhileAdding
      }
    }
    servers.append(server)
    persist()
    return server
  }

  func setEnabled(_ isEnabled: Bool, for id: UUID) {
    guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
    servers[index].isEnabled = isEnabled
    persist()
  }

  /// Ticks `tool` as listed now, with its fingerprint, or unticks it.
  func setAllowed(_ tool: MCPClientTool, _ isAllowed: Bool, for id: UUID) {
    guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
    var tools = servers[index].allowedTools
    tools[tool.name] = isAllowed ? tool.fingerprint : nil
    servers[index].allowedTools = OutsideMCPServer.validTools(tools)
    persist()
  }

  /// Removes the server and its token.
  func remove(id: UUID) async {
    servers.removeAll { $0.id == id }
    persist()
    await Self.delete(serverID: id, in: tokens)
  }

  /// Removes every server and its token: Data settings' Clear All with saved credentials. An add
  /// still saving its token is aborted and deletes it.
  func removeAll() async {
    removeAllCount += 1
    let ids = servers.map(\.id)
    servers = []
    persist()
    for id in ids {
      await Self.delete(serverID: id, in: tokens)
    }
  }

  /// Deletes the tokens of servers that are not in the list, nor being added. Skipped when the
  /// saved list was not read whole: its dropped servers may still own their tokens.
  func removeOrphanTokens() async {
    guard loadedWhole else {
      await AppLogger.shared.warning(
        "Outside MCP servers: the saved list was not read whole; stored tokens are kept",
        category: "MCP")
      return
    }
    let stored = await Self.storedIDs(in: tokens)
    let orphans = Set(stored).subtracting(servers.map(\.id)).subtracting(addingIDs)
    for id in orphans {
      await Self.delete(serverID: id, in: tokens)
    }
  }

  /// The saved token, read off the main actor; nil when there is none. Throws `tokenNotRead`
  /// when the Keychain cannot read it.
  func token(for id: UUID) async throws -> String? {
    try await Self.load(serverID: id, in: tokens)
  }

  @concurrent private static func save(
    _ token: String, serverID: UUID, in tokens: any OutsideMCPTokenStore
  ) async -> Bool {
    tokens.save(token, serverID: serverID)
  }

  @concurrent private static func load(
    serverID: UUID, in tokens: any OutsideMCPTokenStore
  ) async throws -> String? {
    try tokens.load(serverID: serverID)
  }

  @concurrent private static func storedIDs(in tokens: any OutsideMCPTokenStore) async -> [UUID] {
    tokens.serverIDs()
  }

  @concurrent private static func delete(
    serverID: UUID, in tokens: any OutsideMCPTokenStore
  ) async {
    tokens.delete(serverID: serverID)
  }

  private func persist() {
    if servers.isEmpty {
      defaults.removeObject(forKey: Self.defaultsKey)
    } else if let data = try? JSONEncoder().encode(servers) {
      defaults.set(data, forKey: Self.defaultsKey)
    }
  }

  /// Bad entries, unsafe URLs, blank names, repeated ids and servers past `maxServers` are
  /// dropped. `isWhole` is true when there was no data, or it decoded with nothing dropped.
  nonisolated static func decode(_ data: Data?) -> (servers: [OutsideMCPServer], isWhole: Bool) {
    guard let data else { return ([], true) }
    guard data.count <= maxStoredBytes,
      let items = try? JSONDecoder().decode([LossyServer].self, from: data)
    else { return ([], false) }
    var seen = Set<UUID>()
    let servers = items.compactMap { item -> OutsideMCPServer? in
      guard var server = item.server, let name = OutsideMCPServer.normalizedName(server.name),
        (try? MCPClient.endpoint(server.url)) != nil, seen.insert(server.id).inserted
      else { return nil }
      server.name = name
      return server
    }
    return (
      Array(servers.prefix(maxServers)), servers.count == items.count && servers.count <= maxServers
    )
  }

  private nonisolated struct LossyServer: Decodable {
    let server: OutsideMCPServer?

    init(from decoder: Decoder) throws {
      server = try? OutsideMCPServer(from: decoder)
    }
  }
}
