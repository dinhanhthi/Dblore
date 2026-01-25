//
//  NotebookViewModel+SchemaVisualizer.swift
//  SQLNotebook
//
//  Schema visualizer state and methods
//

import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

// MARK: - Schema Visualizer

extension NotebookViewModel {
  // Note: State properties are declared in NotebookViewModel.swift
  // - schemaGraph: SchemaGraph?
  // - visualizerScale: CGFloat
  // - visualizerOffset: CGPoint
  // - selectedGraphNodeId: UUID?

  /// Show the schema visualizer in the main body (replaces cells/editor content)
  func showSchemaVisualizer() {
    isSchemaVisualizerActive = true

    // Load graph if not already loaded
    if schemaGraph == nil {
      Task {
        await loadSchemaGraph()
      }
    }
  }

  /// Hide the schema visualizer and return to normal view
  func hideSchemaVisualizer() {
    isSchemaVisualizerActive = false
  }

  /// Toggle the schema visualizer
  func toggleSchemaVisualizer() {
    if isSchemaVisualizerActive {
      hideSchemaVisualizer()
    } else {
      showSchemaVisualizer()
    }
  }

  /// Get connection key for storing positions
  private var connectionKey: String? {
    guard let config = notebook.connectionConfig else { return nil }
    return SchemaPositionsStore.connectionKey(from: config)
  }

  /// Load and calculate the schema graph layout
  func loadSchemaGraph() async {
    guard connectionState.isConnected else {
      schemaGraph = nil
      return
    }

    isLoadingSchemaGraph = true

    // Build graph from existing data
    let layoutEngine = SchemaLayoutEngine()

    // Calculate canvas size based on number of tables
    let tableCount = databaseTables.count
    let canvasWidth = max(800, CGFloat(tableCount) * 100)
    let canvasHeight = max(600, CGFloat(tableCount) * 80)
    let canvasSize = CGSize(width: canvasWidth, height: canvasHeight)

    // Calculate layout
    var graph = layoutEngine.calculateLayout(
      tables: databaseTables,
      foreignKeys: databaseForeignKeys,
      canvasSize: canvasSize
    )

    // Restore saved positions if available from local storage
    if let key = connectionKey {
      let savedPositions = SchemaPositionsStore.loadPositions(forConnection: key)
      if !savedPositions.isEmpty {
        graph.applyPositions(savedPositions)
      }
    }

    schemaGraph = graph

    // Reset view state
    visualizerScale = 1.0
    visualizerOffset = .zero
    selectedGraphNodeId = nil

    isLoadingSchemaGraph = false
  }

  /// Save current schema node positions to local storage
  func saveSchemaNodePositions() {
    guard let graph = schemaGraph,
      let key = connectionKey
    else { return }

    let positions = graph.exportPositions()
    SchemaPositionsStore.savePositions(positions, forConnection: key)
  }

  /// Reset schema layout to default (recalculate positions)
  func resetSchemaLayout() async {
    guard connectionState.isConnected else { return }

    isLoadingSchemaGraph = true

    // Clear saved positions from local storage
    if let key = connectionKey {
      SchemaPositionsStore.clearPositions(forConnection: key)
    }

    // Recalculate layout
    let layoutEngine = SchemaLayoutEngine()
    let tableCount = databaseTables.count
    let canvasWidth = max(800, CGFloat(tableCount) * 100)
    let canvasHeight = max(600, CGFloat(tableCount) * 80)
    let canvasSize = CGSize(width: canvasWidth, height: canvasHeight)

    schemaGraph = layoutEngine.calculateLayout(
      tables: databaseTables,
      foreignKeys: databaseForeignKeys,
      canvasSize: canvasSize
    )

    // Reset view state
    visualizerScale = 1.0
    visualizerOffset = .zero
    selectedGraphNodeId = nil

    isLoadingSchemaGraph = false
  }

  /// Select a node in the graph
  func selectGraphNode(_ nodeId: UUID?) {
    selectedGraphNodeId = nodeId
  }

  /// Reset the visualizer view (zoom and position)
  func resetVisualizerView() {
    visualizerScale = 1.0
    visualizerOffset = .zero
  }

  /// Zoom in the visualizer
  func zoomInVisualizer() {
    visualizerScale = min(3.0, visualizerScale * 1.25)
  }

  /// Zoom out the visualizer
  func zoomOutVisualizer() {
    visualizerScale = max(0.25, visualizerScale / 1.25)
  }

  /// Refresh the schema graph
  func refreshSchemaGraph() async {
    // Reload schema data first
    await loadDatabaseSchema()
    // Then rebuild graph
    await loadSchemaGraph()
  }

  /// Export the schema graph as a PNG image
  /// Opens a save panel for the user to choose the save location
  func exportSchemaAsImage() {
    guard let nsView = schemaGraphNSView else {
      showToast("Cannot export: Schema view not available", type: .error)
      return
    }

    // Ask user about background preference
    let alert = NSAlert()
    alert.messageText = "Export Background"
    alert.informativeText = "Do you want to include the background in the exported image?"
    alert.addButton(withTitle: "With Background")
    alert.addButton(withTitle: "Transparent")
    alert.addButton(withTitle: "Cancel")

    let response = alert.runModal()

    if response == .alertThirdButtonReturn {
      return  // User cancelled
    }

    let includeBackground = response == .alertFirstButtonReturn

    guard let image = nsView.renderToImage(padding: 40, includeBackground: includeBackground) else {
      showToast("Cannot export: No schema to export", type: .error)
      return
    }

    // Convert NSImage to PNG data
    guard let tiffData = image.tiffRepresentation,
      let bitmapRep = NSBitmapImageRep(data: tiffData),
      let pngData = bitmapRep.representation(using: .png, properties: [:])
    else {
      showToast("Failed to create PNG image", type: .error)
      return
    }

    // Create save panel
    let savePanel = NSSavePanel()
    savePanel.title = "Export Schema as PNG"
    savePanel.nameFieldStringValue = "schema"
    savePanel.allowedContentTypes = [UTType.png]
    savePanel.canCreateDirectories = true

    savePanel.begin { [weak self] response in
      guard response == .OK, let url = savePanel.url else { return }

      do {
        try pngData.write(to: url)
        Task { @MainActor in
          self?.showToast("Schema exported successfully", type: .success)
        }
      } catch {
        Task { @MainActor in
          self?.showToast("Failed to save image: \(error.localizedDescription)", type: .error)
        }
      }
    }
  }
}
