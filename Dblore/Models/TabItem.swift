//
//  TabItem.swift
//  Dblore
//

import Foundation

/// Represents a single tab in the tab bar.
/// Each tab holds reference to a document (notebook or SQL file) with its own state.
struct TabItem: Identifiable, Equatable {
  let id: UUID
  var fileURL: URL?
  var documentType: TabDocumentType
  var title: String
  var isDirty: Bool
  var lastAccessed: Date
  /// Session-only preview state (italic title, replaced by the next preview); never persisted
  var isPreview: Bool
  /// Pinned tabs form the leading zone of the tab bar and persist in the workspace
  var isPinned: Bool
  /// Read-only routine or trigger source on a .sqlFile tab: never dirty, never saved, and
  /// rebuilt on demand rather than persisted or restored at launch
  var objectSource: ObjectSourceRef?

  var isReadOnlySource: Bool { objectSource != nil }

  init(
    id: UUID = UUID(),
    fileURL: URL? = nil,
    documentType: TabDocumentType,
    title: String,
    isDirty: Bool = false,
    lastAccessed: Date = Date(),
    isPreview: Bool = false,
    isPinned: Bool = false,
    objectSource: ObjectSourceRef? = nil
  ) {
    self.id = id
    self.fileURL = fileURL
    self.documentType = documentType
    self.title = title
    self.isDirty = isDirty
    self.lastAccessed = lastAccessed
    self.isPreview = isPreview
    self.isPinned = isPinned
    self.objectSource = objectSource
  }

  /// Creates a new untitled notebook tab
  static func newNotebook() -> TabItem {
    TabItem(
      documentType: .notebook,
      title: "Untitled.dblore",
      isDirty: true  // New files are unsaved
    )
  }

  /// Creates a new untitled SQL file tab
  static func newSQLFile() -> TabItem {
    TabItem(
      documentType: .sqlFile,
      title: "Untitled.sql",
      isDirty: true  // New files are unsaved
    )
  }

  /// Creates a new untitled Markdown note tab
  static func newMarkdownFile() -> TabItem {
    TabItem(
      documentType: .markdown,
      title: "Untitled.md",
      isDirty: true  // New files are unsaved
    )
  }
}

/// The type of document in a tab
enum TabDocumentType: String, Codable, Equatable {
  case notebook  // .dblore files
  case sqlFile  // .sql files
  case dataViewer  // table/view data viewer, no file
  case markdown  // .md files

  var fileExtension: String {
    switch self {
    case .notebook: return "dblore"
    case .sqlFile: return "sql"
    case .dataViewer: return ""
    case .markdown: return "md"
    }
  }

  var icon: String {
    switch self {
    case .notebook: return "doc.text"
    case .sqlFile: return "doc"
    case .dataViewer: return "tablecells"
    case .markdown: return "doc.richtext"
    }
  }

  /// Detect document type from file URL
  static func from(url: URL) -> TabDocumentType? {
    switch url.pathExtension.lowercased() {
    case "dblore": return .notebook
    case "sql": return .sqlFile
    case "md": return .markdown
    default: return nil
    }
  }
}

/// Identifies the routine or trigger whose definition an object source tab shows
nonisolated struct ObjectSourceRef: Codable, Hashable, Sendable {
  enum Kind: String, Codable, Hashable, Sendable {
    case function, procedure, trigger
  }

  var kind: Kind
  var schema: String
  var name: String
  /// Owning table (triggers)
  var table: String?
  /// Argument list (functions and procedures), labels overloads
  var arguments: String?
  /// Catalog oid. Nil on SQLite.
  var oid: UInt32?

  init(
    kind: Kind, schema: String, name: String, table: String? = nil, arguments: String? = nil,
    oid: UInt32? = nil
  ) {
    self.kind = kind
    self.schema = schema
    self.name = name
    self.table = table
    self.arguments = arguments
    self.oid = oid
  }

  /// Finds an open tab for the same object: the oid when present, otherwise the qualified name
  var key: String {
    if let oid { return "\(kind.rawValue):oid:\(oid)" }
    return "\(kind.rawValue):\(schema).\(table ?? "").\(name)"
  }

  /// "name(args)" for routines, "name on table" for triggers
  var title: String {
    switch kind {
    case .function, .procedure:
      return "\(name)(\(arguments ?? ""))"
    case .trigger:
      guard let table, !table.isEmpty else { return name }
      return "\(name) on \(table)"
    }
  }
}

// MARK: - Codable for persistence

extension TabItem: Codable {
  enum CodingKeys: String, CodingKey {
    case id, fileURL, documentType, title, isDirty, lastAccessed, objectSource
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    fileURL = try container.decodeIfPresent(URL.self, forKey: .fileURL)
    documentType = try container.decode(TabDocumentType.self, forKey: .documentType)
    title = try container.decode(String.self, forKey: .title)
    isDirty = try container.decodeIfPresent(Bool.self, forKey: .isDirty) ?? false
    lastAccessed = try container.decodeIfPresent(Date.self, forKey: .lastAccessed) ?? Date()
    isPreview = false
    isPinned = false
    objectSource = try container.decodeIfPresent(ObjectSourceRef.self, forKey: .objectSource)
  }
}
