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

  nonisolated init(content: String = "", metadata: NotebookMetadata = NotebookMetadata(title: "Untitled")) {
    self.content = content
    self.metadata = metadata
  }

  nonisolated init(configuration: ReadConfiguration) throws {
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
    print("📸 [SQLEditorDocument] snapshot() called - content length: \(content.count)")
    print("📸 [SQLEditorDocument] content preview: \(String(content.prefix(100)))")
    return content
  }

  nonisolated func fileWrapper(snapshot: String, configuration: WriteConfiguration) throws -> FileWrapper {
    print("💾 [SQLEditorDocument] fileWrapper() called - snapshot length: \(snapshot.count)")
    print("💾 [SQLEditorDocument] snapshot preview: \(String(snapshot.prefix(100)))")

    guard let data = snapshot.data(using: .utf8) else {
      print("❌ [SQLEditorDocument] Failed to convert snapshot to UTF-8 data")
      throw CocoaError(.fileWriteUnknown)
    }

    print("✅ [SQLEditorDocument] Successfully created FileWrapper with \(data.count) bytes")
    return FileWrapper(regularFileWithContents: data)
  }
}
