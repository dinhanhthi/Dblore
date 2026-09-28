// DataViewerTabTests.swift
// Table/view data viewer tabs: a preview tab is reused by the next table, pinned tabs and the
// transaction origin are kept, and viewer tabs are never dirty, persisted or reopened.
// Disconnected manager: page loads return early.

import Foundation
import Testing

@testable import SQLNotebook

@Suite("Data viewer tab")
@MainActor
struct DataViewerTabTests {
  private static func manager() -> WorkspaceManager {
    WorkspaceManager(workspace: Workspace(), restoreTabs: false)
  }

  @Test("First open adds one active preview tab titled with the table")
  func firstOpen() throws {
    let manager = Self.manager()
    manager.openDataViewer(schema: "public", name: "users", orderColumns: ["id"])

    #expect(manager.tabs.count == 1)
    let tab = try #require(manager.tabs.first)
    #expect(tab.documentType == .dataViewer)
    #expect(tab.isPreview)
    #expect(tab.title == "users")
    #expect(tab.fileURL == nil)
    #expect(manager.activeTabId == tab.id)
    let viewModel = try #require(manager.viewModel(for: tab.id))
    #expect(viewModel.dataViewer?.name == "users")
    #expect(viewModel.dataViewer?.orderColumns == ["id"])
  }

  @Test("Opening another table replaces the preview tab")
  func replacesPreview() throws {
    let manager = Self.manager()
    manager.openDataViewer(schema: "public", name: "users", orderColumns: [])
    let id = try #require(manager.tabs.first?.id)

    manager.openDataViewer(schema: "public", name: "orders", orderColumns: [])
    #expect(manager.tabs.count == 1)
    #expect(manager.tabs.first?.id == id)
    #expect(manager.tabs.first?.title == "orders")
    #expect(manager.viewModel(for: id)?.dataViewer?.name == "orders")
    #expect(manager.activeTabId == id)
  }

  @Test("Opening a table already shown selects its tab")
  func reopenSelectsExisting() throws {
    let manager = Self.manager()
    manager.openDataViewer(schema: "public", name: "users", orderColumns: [])
    let viewerId = try #require(manager.tabs.first?.id)
    let sqlId = manager.newSQLFile()
    #expect(manager.activeTabId == sqlId)

    manager.openDataViewer(schema: "public", name: "users", orderColumns: [])
    #expect(manager.tabs.count == 2)
    #expect(manager.activeTabId == viewerId)
  }

  @Test("A pinned tab is kept and the next table opens a new preview")
  func pinnedTabIsKept() throws {
    let manager = Self.manager()
    manager.openDataViewer(schema: "public", name: "users", orderColumns: [])
    let pinnedId = try #require(manager.tabs.first?.id)
    manager.pinTab(id: pinnedId)
    #expect(manager.tabs.first?.isPreview == false)

    manager.openDataViewer(schema: "public", name: "orders", orderColumns: [])
    #expect(manager.tabs.count == 2)
    #expect(manager.tabs[0].title == "users")
    #expect(manager.tabs[1].title == "orders")
    #expect(manager.tabs[1].isPreview)
    #expect(manager.activeTabId == manager.tabs[1].id)
  }

  @Test("The transaction origin preview is pinned instead of replaced")
  func transactionOriginIsPinned() throws {
    let manager = Self.manager()
    manager.openDataViewer(schema: "public", name: "users", orderColumns: [])
    let originId = try #require(manager.tabs.first?.id)
    manager.transactionOriginTabId = originId

    manager.openDataViewer(schema: "public", name: "orders", orderColumns: [])
    #expect(manager.tabs.count == 2)
    #expect(manager.tabs[0].id == originId)
    #expect(manager.tabs[0].isPreview == false)
    #expect(manager.viewModel(for: originId)?.dataViewer?.name == "users")
    #expect(manager.tabs[1].isPreview)
    #expect(manager.tabs[1].title == "orders")
  }

  @Test("Save and markDirty leave a data viewer clean and file-less")
  func neverDirty() async throws {
    let manager = Self.manager()
    manager.openDataViewer(schema: "public", name: "users", orderColumns: [])
    let id = try #require(manager.tabs.first?.id)

    manager.markDirty(tabId: id)
    #expect(manager.tabs.first?.isDirty == false)
    try await manager.saveTab(id: id)
    #expect(manager.tabs.first?.fileURL == nil)
    #expect(manager.tabs.first?.isDirty == false)
  }

  @Test("Encoded workspace drops data viewers and points at a persisted tab")
  func persistenceDropsViewers() throws {
    let manager = Self.manager()
    let sqlId = manager.newSQLFile()
    manager.openDataViewer(schema: "public", name: "users", orderColumns: [])
    #expect(manager.activeTabId != sqlId)

    let workspace = try Self.decode(manager.encodedWorkspaceData())
    #expect(workspace.tabs.map(\.id) == [sqlId])
    #expect(workspace.activeTabId == sqlId)
  }

  @Test("Encoded workspace with only a data viewer has no tabs and no active tab")
  func persistenceOnlyViewer() throws {
    let manager = Self.manager()
    manager.openDataViewer(schema: "public", name: "users", orderColumns: [])

    let workspace = try Self.decode(manager.encodedWorkspaceData())
    #expect(workspace.tabs.isEmpty)
    #expect(workspace.activeTabId == nil)
  }

  @Test("A closed data viewer cannot be reopened")
  func closedViewerNotReopenable() throws {
    let manager = Self.manager()
    manager.openDataViewer(schema: "public", name: "users", orderColumns: [])
    let id = try #require(manager.tabs.first?.id)

    manager.requestCloseTab(id: id)
    #expect(manager.tabs.isEmpty)
    #expect(!manager.showingCloseConfirmation)
    #expect(!manager.canReopenClosedTab)
  }

  @Test("A non-public schema is part of the title")
  func schemaInTitle() {
    let manager = Self.manager()
    manager.openDataViewer(schema: "sales", name: "orders", orderColumns: [])
    #expect(manager.tabs.first?.title == "sales.orders")
  }

  private static func decode(_ data: Data) throws -> Workspace {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(Workspace.self, from: data)
  }
}
