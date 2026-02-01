//
//  WorkspaceSchemaVisualizerContent.swift
//  SQLNotebook
//
//  Schema visualizer content for workspace level (when no tabs are open)
//

import SwiftUI

/// Schema visualizer view for workspace level - used when no tabs are open
struct WorkspaceSchemaVisualizerContent: View {
  @Bindable var workspaceManager: WorkspaceManager

  var body: some View {
    VStack(spacing: 0) {
      // Header with controls
      schemaVisualizerHeader

      // Graph content
      graphContent
    }
    .background(Color.appBackground)
  }

  // MARK: - Header

  private var schemaVisualizerHeader: some View {
    HStack(spacing: Spacing.sm) {
      // Back button
      Button(action: { workspaceManager.hideSchemaVisualizer() }) {
        Label("Back", systemImage: "chevron.left")
      }
      .buttonStyle(GhostButtonStyle())
      .help("Close Schema Visualizer")

      Divider()
        .frame(height: 20)

      // Zoom controls grouped together
      HStack(spacing: 0) {
        Button(action: { workspaceManager.zoomOutVisualizer() }) {
          Image(systemName: "minus.magnifyingglass")
        }
        .buttonStyle(GhostButtonStyle(iconOnly: true))
        .help("Zoom Out")

        Text("\(Int(workspaceManager.visualizerScale * 100))%")
          .font(.monoSmall)
          .foregroundColor(.foregroundMuted)
          .frame(width: 45)

        Button(action: { workspaceManager.zoomInVisualizer() }) {
          Image(systemName: "plus.magnifyingglass")
        }
        .buttonStyle(GhostButtonStyle(iconOnly: true))
        .help("Zoom In")
      }
      .padding(.horizontal, Spacing.xs)
      .padding(.vertical, Spacing.xxs)
      .background(
        RoundedRectangle(cornerRadius: CornerRadius.md)
          .fill(Color.inputBackground)
      )

      Divider()
        .frame(height: 20)

      // Reset view button
      Button(action: { workspaceManager.resetVisualizerView() }) {
        Image(systemName: "arrow.counterclockwise")
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .help("Reset View")

      // Reset layout button
      Button(action: {
        Task {
          await workspaceManager.resetSchemaLayout()
        }
      }) {
        Image(systemName: "rectangle.3.group")
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .help("Reset Layout to Default")
      .disabled(workspaceManager.isLoadingSchemaGraph)

      // Toggle table connection lines (ER diagram lines)
      Button(action: { workspaceManager.showTableConnections.toggle() }) {
        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
      }
      .buttonStyle(
        GhostButtonStyle(isActive: workspaceManager.showTableConnections, iconOnly: true)
      )
      .help(
        workspaceManager.showTableConnections
          ? "Hide Table Connections" : "Show Table Connections")

      // Toggle column connection lines
      Button(action: { workspaceManager.showColumnConnections.toggle() }) {
        Image(systemName: "arrow.triangle.branch")
      }
      .buttonStyle(
        GhostButtonStyle(isActive: workspaceManager.showColumnConnections, iconOnly: true)
      )
      .help(
        workspaceManager.showColumnConnections
          ? "Hide Column Connections" : "Show Column Connections")

      Divider()
        .frame(height: 20)

      // Export as PNG button
      Button(action: { workspaceManager.exportSchemaAsImage() }) {
        Image(systemName: "square.and.arrow.up")
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .help("Export as PNG")
      .disabled(workspaceManager.schemaGraph?.isEmpty ?? true)

      // Refresh button
      Button(action: {
        Task {
          await workspaceManager.refreshSchemaGraph()
        }
      }) {
        Image(systemName: "arrow.clockwise")
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .help("Refresh Schema")
      .disabled(workspaceManager.isLoadingSchemaGraph)

      Spacer()
    }
    .padding(.horizontal, Spacing.sm)
    .frame(height: ComponentSize.headerHeight)
    .background(Color.cardHeaderBackground)
    .overlay(alignment: .bottom) {
      Divider()
    }
  }

  // MARK: - Graph Content

  @ViewBuilder
  private var graphContent: some View {
    if workspaceManager.isLoadingSchemaGraph {
      loadingView
    } else if let graph = workspaceManager.schemaGraph {
      if graph.isEmpty {
        emptyStateView(message: "No tables found in database")
      } else if !graph.hasRelationships {
        noRelationshipsView(graph: graph)
      } else {
        graphView(graph: graph)
      }
    } else if !workspaceManager.connectionState.isConnected {
      emptyStateView(message: "Connect to a database to visualize schema")
    } else {
      emptyStateView(message: "Loading schema...")
    }
  }

  private var loadingView: some View {
    VStack(spacing: Spacing.md) {
      ProgressView()
        .scaleEffect(1.0)
      Text("Loading schema...")
        .font(.body)
        .foregroundColor(.foregroundMuted)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func emptyStateView(message: String) -> some View {
    VStack(spacing: Spacing.lg) {
      Image(systemName: "point.3.connected.trianglepath.dotted")
        .font(.system(size: 48))
        .foregroundColor(.foregroundMuted)
      Text(message)
        .font(.body)
        .foregroundColor(.foregroundMuted)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(Spacing.xl)
  }

  private func noRelationshipsView(graph: SchemaGraph) -> some View {
    VStack(spacing: Spacing.lg) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 48))
        .foregroundColor(.warning)

      Text("No Foreign Key Relationships")
        .font(.headline)
        .foregroundColor(.foreground)

      Text("Found \(graph.nodes.count) tables but no foreign key constraints.")
        .font(.body)
        .foregroundColor(.foregroundMuted)
        .multilineTextAlignment(.center)

      Text("Tables without relationships are not shown in the graph.")
        .font(.small)
        .foregroundColor(.foregroundSubtle)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(Spacing.xl)
  }

  private func graphView(graph: SchemaGraph) -> some View {
    VStack(spacing: 0) {
      SchemaGraphView(
        graph: Binding(
          get: { workspaceManager.schemaGraph ?? SchemaGraph() },
          set: { workspaceManager.schemaGraph = $0 }
        ),
        scale: $workspaceManager.visualizerScale,
        offset: $workspaceManager.visualizerOffset,
        selectedNodeId: $workspaceManager.selectedGraphNodeId,
        showTableConnections: $workspaceManager.showTableConnections,
        showColumnConnections: $workspaceManager.showColumnConnections,
        searchState: workspaceManager.schemaSearchState,
        onNodeDoubleClick: { node in
          handleNodeDoubleClick(node)
        },
        onNodeDragEnded: {
          workspaceManager.saveSchemaNodePositions()
        },
        onViewCreated: { nsView in
          workspaceManager.schemaGraphNSView = nsView
        }
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      // Footer legend
      schemaLegendFooter
    }
  }

  // MARK: - Legend Footer

  private var schemaLegendFooter: some View {
    ViewThatFits(in: .horizontal) {
      // First try: Single row layout
      HStack(spacing: Spacing.xl) {
        columnAttributesLegend

        Divider()
          .frame(height: 16)

        relationshipLegend
      }
      .frame(maxWidth: .infinity)

      // Fallback: Two rows layout for narrow width
      VStack(spacing: Spacing.sm) {
        columnAttributesLegend
        relationshipLegend
      }
      .frame(maxWidth: .infinity)
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.xs)
    .background(Color.cardHeaderBackground)
    .overlay(
      Divider(),
      alignment: .top
    )
  }

  private var columnAttributesLegend: some View {
    HStack(spacing: Spacing.md) {
      legendItem(icon: "key.fill", color: .yellow, label: "Primary Key")
      legendItem(icon: "number", color: .blue, label: "Identity")
      legendItem(icon: "touchid", color: .purple, label: "Unique")
      legendItem(icon: "diamond.fill", color: .gray, label: "Not Null")
      legendItem(icon: "diamond", color: .gray, label: "Nullable")
    }
  }

  private var relationshipLegend: some View {
    HStack(spacing: Spacing.md) {
      relationshipLegendItem(type: .one, label: "One")
      relationshipLegendItem(type: .many, label: "Many")
      relationshipLegendItem(type: .zeroOrOne, label: "Zero or One")
      relationshipLegendItem(type: .zeroOrMany, label: "Zero or Many")
    }
  }

  private func legendItem(icon: String, color: Color, label: String) -> some View {
    HStack(spacing: Spacing.xs) {
      Image(systemName: icon)
        .font(.system(size: 10))
        .foregroundColor(color)
        .frame(width: 12)
      Text(label)
        .font(.system(size: 10))
        .foregroundColor(.foregroundMuted)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
  }

  private func relationshipLegendItem(type: SchemaRelationshipType, label: String) -> some View {
    HStack(spacing: Spacing.xs) {
      SchemaRelationshipSymbolView(type: type)
        .frame(width: 24, height: 12)
      Text(label)
        .font(.system(size: 10))
        .foregroundColor(.foregroundMuted)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
  }

  // MARK: - Actions

  private func handleNodeDoubleClick(_ node: SchemaNode) {
    // Find table in sidebar and expand it
    if let tableIndex = workspaceManager.databaseTables.firstIndex(where: {
      $0.schema == node.table.schema && $0.name == node.table.name
    }) {
      // Open left sidebar if not visible
      if !workspaceManager.isLeftSidebarVisible {
        workspaceManager.toggleLeftSidebar()
      }
      // Expand the table in sidebar
      if !workspaceManager.databaseTables[tableIndex].isExpanded {
        workspaceManager.databaseTables[tableIndex].isExpanded = true
      }
    }
  }
}

// MARK: - Preview

#Preview("Schema Visualizer Header") {
  WorkspaceSchemaVisualizerContent(
    workspaceManager: WorkspaceManager.preview()
  )
  .frame(width: 800, height: 500)
}
