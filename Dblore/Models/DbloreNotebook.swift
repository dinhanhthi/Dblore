//
//  DbloreNotebook.swift
//  Dblore
//

import Foundation

/// Document type for SQL files
enum DocumentType: String, Codable, Sendable {
  case notebook  // .dblore - JSON format with multiple cells
  case script  // .sql - Plain text format for editor mode
}

/// Core document model representing a SQL notebook
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
