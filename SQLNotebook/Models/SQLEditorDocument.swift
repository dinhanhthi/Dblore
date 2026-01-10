//
//  SQLEditorDocument.swift
//  SQLNotebook
//

import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Document for SQL editor mode - handles plain .sql files
final class SQLEditorDocument: ReferenceFileDocument, ObservableObject, @unchecked Sendable {
  @Published var content: String
  @Published var metadata: NotebookMetadata

  nonisolated static var readableContentTypes: [UTType] {
    [.sql, .plainText]
  }

  nonisolated var writableContentTypes: [UTType] {
    [.sql]
  }

  init(content: String = "", metadata: NotebookMetadata = NotebookMetadata(title: "Untitled")) {
    self.content = content
    self.metadata = metadata
  }

  init(configuration: ReadConfiguration) throws {
    guard let data = configuration.file.regularFileContents,
          let sqlContent = String(data: data, encoding: .utf8) else {
      throw CocoaError(.fileReadCorruptFile)
    }

    self.content = sqlContent

    // Extract filename for title
    let filename = configuration.file.filename ?? "Untitled"
    let title = (filename as NSString).deletingPathExtension
    self.metadata = NotebookMetadata(title: title)
  }

  func snapshot(contentType: UTType) throws -> String {
    // Return current content for saving
    return content
  }

  nonisolated func fileWrapper(snapshot: String, configuration: WriteConfiguration) throws -> FileWrapper {
    guard let data = snapshot.data(using: .utf8) else {
      throw CocoaError(.fileWriteUnknown)
    }

    return FileWrapper(regularFileWithContents: data)
  }
}
