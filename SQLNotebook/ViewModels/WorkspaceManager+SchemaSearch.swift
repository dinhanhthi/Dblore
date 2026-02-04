//
//  WorkspaceManager+SchemaSearch.swift
//  SQLNotebook
//
//  Schema search functionality for workspace-level schema visualizer
//

import AppKit
import Foundation
import SwiftUI

// MARK: - Schema Search

extension WorkspaceManager {
  /// Perform search across all schema nodes (tables and columns)
  @MainActor
  func performSchemaSearch(query: String, caseSensitive: Bool) async {
    schemaSearchState.isSearching = true
    schemaSearchState.query = query
    schemaSearchState.isCaseSensitive = caseSensitive
    schemaSearchState.matches = []
    schemaSearchState.currentMatchIndex = 0

    guard !query.isEmpty, let graph = schemaGraph else {
      schemaSearchState.isSearching = false
      return
    }

    // Build search matches
    var matches: [SchemaSearchMatch] = []

    for node in graph.nodes {
      // Search in table name - use node.table.name which is what gets drawn
      let qualifiedName = "\(node.table.schema).\(node.table.name)"
      let displayedTableName = node.table.name
      let searchOptions: String.CompareOptions = caseSensitive ? [] : .caseInsensitive

      // Search in the displayed table name (what's actually drawn on screen)
      if let range = displayedTableName.range(of: query, options: searchOptions) {
        matches.append(
          SchemaSearchMatch(
            nodeId: node.id,
            tableName: qualifiedName,
            matchType: .tableName,
            matchedText: displayedTableName,
            matchRange: range
          )
        )
      }

      // Search in column names (use original text for range)
      for (columnIndex, column) in node.table.columns.enumerated() {
        if let range = column.name.range(of: query, options: searchOptions) {
          matches.append(
            SchemaSearchMatch(
              nodeId: node.id,
              tableName: qualifiedName,
              matchType: .columnName(columnIndex: columnIndex),
              matchedText: column.name,
              matchRange: range
            )
          )
        }
      }
    }

    schemaSearchState.matches = matches
    schemaSearchState.isSearching = false

    // Auto-navigate to first match
    if !matches.isEmpty {
      navigateToSchemaMatch(at: 0)
    }
  }

  /// Navigate to next schema match
  @MainActor
  func navigateToNextSchemaMatch() {
    guard !schemaSearchState.matches.isEmpty else { return }

    let newIndex = (schemaSearchState.currentMatchIndex + 1) % schemaSearchState.matches.count
    navigateToSchemaMatch(at: newIndex)
  }

  /// Navigate to previous schema match
  @MainActor
  func navigateToPreviousSchemaMatch() {
    guard !schemaSearchState.matches.isEmpty else { return }

    let newIndex =
      schemaSearchState.currentMatchIndex == 0
      ? schemaSearchState.matches.count - 1
      : schemaSearchState.currentMatchIndex - 1
    navigateToSchemaMatch(at: newIndex)
  }

  /// Navigate to specific schema match index
  @MainActor
  private func navigateToSchemaMatch(at index: Int) {
    guard index >= 0, index < schemaSearchState.matches.count else { return }

    schemaSearchState.currentMatchIndex = index
    let match = schemaSearchState.matches[index]

    // Select the node
    selectedGraphNodeId = match.nodeId

    // Scroll to the node
    scrollToSchemaNode(nodeId: match.nodeId)
  }

  /// Scroll the schema canvas to center on a specific node
  @MainActor
  func scrollToSchemaNode(nodeId: UUID) {
    guard let graph = schemaGraph,
      let node = graph.nodes.first(where: { $0.id == nodeId }),
      let nsView = schemaGraphNSView
    else { return }

    // Get node center position in canvas coordinates
    // Use default width of 200 if custom width not set
    let nodeWidth = node.width ?? 200
    let nodeCenter = CGPoint(
      x: node.position.x + nodeWidth / 2,
      y: node.position.y + 50  // Approximate node height center
    )

    // Calculate the offset to center the node in the view
    let viewBounds = nsView.bounds
    let viewCenter = CGPoint(x: viewBounds.width / 2, y: viewBounds.height / 2)

    // Calculate new offset to center the node
    let newOffset = CGPoint(
      x: viewCenter.x - nodeCenter.x * visualizerScale,
      y: viewCenter.y - nodeCenter.y * visualizerScale
    )

    // Animate to new position
    withAnimation(.easeInOut(duration: 0.3)) {
      visualizerOffset = newOffset
    }
  }

  /// Open schema search panel
  @MainActor
  func openSchemaSearch() {
    if isSchemaSearchPanelVisible {
      // Re-focus search field if already visible
      schemaSearchFocusTrigger = UUID()
    } else {
      isSchemaSearchPanelVisible = true
    }
  }

  /// Close schema search panel
  @MainActor
  func closeSchemaSearch() {
    isSchemaSearchPanelVisible = false
    schemaSearchState = SchemaSearchState()
    selectedGraphNodeId = nil
  }
}
