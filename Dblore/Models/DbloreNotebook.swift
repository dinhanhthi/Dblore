//
//  DbloreNotebook.swift
//  Dblore
//

import Foundation

/// Document type for notebook and query files
enum DocumentType: String, Codable, Sendable {
  case notebook  // .dblore - JSON format with multiple cells
  case script  // .sql - Plain text format for editor mode
}

/// Core document model representing a notebook
struct DbloreNotebook: Codable, Identifiable, Sendable {
  let id: UUID
  var cells: [NotebookCell]
  var metadata: NotebookMetadata
  var connectionConfig: ConnectionConfig?
  var settings: NotebookSettings
  var documentType: DocumentType  // Track document type for save format

  nonisolated init(
    id: UUID = UUID(),
    cells: [NotebookCell] = [],
    metadata: NotebookMetadata = NotebookMetadata(),
    connectionConfig: ConnectionConfig? = nil,
    settings: NotebookSettings = NotebookSettings(),
    documentType: DocumentType = .notebook
  ) {
    self.id = id
    self.cells = cells
    self.metadata = metadata
    self.connectionConfig = connectionConfig
    self.settings = settings
    self.documentType = documentType
  }

  private enum CodingKeys: String, CodingKey {
    case id, cells, metadata, connectionConfig, settings, documentType
  }

  nonisolated init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    cells = try container.decode([NotebookCell].self, forKey: .cells)
    metadata = try container.decode(NotebookMetadata.self, forKey: .metadata)
    connectionConfig = try container.decodeIfPresent(
      ConnectionConfig.self, forKey: .connectionConfig)
    settings = try container.decode(NotebookSettings.self, forKey: .settings)
    documentType = try container.decode(DocumentType.self, forKey: .documentType)
  }

  nonisolated func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(cells, forKey: .cells)
    try container.encode(metadata, forKey: .metadata)
    try container.encodeIfPresent(connectionConfig, forKey: .connectionConfig)
    try container.encode(settings, forKey: .settings)
    try container.encode(documentType, forKey: .documentType)
  }

  /// Creates a new notebook with a default empty SQL cell
  nonisolated static func newDocument() -> DbloreNotebook {
    DbloreNotebook(
      cells: [NotebookCell(cellType: .sql, content: "")]
    )
  }
}

/// Metadata about the notebook document
struct NotebookMetadata: Codable, Sendable {
  var createdAt: Date
  var modifiedAt: Date
  var title: String

  nonisolated init(
    createdAt: Date = Date(),
    modifiedAt: Date = Date(),
    title: String = "Untitled Notebook"
  ) {
    self.createdAt = createdAt
    self.modifiedAt = modifiedAt
    self.title = title
  }
}
