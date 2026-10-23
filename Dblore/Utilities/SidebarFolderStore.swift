// SidebarFolderStore.swift
// Folders of tables and views in the left sidebar, per connection (`databaseType|host|port|
// database`, the key shape of `SavedFilterStore`). A folder lists its members by `schema.name`;
// a member the schema no longer has stays saved and is skipped when the sidebar renders.

import Foundation

/// A named folder of tables and views, listed in its schema's group
nonisolated struct SidebarFolder: Codable, Identifiable, Equatable, Sendable {
  var id: UUID
  var name: String
  /// The schema whose group lists the folder
  var schema: String
  /// `schema.name` of each table or view, in the order they were added
  var members: [String]

  init(id: UUID = UUID(), name: String, schema: String, members: [String] = []) {
    self.id = id
    self.name = name
    self.schema = schema
    self.members = members
  }

  /// `schema.name`, the member string of a table or view
  static func member(schema: String, name: String) -> String {
    "\(schema).\(name)"
  }

  /// Members that are no strings are dropped, so one bad member keeps its folder
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    schema = try container.decodeIfPresent(String.self, forKey: .schema) ?? ""
    members =
      ((try? container.decodeIfPresent([LossyString].self, forKey: .members)) ?? nil)?
      .compactMap(\.value) ?? []
  }

  private struct LossyString: Decodable {
    let value: String?

    init(from decoder: Decoder) throws {
      value = try? decoder.singleValueContainer().decode(String.self)
    }
  }
}

@MainActor @Observable
final class SidebarFolderStore {
  static let shared = SidebarFolderStore(defaults: AppSettings.sharedDefaults)

  nonisolated static let defaultsKey = "ace.thi.dblore.sidebarFolders"
  /// Larger saved data reads as no folders
  nonisolated static let maxStoredBytes = 2_000_000
  nonisolated static let maxConnections = 500
  nonisolated static let maxConnectionKeyLength = 2_048
  nonisolated static let maxFoldersPerConnection = 100
  nonisolated static let maxMembersPerFolder = 1_000
  nonisolated static let maxMemberLength = 512
  nonisolated static let maxSchemaLength = 255
  nonisolated static let nameLimit = 64

  /// Folders of each connection key, in the order they were made
  private(set) var foldersByConnection: [String: [SidebarFolder]]

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let localDataChanges = LocalDataChangeObserver()

  init(defaults: UserDefaults) {
    self.defaults = defaults
    foldersByConnection = Self.decode(defaults.data(forKey: Self.defaultsKey))
    // A backup import or a delete in Data settings rewrites the stored folders
    localDataChanges.start { [weak self] note in
      guard LocalDataCategory.notification(note, includes: .sidebarFolders) else { return }
      Task { @MainActor [weak self] in self?.reload() }
    }
  }

  /// The key folders of `config` are saved under
  nonisolated static func key(for config: ConnectionConfig) -> String {
    SavedFilterStore.connectionKey(for: config)
  }

  func folders(for key: String) -> [SidebarFolder] {
    foldersByConnection[key] ?? []
  }

  /// Adds an empty folder to `schema`. Nil when the name is blank or the connection has
  /// `maxFoldersPerConnection` folders.
  @discardableResult
  func createFolder(named name: String, schema: String, for key: String) -> SidebarFolder? {
    guard let name = Self.normalizedName(name),
      folders(for: key).count < Self.maxFoldersPerConnection
    else { return nil }
    let folder = SidebarFolder(name: name, schema: schema)
    foldersByConnection[key, default: []].append(folder)
    persist()
    return folder
  }

  /// A blank name keeps the old one
  func renameFolder(id: UUID, to name: String, for key: String) {
    guard let name = Self.normalizedName(name),
      let index = foldersByConnection[key]?.firstIndex(where: { $0.id == id })
    else { return }
    foldersByConnection[key]?[index].name = name
    persist()
  }

  /// Its members go back to the ungrouped list
  func deleteFolder(id: UUID, for key: String) {
    foldersByConnection[key]?.removeAll { $0.id == id }
    persist()
  }

