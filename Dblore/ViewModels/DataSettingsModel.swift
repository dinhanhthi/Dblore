// DataSettingsModel.swift
// Settings model for local data: summaries, export, import, and removal.
// Secret values never enter this type. Removal asks the inventory to delete accounts. Clear All
// with credentials also removes the outside MCP servers, which are kept with their tokens.
// Deleting the MCP server token makes the server forget it: a running server restarts with a
// new one. While anything is locked, an import or clear that could drop a lock (connection rows,
// Recents' locked workspaces, the relock timeout in app settings) asks the owner first through
// LockCenter; so does deleting a workspace key, and the Lock password record goes only through
// LockCenter's removal rules.

import Foundation
import Observation

/// One category row in the data settings list.
nonisolated struct DataSettingsRow: Equatable, Identifiable, Sendable {
  var category: LocalDataCategory
  var summary: LocalDataSummary?
  var loading: Bool
  var error: String?
  var id: LocalDataCategory { category }
}

/// Outcome of importing one category from a backup package.
nonisolated struct DataImportResult: Equatable, Sendable {
  var category: LocalDataCategory
  var succeeded: Bool
}

/// Proof that the user confirmed one destructive action. A token authorizes only that action.
nonisolated struct ConfirmationToken: Equatable, Sendable {
  fileprivate let id: UUID
  fileprivate init() { id = UUID() }
}

@MainActor @Observable
final class DataSettingsModel {
  private(set) var rows: [DataSettingsRow]
  private(set) var secrets: [SecretItem] = []
  /// Set when clearing every secret fails. Category failures stay on the row.
  private(set) var error: String?
  /// Set while an export runs, nil otherwise.
  private(set) var exportProgress: BackupExportProgress?

  var totalBytes: Int64 {
    rows.reduce(0) { $0 + ($1.summary?.bytes ?? 0) }
  }

  @ObservationIgnored private let providers: [any LocalDataProvider]
  @ObservationIgnored private let inventory: any SecretInventory
  @ObservationIgnored private let outsideServers: OutsideMCPServerStore
  @ObservationIgnored private let mcpServerTokenDeleted: @MainActor @Sendable () async -> Void
  @ObservationIgnored private let lockCenter: LockCenter
  /// Recents: the locked workspaces the Lock password removal checks (open ones are registered)
  @ObservationIgnored private let recentWorkspaces: @MainActor () -> [WorkspaceHistoryEntry]
  @ObservationIgnored private var pending: PendingAction?

  init(
    providers: [any LocalDataProvider], inventory: any SecretInventory,
    outsideServers: OutsideMCPServerStore = .shared,
    mcpServerTokenDeleted: @escaping @MainActor @Sendable () async -> Void = {
      await MCPServerController.shared.forgetToken()
    },
    lockCenter: LockCenter = .shared,
    recentWorkspaces: @escaping @MainActor () -> [WorkspaceHistoryEntry] = {
      RecentManager.shared.recentWorkspaces
    }
  ) {
    self.providers = providers
    self.inventory = inventory
    self.outsideServers = outsideServers
    self.mcpServerTokenDeleted = mcpServerTokenDeleted
    self.lockCenter = lockCenter
    self.recentWorkspaces = recentWorkspaces
    rows = providers.map {
      DataSettingsRow(category: $0.category, summary: nil, loading: false, error: nil)
    }
  }

  /// Loads every summary and the secret list at the same time, off the main actor.
  func refresh() async {
    error = nil
    for index in rows.indices {
      rows[index].loading = true
      rows[index].error = nil
    }
    let loaded = await Self.load(providers: providers, inventory: inventory)
    for index in rows.indices {
      rows[index].summary = loaded.summaries[rows[index].category]
      rows[index].loading = false
    }
    secrets = loaded.secrets
  }

  func export(_ category: LocalDataCategory, to url: URL) async throws {
    try await write([category], to: url)
  }

