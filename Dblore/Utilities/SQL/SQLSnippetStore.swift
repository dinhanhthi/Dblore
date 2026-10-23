// SQLSnippetStore.swift
// The saved SQL snippets, read by editor autocomplete and edited in Settings

import Foundation

@MainActor @Observable
final class SQLSnippetStore {
  static let shared = SQLSnippetStore(defaults: AppSettings.sharedDefaults)

  nonisolated static let defaultsKey = "ace.thi.dblore.sqlSnippets"
  /// Larger saved data reads as no snippets: 200 snippets at their limits stay well below it
  nonisolated static let maxStoredBytes = 2_000_000

  /// In the order they were added
  private(set) var snippets: [SQLSnippet]

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let localDataChanges = LocalDataChangeObserver()

  init(defaults: UserDefaults) {
    self.defaults = defaults
    snippets = Self.decode(defaults.data(forKey: Self.defaultsKey))
    // A backup import or a delete in Data settings rewrites the stored list
    localDataChanges.start { [weak self] note in
      guard LocalDataCategory.notification(note, includes: .sqlSnippets) else { return }
      Task { @MainActor [weak self] in self?.reload() }
    }
  }

  /// Adds `snippet`, or replaces the one with its id. Throws why it cannot be saved.
  func save(_ snippet: SQLSnippet) throws(SQLSnippet.ValidationError) {
    if let error = SQLSnippet.validate(snippet, among: snippets) { throw error }
    if let index = snippets.firstIndex(where: { $0.id == snippet.id }) {
      snippets[index] = snippet
    } else {
      snippets.append(snippet)
    }
    persist()
  }

  func delete(id: UUID) {
    snippets.removeAll { $0.id == id }
    persist()
  }

  func reload() {
    snippets = Self.decode(defaults.data(forKey: Self.defaultsKey))
  }

  private func persist() {
    guard let data = try? JSONEncoder().encode(snippets) else { return }
    defaults.set(data, forKey: Self.defaultsKey)
  }

  // MARK: - Stored data (any isolation)

  /// One saved snippet; nil when it cannot be decoded, so one bad entry drops only itself
  private nonisolated struct LossySnippet: Decodable {
    let snippet: SQLSnippet?

    init(from decoder: Decoder) throws {
      snippet = try? SQLSnippet(from: decoder)
    }
  }

  /// The saved list is untrusted: invalid entries are dropped and the limits applied; data that
  /// is no array, or over `maxStoredBytes`, reads as no snippets
  nonisolated static func decode(_ data: Data?) -> [SQLSnippet] {
    guard let data, data.count <= maxStoredBytes,
      let entries = try? JSONDecoder().decode([LossySnippet].self, from: data)
    else { return [] }
    return SQLSnippet.sanitized(entries.compactMap(\.snippet))
  }

  /// The stored list as raw JSON, nil when none is saved
  nonisolated static func storedData(defaults: UserDefaults, domainName: String) -> Data? {
    defaults.persistentDomain(forName: domainName)?[defaultsKey] as? Data
  }

  /// Writes `data` sanitized (an imported file is untrusted); nil removes the list
  nonisolated static func replace(_ data: Data?, defaults: UserDefaults, domainName: String) {
    var domain = defaults.persistentDomain(forName: domainName) ?? [:]
    if let data, let encoded = try? JSONEncoder().encode(decode(data)) {
      domain[defaultsKey] = encoded
    } else {
      domain.removeValue(forKey: defaultsKey)
    }
    defaults.setPersistentDomain(domain, forName: domainName)
  }
}
