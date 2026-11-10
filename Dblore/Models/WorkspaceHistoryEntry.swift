//
//  WorkspaceHistoryEntry.swift
//  Dblore
//

import Foundation

/// Entry for recent workspaces list
nonisolated struct WorkspaceHistoryEntry: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let fileURL: URL
  let name: String
  let connectionDisplayString: String?
  /// Engine name as stored, kept when this build does not know it so a save writes it back
  private var databaseTypeName: String?
  let lastOpenedAt: Date
  let tabCount: Int
  /// App-scope security-scoped bookmark of the .sqlws file (nil in entries saved before bookmarks)
  var bookmark: Data?
  /// Bookmark of the folder containing the .sqlws, re-granting its bookmark-less tab files
  var folderBookmark: Data?
  /// Raw `AccentColor` of the folder icon on the welcome row (nil keeps the default tint)
  var iconColorName: String?
  /// The workspace's files are sealed (Lock Workspace); false in entries saved before Lock
  var isLocked = false

  private enum CodingKeys: String, CodingKey {
    case id, fileURL, name, connectionDisplayString, lastOpenedAt, tabCount
    case databaseTypeName = "databaseType"
    case bookmark, folderBookmark, iconColorName, isLocked
  }

  init(
    id: UUID = UUID(),
    fileURL: URL,
    name: String,
    connectionDisplayString: String? = nil,
    databaseType: DatabaseType? = nil,
    lastOpenedAt: Date = Date(),
    tabCount: Int = 0,
    bookmark: Data? = nil
  ) {
    self.id = id
    self.fileURL = fileURL
    self.name = name
    self.connectionDisplayString = connectionDisplayString
    self.databaseTypeName = databaseType?.rawValue
    self.lastOpenedAt = lastOpenedAt
    self.tabCount = tabCount
    self.bookmark = bookmark
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    fileURL = try container.decode(URL.self, forKey: .fileURL)
    name = try container.decode(String.self, forKey: .name)
    connectionDisplayString = try container.decodeIfPresent(
      String.self, forKey: .connectionDisplayString)
    databaseTypeName = try container.decodeIfPresent(String.self, forKey: .databaseTypeName)
    lastOpenedAt = try container.decode(Date.self, forKey: .lastOpenedAt)
    tabCount = try container.decode(Int.self, forKey: .tabCount)
    bookmark = try container.decodeIfPresent(Data.self, forKey: .bookmark)
    folderBookmark = try container.decodeIfPresent(Data.self, forKey: .folderBookmark)
    isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
  }

  /// Bookmark bytes differ between creations of the same file, so equality ignores them
  static func == (lhs: WorkspaceHistoryEntry, rhs: WorkspaceHistoryEntry) -> Bool {
    lhs.id == rhs.id && lhs.fileURL == rhs.fileURL && lhs.name == rhs.name
      && lhs.connectionDisplayString == rhs.connectionDisplayString
      && lhs.databaseTypeName == rhs.databaseTypeName
      && lhs.lastOpenedAt == rhs.lastOpenedAt && lhs.tabCount == rhs.tabCount
      && lhs.iconColorName == rhs.iconColorName
      && lhs.isLocked == rhs.isLocked
  }

  /// Engine of the workspace connection, badged on the welcome row (nil in older entries and
  /// for an engine this build does not know)
  var databaseType: DatabaseType? {
    databaseTypeName.flatMap(DatabaseType.init(rawValue:))
  }

  /// Color picked for the folder icon; an unknown stored name reads as none
  var iconColor: AccentColor? {
    get { iconColorName.flatMap(AccentColor.init(rawValue:)) }
    set { iconColorName = newValue?.rawValue }
  }

  /// Display string for the welcome screen
  /// Format: "My Project (mydb@localhost:5432)" or just "My Project" if no connection
  var displayString: String {
    if let conn = connectionDisplayString {
      return "\(name) (\(conn))"
    }
    return name
  }

  /// Short display name (just the workspace name)
  var shortDisplayName: String {
    name
  }

  /// Same recent row with a new display name and file location.
  func edited(name: String, fileURL: URL, bookmark: Data?) -> WorkspaceHistoryEntry {
    var edited = WorkspaceHistoryEntry(
      id: id,
      fileURL: fileURL,
      name: name,
      connectionDisplayString: connectionDisplayString,
      databaseType: databaseType,
      lastOpenedAt: lastOpenedAt,
      tabCount: tabCount,
      bookmark: bookmark
    )
    edited.databaseTypeName = databaseTypeName
    edited.folderBookmark = folderBookmark
    edited.iconColorName = iconColorName
    edited.isLocked = isLocked
    return edited
  }

  /// Formatted last opened date
  var formattedLastOpened: String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: lastOpenedAt, relativeTo: Date())
  }

  /// Create from a Workspace
  static func from(_ workspace: Workspace, bookmark: Data? = nil) -> WorkspaceHistoryEntry? {
    guard let fileURL = workspace.fileURL else { return nil }
    return WorkspaceHistoryEntry(
      id: workspace.id,
      fileURL: fileURL,
      name: workspace.name,
      connectionDisplayString: workspace.connectionConfig?.displayString,
      databaseType: workspace.connectionConfig?.databaseType,
      lastOpenedAt: workspace.lastOpenedAt,
      tabCount: workspace.tabs.count,
      bookmark: bookmark
    )
  }

  /// Reads a stored list entry by entry: `entries` are those this build reads, `unreadable` the
  /// others as stored, so one bad entry never empties the list
  static func decodeList(
    _ data: Data?
  ) -> (entries: [WorkspaceHistoryEntry], unreadable: [JSONValue]) {
    guard let data, let stored = try? JSONDecoder().decode([StoredEntry].self, from: data) else {
      return ([], [])
    }
    var entries: [WorkspaceHistoryEntry] = []
    var unreadable: [JSONValue] = []
    for item in stored {
      switch item {
      case .entry(let entry): entries.append(entry)
      case .unreadable(let value): unreadable.append(value)
      }
    }
    return (entries, unreadable)
  }

  /// `entries` followed by the entries of `stored` this build cannot read, so a save never
  /// drops them
  static func encodeList(
    _ entries: [WorkspaceHistoryEntry], keepingUnreadableOf stored: Data?
  ) -> Data? {
    let kept = decodeList(stored).unreadable.map(StoredEntry.unreadable)
    return try? JSONEncoder().encode(entries.map(StoredEntry.entry) + kept)
  }

  /// One element of a stored list: an entry, or the JSON of one this build cannot read
  private nonisolated enum StoredEntry: Codable {
    case entry(WorkspaceHistoryEntry)
    case unreadable(JSONValue)

    init(from decoder: Decoder) throws {
      let container = try decoder.singleValueContainer()
      if let entry = try? container.decode(WorkspaceHistoryEntry.self) {
        self = .entry(entry)
      } else {
        self = .unreadable(try container.decode(JSONValue.self))
      }
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.singleValueContainer()
      switch self {
      case .entry(let entry): try container.encode(entry)
      case .unreadable(let value): try container.encode(value)
      }
    }
  }
}
