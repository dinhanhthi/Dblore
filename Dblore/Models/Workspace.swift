//
//  Workspace.swift
//  Dblore
//

import Foundation

/// Represents a workspace containing tabs, connection, and settings.
/// A workspace is saved as a .sqlws file.
struct Workspace: Codable, Identifiable, Sendable {
  /// File format version for future compatibility
  static let currentVersion = 1

  let id: UUID
  var name: String
  var fileURL: URL?

  // MARK: - Connection

  /// Connection configuration (password NOT stored, use keychainKey)
  var connectionConfig: ConnectionConfig?

  /// Keychain key for retrieving password
  var connectionKeychainKey: String?

  // MARK: - Tabs

  /// References to open tabs
  var tabs: [WorkspaceTabReference]

  /// Currently active tab ID
  var activeTabId: UUID?

  // MARK: - Settings

  /// Workspace-level settings (overrides user settings)
  var settings: WorkspaceSettings

  // MARK: - Favorites

  /// Saved SQL statements shown in the left sidebar
  var favorites: WorkspaceFavorites

  // MARK: - Metadata

  let createdAt: Date
  var lastOpenedAt: Date

  // MARK: - Coding

  private enum CodingKeys: String, CodingKey {
    case version
    case id
    case name
    case connectionConfig = "connection"
    case connectionKeychainKey
    case tabs
    case activeTabId
    case settings
    case favorites
    case createdAt
    case lastOpenedAt
  }

  init(
    id: UUID = UUID(),
    name: String = "Untitled",
    fileURL: URL? = nil,
    connectionConfig: ConnectionConfig? = nil,
    connectionKeychainKey: String? = nil,
    tabs: [WorkspaceTabReference] = [],
    activeTabId: UUID? = nil,
    settings: WorkspaceSettings = .empty,
    favorites: WorkspaceFavorites = .empty,
    createdAt: Date = Date(),
    lastOpenedAt: Date = Date()
  ) {
    self.id = id
    self.name = name
    self.fileURL = fileURL
    self.connectionConfig = connectionConfig
    self.connectionKeychainKey = connectionKeychainKey
    self.tabs = tabs
    self.activeTabId = activeTabId
    self.settings = settings
    self.favorites = favorites
    self.createdAt = createdAt
    self.lastOpenedAt = lastOpenedAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    // Version check for future compatibility
    let version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
    guard version <= Workspace.currentVersion else {
      throw DecodingError.dataCorruptedError(
        forKey: .version,
        in: container,
        debugDescription: "Unsupported workspace version: \(version)"
      )
    }

    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    connectionConfig = try container.decodeIfPresent(
      ConnectionConfig.self, forKey: .connectionConfig)
    connectionKeychainKey = try container.decodeIfPresent(
      String.self, forKey: .connectionKeychainKey)
    tabs = try container.decodeIfPresent([WorkspaceTabReference].self, forKey: .tabs) ?? []
    activeTabId = try container.decodeIfPresent(UUID.self, forKey: .activeTabId)
    settings = try container.decodeIfPresent(WorkspaceSettings.self, forKey: .settings) ?? .empty
    favorites =
      try container.decodeIfPresent(WorkspaceFavorites.self, forKey: .favorites) ?? .empty
    createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    lastOpenedAt = try container.decodeIfPresent(Date.self, forKey: .lastOpenedAt) ?? Date()

    // fileURL is not encoded (set when loading from file)
    fileURL = nil
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)

    try container.encode(Workspace.currentVersion, forKey: .version)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)

    // Encode connection without password
    if var config = connectionConfig {
      config.password = ""  // Never store password
      try container.encode(config, forKey: .connectionConfig)
    }

    try container.encodeIfPresent(connectionKeychainKey, forKey: .connectionKeychainKey)
    try container.encode(tabs, forKey: .tabs)
    try container.encodeIfPresent(activeTabId, forKey: .activeTabId)
    try container.encode(settings, forKey: .settings)
    try container.encode(favorites, forKey: .favorites)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(lastOpenedAt, forKey: .lastOpenedAt)
    // fileURL is not encoded
  }

  // MARK: - Helpers

  /// Returns the keychain key for the connection
  var keychainKey: String? {
    connectionKeychainKey
      ?? connectionConfig.map {
        "\($0.host):\($0.port):\($0.database):\($0.username)"
      }
  }

  /// Display string for the workspace
  var displayString: String {
    if let conn = connectionConfig {
      return "\(name) - \(conn.displayString)"
    }
    return name
  }

  /// Whether the workspace has been saved to a file
  var isSaved: Bool {
    fileURL != nil
  }

  /// Create a new untitled workspace
  static func newUntitled(connection: ConnectionConfig? = nil) -> Workspace {
    Workspace(
      name: "Untitled",
      connectionConfig: connection,
      connectionKeychainKey: connection.map {
        "\($0.host):\($0.port):\($0.database):\($0.username)"
      }
    )
  }
}

// MARK: - WorkspaceTabReference

/// Reference to a tab within a workspace (stored in .sqlws file)
struct WorkspaceTabReference: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  var fileURL: URL?
  var documentType: TabDocumentType
  var title: String
  /// App-scope security-scoped bookmark of `fileURL` (nil in workspaces saved before bookmarks)
  var bookmark: Data?
  /// Relation shown by a data viewer tab (nil for file tabs)
  var dataViewer: DataViewerReference?

  /// Table/view of a pinned data viewer tab
  struct DataViewerReference: Codable, Equatable, Sendable {
    var schema: String
    var name: String
    var orderColumns: [String]
  }

  init(
    id: UUID = UUID(),
    fileURL: URL? = nil,
    documentType: TabDocumentType,
    title: String,
    bookmark: Data? = nil,
    dataViewer: DataViewerReference? = nil
  ) {
    self.id = id
    self.fileURL = fileURL
    self.documentType = documentType
    self.title = title
    self.bookmark = bookmark
    self.dataViewer = dataViewer
  }

  /// Bookmark bytes differ between creations of the same file, so equality ignores them
  static func == (lhs: WorkspaceTabReference, rhs: WorkspaceTabReference) -> Bool {
    lhs.id == rhs.id && lhs.fileURL == rhs.fileURL && lhs.documentType == rhs.documentType
      && lhs.title == rhs.title && lhs.dataViewer == rhs.dataViewer
  }

  /// Create from a TabItem
  static func from(
    _ tab: TabItem, bookmark: Data? = nil, dataViewer: DataViewerReference? = nil
  ) -> WorkspaceTabReference {
    WorkspaceTabReference(
      id: tab.id,
      fileURL: tab.fileURL,
      documentType: tab.documentType,
      title: tab.title,
      bookmark: bookmark,
      dataViewer: dataViewer
    )
  }

  /// Convert to TabItem
  func toTabItem(isDirty: Bool = false) -> TabItem {
    TabItem(
      id: id,
      fileURL: fileURL,
      documentType: documentType,
      title: title,
      isDirty: isDirty,
      lastAccessed: Date()
    )
  }
}