  /// Puts `member` in the folder `id` only, out of any other folder of the connection. A full
  /// folder takes nothing.
  func move(_ member: String, toFolder id: UUID, for key: String) {
    guard var folders = foldersByConnection[key],
      let target = folders.firstIndex(where: { $0.id == id }),
      !folders[target].members.contains(member),
      folders[target].members.count < Self.maxMembersPerFolder,
      member.count <= Self.maxMemberLength
    else { return }
    for index in folders.indices { folders[index].members.removeAll { $0 == member } }
    folders[target].members.append(member)
    foldersByConnection[key] = folders
    persist()
  }

  func removeMember(_ member: String, for key: String) {
    guard var folders = foldersByConnection[key] else { return }
    for index in folders.indices { folders[index].members.removeAll { $0 == member } }
    foldersByConnection[key] = folders
    persist()
  }

  func reload() {
    foldersByConnection = Self.decode(defaults.data(forKey: Self.defaultsKey))
  }

  private func persist() {
    let kept = foldersByConnection.filter { !$0.value.isEmpty }
    if kept.isEmpty {
      defaults.removeObject(forKey: Self.defaultsKey)
    } else if let data = try? JSONEncoder().encode(kept) {
      defaults.set(data, forKey: Self.defaultsKey)
    }
  }

  // MARK: - Stored data (any isolation)

  /// Trimmed and cut to `nameLimit` characters; blank is nil
  nonisolated static func normalizedName(_ name: String) -> String? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let cut = String(trimmed.prefix(nameLimit)).trimmingCharacters(in: .whitespacesAndNewlines)
    return cut.isEmpty ? nil : cut
  }

  /// One saved folder; nil when it cannot be decoded, so one bad folder drops only itself
  private nonisolated struct LossyFolder: Decodable {
    let folder: SidebarFolder?

    init(from decoder: Decoder) throws {
      folder = try? SidebarFolder(from: decoder)
    }
  }

  /// The folders of one connection; anything but an array reads as none
  private nonisolated struct LossyFolderList: Decodable {
    let folders: [SidebarFolder]

    init(from decoder: Decoder) throws {
      folders = ((try? [LossyFolder](from: decoder)) ?? []).compactMap(\.folder)
    }
  }

  /// The saved folders are untrusted: undecodable folders are dropped, names normalized, and
  /// the limits applied; data that is no object, or over `maxStoredBytes`, reads as none
  nonisolated static func decode(_ data: Data?) -> [String: [SidebarFolder]] {
    guard let data, data.count <= maxStoredBytes,
      let all = try? JSONDecoder().decode([String: LossyFolderList].self, from: data)
    else { return [:] }
    var result: [String: [SidebarFolder]] = [:]
    for key in all.keys.sorted() where key.count <= maxConnectionKeyLength {
      guard result.count < maxConnections else { break }
      let folders = sanitized(all[key]?.folders ?? [])
      if !folders.isEmpty { result[key] = folders }
    }
    return result
  }

  /// Unique ids, normalized names, unique members within the limits, at most
  /// `maxFoldersPerConnection`
  private nonisolated static func sanitized(_ folders: [SidebarFolder]) -> [SidebarFolder] {
    var seen: Set<UUID> = []
    var kept: [SidebarFolder] = []
    for var folder in folders {
      guard kept.count < maxFoldersPerConnection else { break }
      guard let name = normalizedName(folder.name), folder.schema.count <= maxSchemaLength,
        seen.insert(folder.id).inserted
      else { continue }
      folder.name = name
      var members: Set<String> = []
      folder.members = folder.members.filter {
        !$0.isEmpty && $0.count <= maxMemberLength && members.insert($0).inserted
      }
      folder.members = Array(folder.members.prefix(maxMembersPerFolder))
      kept.append(folder)
    }
    return kept
  }

  /// The stored folders as raw JSON, nil when none are saved
  nonisolated static func storedData(defaults: UserDefaults, domainName: String) -> Data? {
    defaults.persistentDomain(forName: domainName)?[defaultsKey] as? Data
  }

  /// Writes `data` sanitized (an imported file is untrusted); nil, or nothing valid, removes
  /// the folders
  nonisolated static func replace(_ data: Data?, defaults: UserDefaults, domainName: String) {
    var domain = defaults.persistentDomain(forName: domainName) ?? [:]
    let folders = decode(data)
    if !folders.isEmpty, let encoded = try? JSONEncoder().encode(folders) {
      domain[defaultsKey] = encoded
    } else {
      domain.removeValue(forKey: defaultsKey)
    }
    defaults.setPersistentDomain(domain, forName: domainName)
  }
}
