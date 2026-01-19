//
//  SQLNotebookDocument.swift
//  SQLNotebook
//
//  Document wrapper for SQL Notebook files
//
//  NOTE: This file has been split into focused modules:
//  - SQLNotebookDocument+Coding.swift (JSON encoding/decoding)
//

import Combine
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
  nonisolated static var sqlNotebook: UTType {
    UTType(exportedAs: "com.sqlnotebook.document")
  }

  nonisolated static var sql: UTType {
    UTType(importedAs: "public.sql")
  }
}

/// Document wrapper for SQL Notebook files (.sqlnb)
final class SQLNotebookDocument: ReferenceFileDocument, ObservableObject, @unchecked Sendable {
  @Published var notebook: SQLNotebook

  nonisolated static var readableContentTypes: [UTType] {
    [.sqlNotebook, .json]
  }

  var writableContentTypes: [UTType] {
    [.sqlNotebook]
  }

  init(notebook: SQLNotebook = SQLNotebook.newDocument()) {
    self.notebook = notebook
  }

  init(configuration: ReadConfiguration) throws {
    guard let data = configuration.file.regularFileContents else {
      throw CocoaError(.fileReadCorruptFile)
    }

    // JSON format (.sqlnb)
    notebook = try DocumentCoder.decode(from: data)
    // Ensure documentType is .notebook
    notebook.documentType = .notebook
  }

  // Create snapshot for saving
  func snapshot(contentType: UTType) throws -> SQLNotebook {
    var notebookSnapshot = notebook
    notebookSnapshot.metadata.modifiedAt = Date()
    return notebookSnapshot
  }

  nonisolated func fileWrapper(
    snapshot: SQLNotebook, configuration: WriteConfiguration
  ) throws
    -> FileWrapper
  {
    let notebookToSave = snapshot

    // Save as JSON .sqlnb file
    // Access AppSettings in a thread-safe way
    let includeResults = AppSettings.getIncludeResultsOnSave()

    // Use compact format for large files
    let estimatedSize =
      (try? FileOptimizationService.calculateNotebookSize(
        notebookToSave, includeResults: includeResults)) ?? 0
    let useCompactFormat = estimatedSize > FileOptimizationService.warningSizeThreshold

    let data = try DocumentCoder.encode(
      notebookToSave,
      includeResultsOnSave: includeResults,
      useCompactFormat: useCompactFormat
    )
    return FileWrapper(regularFileWithContents: data)
  }
}