  /// Writes one package containing these categories, in order.
  /// `.localModels` is written only when it is listed.
  func export(_ categories: [LocalDataCategory], to url: URL) async throws {
    try await write(categories, to: url)
  }

  /// Exports every category this model can reach. Local models are included only when asked.
  func exportAll(includeModels: Bool, to url: URL) async throws {
    let wanted = LocalDataBackup.exportAllCategories(
      including: includeModels ? [.localModels] : [])
    let available = Set(providers.map(\.category))
    let categories = wanted.filter { available.contains($0) }
    try await write(categories, to: url)
  }

  /// Publishes `exportProgress` while the package is written. Cancelling the task deletes it.
  private func write(_ categories: [LocalDataCategory], to url: URL) async throws {
    exportProgress = BackupExportProgress(
      completed: 0, total: categories.count + 1, category: categories.first)
    defer { exportProgress = nil }
    try await Self.writePackage(categories, providers: providers, to: url) { [weak self] step in
      await MainActor.run { self?.exportProgress = step }
    }
  }

  func prepareClear(_ category: LocalDataCategory) -> ConfirmationToken {
    issue(.clear(category))
  }

  func clear(_ category: LocalDataCategory, confirmed token: ConfirmationToken) async {
    guard consume(token, matching: .clear(category)) else { return }
    guard let provider = providers.first(where: { $0.category == category }) else { return }
    if Self.lockClears.contains(category) {
      guard await ownerConfirmsLocks("clear \(category.title.lowercased())") else {
        update(category) { $0.error = Self.notConfirmed }
        return
      }
    }
    update(category) {
      $0.loading = true
      $0.error = nil
    }
    do {
      let summary = try await Self.clearedSummary(of: provider)
      update(category) {
        $0.summary = summary
        $0.loading = false
        $0.error = nil
      }
    } catch {
      update(category) {
        $0.loading = false
        $0.error = error.localizedDescription
      }
    }
  }

  func prepareClearAll(includeSecrets: Bool) -> ConfirmationToken {
    issue(.clearAll(includeSecrets: includeSecrets))
  }

  func clearAll(includeSecrets: Bool, confirmed token: ConfirmationToken) async {
    guard consume(token, matching: .clearAll(includeSecrets: includeSecrets)) else { return }
    let listed = includeSecrets ? await Self.listed(inventory) : []
    // Workspace keys are deleted too: their workspaces then open only with the Lock password
    if hasLocks || listed.contains(where: { $0.kind == .lockContentKey }) {
      guard await lockCenter.authenticateOwner(reason: "clear all local data") else {
        error = Self.notConfirmed
        return
      }
    }
    let failures = await Self.clear(providers)
    var secretFailures: [String] = []
    if includeSecrets {
      // The list goes with its tokens: names, URLs and ticked tools, not a secret by itself.
      await outsideServers.removeAll()
      // A locked row refused the history clear: the credentials of that saved row stay
      let keepsConnections = failures.contains { $0.category == .connectionHistory }
      do {
        try await Self.removeSecrets(inventory, keepingConnections: keepsConnections)
      } catch {
        secretFailures.append(error.localizedDescription)
      }
      if keepsConnections {
        secretFailures.append(
          "Connection passwords, certificates and SSH credentials were kept: a locked "
            + "connection is still saved.")
      }
      let passwords = listed.filter { $0.kind == .lockPassword }
      if !passwords.isEmpty, let refusal = await removeLockPassword(passwords) {
        secretFailures.append(refusal)
      }
      await mcpServerTokenDeleted()
    }
    await refresh()
    for failure in failures {
      update(failure.category) { $0.error = failure.message }
    }
    error = secretFailures.isEmpty ? nil : secretFailures.joined(separator: " ")
  }

  func prepareDeleteSecret(_ item: SecretItem) -> ConfirmationToken {
    issue(.deleteSecret(item.id))
  }

