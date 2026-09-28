//
//  TabItem.swift
//  SQLNotebook
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

  init(
    id: UUID = UUID(),
    fileURL: URL? = nil,
    documentType: TabDocumentType,
    title: String,
    isDirty: Bool = false,
    lastAccessed: Date = Date(),
    isPreview: Bool = false
  ) {
    self.id = id
    self.fileURL = fileURL
    self.documentType = documentType
    self.title = title
    self.isDirty = isDirty
    self.lastAccessed = lastAccessed
    self.isPreview = isPreview
  }

  /// Creates a new untitled notebook tab
  static func newNotebook() -> TabItem {
    TabItem(
      documentType: .notebook,
      title: "Untitled.sqlnb",
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
}

/// The type of document in a tab
enum TabDocumentType: String, Codable, Equatable {
  case notebook  // .sqlnb files
  case sqlFile  // .sql files
  case dataViewer  // table/view data viewer, no file

  var fileExtension: String {
    switch self {
    case .notebook: return "sqlnb"
    case .sqlFile: return "sql"
    case .dataViewer: return ""
    }
  }

  var icon: String {
    switch self {
    case .notebook: return "doc.text"
    case .sqlFile: return "doc"
    case .dataViewer: return "tablecells"
    }
  }

  /// Detect document type from file URL
  static func from(url: URL) -> TabDocumentType? {
    switch url.pathExtension.lowercased() {
    case "sqlnb": return .notebook
    case "sql": return .sqlFile
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
  }
}
