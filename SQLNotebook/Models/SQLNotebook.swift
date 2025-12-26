//
//  SQLNotebook.swift
//  SQLNotebook
//

import Foundation

/// Core document model representing a SQL notebook
struct SQLNotebook: Codable, Identifiable, Sendable {
  let id: UUID
  var cells: [NotebookCell]
  var metadata: NotebookMetadata
  var connectionConfig: ConnectionConfig?

  nonisolated init(
    id: UUID = UUID(),
    cells: [NotebookCell] = [],
    metadata: NotebookMetadata = NotebookMetadata(),
    connectionConfig: ConnectionConfig? = nil
  ) {
    self.id = id
    self.cells = cells
    self.metadata = metadata
    self.connectionConfig = connectionConfig
  }

  /// Creates a new notebook with a default empty SQL cell
  nonisolated static func newDocument() -> SQLNotebook {
    SQLNotebook(
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