  func deleteSecret(_ item: SecretItem, confirmed token: ConfirmationToken) async {
    guard consume(token, matching: .deleteSecret(item.id)) else { return }
    switch item.kind {
    case .lockPassword:
      error = await removeLockPassword([item])
      secrets = await Self.listed(inventory)
      return
    case .lockContentKey:
      guard await lockCenter.authenticateOwner(reason: "delete a locked workspace's key")
      else {
        error = Self.notConfirmed
        return
      }
    default:
      break
    }
    do {
      try await Self.delete(item, from: inventory)
      error = nil
      // A server without its token would only be refused: turn it off.
      if item.kind == .outsideMCPToken, let id = UUID(uuidString: item.account) {
        outsideServers.setEnabled(false, for: id)
      }
      if item.kind == .mcpServerToken {
        await mcpServerTokenDeleted()
      }
    } catch {
      self.error = error.localizedDescription
    }
    secrets = await Self.listed(inventory)
  }

  func prepareImport(url: URL, selected: [LocalDataCategory]) -> ConfirmationToken {
    issue(.importBackup(url, selected))
  }

  /// Replaces every selected category, or none of them when the package is invalid.
  /// Returns one result per category. An unconfirmed call returns an empty list.
  func importBackup(
    url: URL, selected: [LocalDataCategory], confirmed token: ConfirmationToken
  ) async -> [DataImportResult] {
    guard consume(token, matching: .importBackup(url, selected)) else { return [] }
    if !Self.lockImports.isDisjoint(with: selected) {
      // A backup's rows replace the current ones, locks included: one without a lock drops it
      guard await ownerConfirmsLocks("import a backup over locked items") else {
        for category in selected {
          update(category) { $0.error = Self.notConfirmed }
        }
        return selected.map { DataImportResult(category: $0, succeeded: false) }
      }
    }
    do {
      try await Self.readPackage(url, categories: selected, providers: providers)
      await refresh()
      return selected.map { DataImportResult(category: $0, succeeded: true) }
    } catch {
      let message = error.localizedDescription
      for category in selected {
        update(category) { $0.error = message }
      }
      return selected.map { DataImportResult(category: $0, succeeded: false) }
    }
  }

  static let notConfirmed = "Touch ID or the Mac password did not confirm, so nothing changed."

  /// Categories whose clear can drop a lock: connection rows and Recents' locked workspaces
  private static let lockClears: Set<LocalDataCategory> = [.connectionHistory, .recentItems]
  /// Categories whose import can drop or weaken a lock: also the relock timeout (app settings)
  private static let lockImports = lockClears.union([.appSettings])

  /// A connection or workspace is locked (registered), or a locked workspace file this Mac has
  /// seen is listed
  private var hasLocks: Bool {
    !lockCenter.registry.lockedIdentities.isEmpty || !lockCenter.lockedWorkspaces.entries.isEmpty
  }

  /// True when nothing is locked, or the owner confirmed (Touch ID or the Mac password)
  private func ownerConfirmsLocks(_ reason: String) async -> Bool {
    guard hasLocks else { return true }
    return await lockCenter.authenticateOwner(reason: reason)
  }

  /// Removes the Lock password through LockCenter (refused while a locked workspace uses it;
  /// the owner confirms), then its listed accounts. Workspace keys stay. Nil when removed, else
  /// why not.
  private func removeLockPassword(_ items: [SecretItem]) async -> String? {
    let result = await lockCenter.removeLockPassword(
      current: nil, workspaces: recentWorkspaces(), reason: "delete the Lock password")
    guard result == .removed else { return result.message }
    do {
      for item in items {
        try await Self.delete(item, from: inventory)
      }
    } catch {
      return error.localizedDescription
    }
    return nil
  }

  private func issue(_ kind: PendingAction.Kind) -> ConfirmationToken {
    let token = ConfirmationToken()
    pending = PendingAction(token: token, kind: kind)
    return token
  }

