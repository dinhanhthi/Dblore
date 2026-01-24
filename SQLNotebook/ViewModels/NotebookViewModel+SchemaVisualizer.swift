//
//  NotebookViewModel+SchemaVisualizer.swift
//  SQLNotebook
//
//  Schema visualizer state and methods
//

import CoreGraphics
import Foundation

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
}
