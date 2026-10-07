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

  init(
    id: UUID = UUID(),
    fileURL: URL? = nil,
    documentType: TabDocumentType,
    title: String,
    isDirty: Bool = false,
    lastAccessed: Date = Date(),
    isPreview: Bool = false,
    isPinned: Bool = false
  ) {
    self.id = id
    self.fileURL = fileURL
    self.documentType = documentType
    self.title = title
    self.isDirty = isDirty
    self.lastAccessed = lastAccessed
    self.isPreview = isPreview
    self.isPinned = isPinned
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

// MARK: - Codable for persistence

extension TabItem: Codable {
  enum CodingKeys: String, CodingKey {
    case id, fileURL, documentType, title, isDirty, lastAccessed
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
  }
}
