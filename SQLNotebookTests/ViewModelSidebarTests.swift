// ViewModelSidebarTests.swift
// Tests for sidebar, connection state, and notebook metadata

import Foundation
import Testing

@testable import SQLNotebook

@Suite("ViewModel Sidebar Tests")
@MainActor
struct ViewModelSidebarTests {

  // Helper to create a test notebook
  func createTestNotebook() -> SQLNotebook {
    SQLNotebook(
      id: UUID(),
      cells: [
        NotebookCell(
          id: UUID(),
          cellType: .sql,
          content: "SELECT 1;",
          executionCount: 0,
          result: nil
        )
      ],
      metadata: NotebookMetadata(
        createdAt: Date(),
        modifiedAt: Date(),
        title: "Test Notebook"
      ),
      connectionConfig: nil,
      settings: NotebookSettings()
    )
  }

  // MARK: - Sidebar Tests

  @Test("Toggle right sidebar")
  func toggleRightSidebar() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)
    let initialState = viewModel.isRightSidebarVisible

    // Act
    viewModel.toggleSidebar()

    // Assert
    #expect(viewModel.isRightSidebarVisible == !initialState)

    // Act again
    viewModel.toggleSidebar()

    // Assert - Back to initial state
    #expect(viewModel.isRightSidebarVisible == initialState)
  }

  @Test("Toggle left sidebar")
  func toggleLeftSidebar() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)
    let initialState = viewModel.isLeftSidebarVisible

    // Act
    viewModel.toggleLeftSidebar()

    // Assert
    #expect(viewModel.isLeftSidebarVisible == !initialState)
  }

  @Test("Show settings in sidebar")
  func showSettingsInSidebar() {
    // Arrange
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)

    // Act
    viewModel.showSettings()

    // Assert
    #expect(viewModel.isRightSidebarVisible == true)
    #expect(viewModel.rightSidebarContent == .settings)
  }

  // MARK: - Connection State Tests

  @Test("Connection state initially disconnected")
  func connectionStateInitiallyDisconnected() {
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)

    #expect(viewModel.connectionState == .disconnected)
  }

  // MARK: - Notebook Metadata Tests

  @Test("Notebook metadata accessible")
  func notebookMetadataAccessible() {
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)

    #expect(viewModel.notebook.metadata.title == "Test Notebook")
  }

  @Test("Notebook settings accessible")
  func notebookSettings() {
    let notebook = createTestNotebook()
    let viewModel = NotebookViewModel(notebook: notebook)

    // Just verify settings exists and has keyboardShortcuts
    #expect(viewModel.notebook.settings.keyboardShortcuts.isEmpty == true)
  }
}
