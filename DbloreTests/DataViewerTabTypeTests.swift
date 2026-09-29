// DataViewerTabTypeTests.swift
// The `.dataViewer` tab type has no file: it is never detected from a URL, and its session-only
// `isPreview` flag is never encoded. Saving a data viewer tab is a no-op.

import Foundation
import Testing

@testable import Dblore

@Suite("Data viewer tab type")
@MainActor
struct DataViewerTabTypeTests {
  @Test("Has no file extension and a table icon")
  func extensionAndIcon() {
    #expect(TabDocumentType.dataViewer.fileExtension == "")
    #expect(TabDocumentType.dataViewer.icon == "tablecells")
  }

  @Test("Is never detected from a file URL")
  func neverFromURL() {
    for name in ["a.dblore", "a.sql", "a", "a.dataViewer", "a.txt"] {
      #expect(TabDocumentType.from(url: URL(fileURLWithPath: "/tmp/\(name)")) != .dataViewer)
    }
  }

  @Test("isPreview is never encoded and decodes as false")
  func isPreviewNotPersisted() throws {
    let tab = TabItem(documentType: .sqlFile, title: "users", isPreview: true)
    #expect(tab.isPreview)

    let data = try JSONEncoder().encode(tab)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["isPreview"] == nil)

    let decoded = try JSONDecoder().decode(TabItem.self, from: data)
    #expect(!decoded.isPreview)
  }

  @Test("dataViewer document type round-trips through Codable")
  func documentTypeRoundTrip() throws {
    let tab = TabItem(documentType: .dataViewer, title: "users")
    let data = try JSONEncoder().encode(tab)
    let decoded = try JSONDecoder().decode(TabItem.self, from: data)
    #expect(decoded.documentType == .dataViewer)
  }

  @Test("Saving a data viewer tab is a no-op")
  func saveIsNoOp() async throws {
    let manager = WorkspaceManager(workspace: Workspace(), restoreTabs: false)
    let tab = TabItem(documentType: .dataViewer, title: "users", isPreview: true)
    manager.tabs.append(tab)

    try await manager.saveTab(id: tab.id)

    let saved = try #require(manager.tabs.first(where: { $0.id == tab.id }))
    #expect(saved.fileURL == nil)
    #expect(saved.title == "users")
  }
}