  private func consume(_ token: ConfirmationToken, matching kind: PendingAction.Kind) -> Bool {
    guard let pending, pending.token == token, pending.kind == kind else { return false }
    self.pending = nil
    return true
  }

  private func update(_ category: LocalDataCategory, _ body: (inout DataSettingsRow) -> Void) {
    guard let index = rows.firstIndex(where: { $0.category == category }) else { return }
    body(&rows[index])
  }

  private struct PendingAction: Equatable {
    var token: ConfirmationToken
    var kind: Kind

    enum Kind: Equatable {
      case clear(LocalDataCategory)
      case clearAll(includeSecrets: Bool)
      case deleteSecret(String)
      case importBackup(URL, [LocalDataCategory])
    }
  }

  private struct ProviderFailure: Sendable {
    var category: LocalDataCategory
    var message: String
  }

  private struct Loaded: Sendable {
    var summaries: [LocalDataCategory: LocalDataSummary]
    var secrets: [SecretItem]
  }

  /// `@concurrent` leaves the main actor. Summaries run at the same time as the secret list.
  @concurrent private static func load(
    providers: [any LocalDataProvider], inventory: any SecretInventory
  ) async -> Loaded {
    async let summaries = loadSummaries(providers)
    async let secrets = inventory.items()
    return await Loaded(summaries: summaries, secrets: secrets)
  }

  @concurrent private static func loadSummaries(
    _ providers: [any LocalDataProvider]
  ) async -> [LocalDataCategory: LocalDataSummary] {
    await withTaskGroup(of: (LocalDataCategory, LocalDataSummary).self) { group in
      for provider in providers {
        group.addTask {
          let summary = await provider.summary()
          return (provider.category, summary)
        }
      }
      var loaded: [LocalDataCategory: LocalDataSummary] = [:]
      for await (category, summary) in group {
        loaded[category] = summary
      }
      return loaded
    }
  }

  @concurrent private static func clear(
    _ providers: [any LocalDataProvider]
  ) async -> [ProviderFailure] {
    var failures: [ProviderFailure] = []
    for provider in providers {
      do {
        try await provider.clear()
      } catch {
        failures.append(
          ProviderFailure(category: provider.category, message: error.localizedDescription))
      }
    }
    return failures
  }

  /// Every kind but the Lock password, which goes only through LockCenter's rules
  @concurrent private static func removeSecrets(
    _ inventory: any SecretInventory, keepingConnections: Bool
  ) async throws {
    let connections: [SecretKind] = [.dbPassword, .clientCertificate, .sshCredential]
    let others: [SecretKind] = [
      .aiKey, .chatGPTToken, .safeModePassword, .sshHostKey, .outsideMCPToken, .mcpServerToken,
      .lockContentKey,
    ]
    for kind in (keepingConnections ? [] : connections) + others {
      try await inventory.deleteAll(kind: kind)
    }
  }

  @concurrent private static func clearedSummary(
    of provider: any LocalDataProvider
  ) async throws -> LocalDataSummary {
    try await provider.clear()
    return await provider.summary()
  }

  @concurrent private static func writePackage(
    _ categories: [LocalDataCategory], providers: [any LocalDataProvider], to url: URL,
    progress: @escaping @Sendable (BackupExportProgress) async -> Void
  ) async throws {
    try await LocalDataBackup.export(
      categories: categories, providers: providers, to: url, progress: progress)
  }

  @concurrent private static func readPackage(
    _ url: URL, categories: [LocalDataCategory], providers: [any LocalDataProvider]
  ) async throws {
    try await LocalDataBackup.import(url, categories: categories, providers: providers)
  }

  @concurrent private static func delete(
    _ item: SecretItem, from inventory: any SecretInventory
  ) async throws {
    try await inventory.delete(item)
  }

  @concurrent private static func listed(_ inventory: any SecretInventory) async -> [SecretItem] {
    await inventory.items()
  }
}
