// DataSettingsModel.swift
// Settings model for local data: summaries, export, import, and removal.
// Secret values never enter this type. Removal asks the inventory to delete accounts.

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

  var totalBytes: Int64 {
    rows.reduce(0) { $0 + ($1.summary?.bytes ?? 0) }
  }

  @ObservationIgnored private let providers: [any LocalDataProvider]
  @ObservationIgnored private let inventory: any SecretInventory
  @ObservationIgnored private var pending: PendingAction?

  init(providers: [any LocalDataProvider], inventory: any SecretInventory) {
    self.providers = providers
    self.inventory = inventory
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
    try await Self.writePackage([category], providers: providers, to: url)
  }

  /// Writes one package containing these categories, in order.
  /// `.localModels` is written only when it is listed.
  func export(_ categories: [LocalDataCategory], to url: URL) async throws {
    try await Self.writePackage(categories, providers: providers, to: url)
  }

  /// Exports every category this model can reach. Local models are included only when asked.
  func exportAll(includeModels: Bool, to url: URL) async throws {
    let wanted = LocalDataBackup.exportAllCategories(
      including: includeModels ? [.localModels] : [])
    let available = Set(providers.map(\.category))
    let categories = wanted.filter { available.contains($0) }
    try await Self.writePackage(categories, providers: providers, to: url)
  }

  func prepareClear(_ category: LocalDataCategory) -> ConfirmationToken {
    issue(.clear(category))
  }

  func clear(_ category: LocalDataCategory, confirmed token: ConfirmationToken) async {
    guard consume(token, matching: .clear(category)) else { return }
    guard let provider = providers.first(where: { $0.category == category }) else { return }
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
    let failures = await Self.clear(providers)
    var secretFailure: String?
    if includeSecrets {
      do {
        try await Self.removeSecrets(inventory)
      } catch {
        secretFailure = error.localizedDescription
      }
    }
    await refresh()
    for failure in failures {
      update(failure.category) { $0.error = failure.message }
    }
    error = secretFailure
  }

  func prepareDeleteSecret(_ item: SecretItem) -> ConfirmationToken {
    issue(.deleteSecret(item.id))
  }

  func deleteSecret(_ item: SecretItem, confirmed token: ConfirmationToken) async {
    guard consume(token, matching: .deleteSecret(item.id)) else { return }
    do {
      try await Self.delete(item, from: inventory)
      error = nil
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

  @concurrent private static func removeSecrets(_ inventory: any SecretInventory) async throws {
    let kinds: [SecretKind] = [
      .dbPassword, .aiKey, .chatGPTToken, .safeModePassword, .clientCertificate, .sshCredential,
      .sshHostKey,
    ]
    for kind in kinds {
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
    _ categories: [LocalDataCategory], providers: [any LocalDataProvider], to url: URL
  ) async throws {
    try await LocalDataBackup.export(categories: categories, providers: providers, to: url)
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
