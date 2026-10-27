//
//  GridColumnPrefsStore.swift
//  Dblore
//

import Foundation

/// Grid column preferences of one table. Columns are named, never indexed, so a preference
/// survives column reorder, hidden columns and grid rebuilds.
struct GridColumnPrefs: Codable, Equatable {
  /// Leading columns are frozen up to and including this one, nil for none
  var frozenThrough: String?
  /// "Display As" of binary columns by column name; a column left out shows its size
  var binaryFormats: [String: BinaryDisplayFormat] = [:]

  private enum CodingKeys: String, CodingKey {
    case frozenThrough, binaryFormats
  }

  init(frozenThrough: String? = nil, binaryFormats: [String: BinaryDisplayFormat] = [:]) {
    self.frozenThrough = frozenThrough
    self.binaryFormats = binaryFormats
  }

  /// Entries written before a field existed decode it as empty; a format this build does not
  /// know is dropped, so the other preferences still load
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    frozenThrough = try container.decodeIfPresent(String.self, forKey: .frozenThrough)
    let formats =
      try container.decodeIfPresent([String: String].self, forKey: .binaryFormats) ?? [:]
    binaryFormats = formats.compactMapValues(BinaryDisplayFormat.init(rawValue:))
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(frozenThrough, forKey: .frozenThrough)
    if !binaryFormats.isEmpty { try container.encode(binaryFormats, forKey: .binaryFormats) }
  }
}

/// Grid column preferences per connection and table, stored as JSON in UserDefaults
final class GridColumnPrefsStore {
  nonisolated static let storageKey = "ace.thi.dblore.gridColumnPrefs"

  private let defaults: UserDefaults

  init(defaults: UserDefaults = RecentManager.sharedDefaults) {
    self.defaults = defaults
  }

  /// The table key of the saved filters: `databaseType|host|port|database|schema.name`
  static func key(for config: ConnectionConfig, schema: String, name: String) -> String {
    SavedFilterStore.key(for: config, schema: schema, name: name)
  }

  func frozenThrough(for key: String) -> String? {
    load()[key]?.frozenThrough
  }

  /// Stores the frozen-through column; nil unfreezes and drops an entry left empty
  func setFrozenThrough(_ column: String?, for key: String) {
    update(key) { $0.frozenThrough = column }
  }

  /// "Display As" of the table's binary columns by column name
  func binaryFormats(for key: String) -> [String: BinaryDisplayFormat] {
    load()[key]?.binaryFormats ?? [:]
  }

  /// Stores the "Display As" of `column`; `.size` (the default) removes it and drops an entry
  /// left empty
  func setBinaryFormat(_ format: BinaryDisplayFormat, column: String, for key: String) {
    update(key) { $0.binaryFormats[column] = format == .size ? nil : format }
  }

  /// The column the grid freezes through, given the current order of the result columns (the
  /// `#` gutter excluded) and the hidden ones: `stored` itself, or when it is hidden the last
  /// visible column before it. Nil when `stored` is nil, no longer a column, or has no visible
  /// column at or before it.
  nonisolated static func resolvedFrozenThrough(
    _ stored: String?, columns: [String], hidden: Set<String>
  ) -> String? {
    guard let stored, let index = columns.firstIndex(of: stored) else { return nil }
    return columns[...index].last { !hidden.contains($0) }
  }

  /// Changes the entry of `key`, removed when it is left with no preference
  private func update(_ key: String, _ change: (inout GridColumnPrefs) -> Void) {
    var all = load()
    var prefs = all[key] ?? GridColumnPrefs()
    change(&prefs)
    all[key] = prefs == GridColumnPrefs() ? nil : prefs
    store(all)
  }

  /// One table's entry; a malformed one is dropped alone, so the next write keeps the others
  private struct StoredEntry: Decodable {
    let prefs: GridColumnPrefs?

    init(from decoder: Decoder) throws {
      prefs = try? GridColumnPrefs(from: decoder)
    }
  }

  private func load() -> [String: GridColumnPrefs] {
    guard let data = defaults.data(forKey: Self.storageKey),
      let all = try? JSONDecoder().decode([String: StoredEntry].self, from: data)
    else { return [:] }
    return all.compactMapValues(\.prefs)
  }

  private func store(_ all: [String: GridColumnPrefs]) {
    guard let data = try? JSONEncoder().encode(all) else { return }
    defaults.set(data, forKey: Self.storageKey)
  }
}
