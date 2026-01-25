//
//  SchemaVisualizerContent.swift
//  SQLNotebook
//
//  Schema visualizer main body view - displays database schema relationships
//

import SwiftUI

/// Main body view for schema visualization (replaces cells/editor content)
struct SchemaVisualizerContent: View {
  @Bindable var viewModel: NotebookViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Header with controls
      header

      Divider()

      // Graph view or empty state
      graphContent
    }
    .background(Color.appBackground)
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: Spacing.md) {
      // Title and back button
      HStack(spacing: Spacing.sm) {
        Button(action: { viewModel.hideSchemaVisualizer() }) {
          Image(systemName: "chevron.left")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.foreground)
        }
        .buttonStyle(SidebarHeaderButtonStyle())
        .help("Back to \(viewModel.viewMode == .notebook ? "Notebook" : "Editor")")

        Text("Schema Relationships")
          .font(.subheading)
          .foregroundColor(.foreground)
      }

      Spacer()

      // Statistics
      if let graph = viewModel.schemaGraph {
        HStack(spacing: Spacing.md) {
          Label("\(graph.nodes.count) tables", systemImage: "tablecells")
          Label("\(graph.edges.count) relationships", systemImage: "arrow.triangle.branch")
        }
        .font(.small)
        .foregroundColor(.foregroundMuted)
      }

      Spacer()

      // Controls
      HStack(spacing: Spacing.xs) {
        // Zoom controls
        HStack(spacing: Spacing.xs) {
          Button(action: { viewModel.zoomOutVisualizer() }) {
            Image(systemName: "minus.magnifyingglass")
              .font(.system(size: 12, weight: .semibold))
              .foregroundColor(.foregroundMuted)
          }
          .buttonStyle(SidebarHeaderButtonStyle())
          .help("Zoom Out (Cmd+Scroll or Pinch)")

          Text("\(Int(viewModel.visualizerScale * 100))%")
            .font(.monoSmall)
            .foregroundColor(.foregroundMuted)
            .frame(width: 45)

          Button(action: { viewModel.zoomInVisualizer() }) {
            Image(systemName: "plus.magnifyingglass")
              .font(.system(size: 12, weight: .semibold))
              .foregroundColor(.foregroundMuted)
          }
          .buttonStyle(SidebarHeaderButtonStyle())
          .help("Zoom In (Cmd+Scroll or Pinch)")
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, Spacing.xxs)
        .background(
          RoundedRectangle(cornerRadius: CornerRadius.sm)
            .fill(Color.inputBackground)
        )

        Button(action: { viewModel.resetVisualizerView() }) {
          Image(systemName: "arrow.counterclockwise")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.foregroundMuted)
        }
        .buttonStyle(SidebarHeaderButtonStyle())
        .help("Reset View")

        // Refresh button
        Button(action: {
          Task {
            await viewModel.refreshSchemaGraph()
          }
        }) {
          Image(systemName: "arrow.clockwise")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.foregroundMuted)
        }
        .buttonStyle(SidebarHeaderButtonStyle())
        .help("Refresh Schema")
        .disabled(viewModel.isLoadingSchemaGraph)

        // Close button
        Button(action: { viewModel.hideSchemaVisualizer() }) {
          Image(systemName: "xmark")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.foregroundMuted)
        }
        .buttonStyle(SidebarHeaderButtonStyle())
        .help("Close Visualizer (Esc)")
      }
    }
    .padding(.horizontal, Spacing.md)
    .frame(height: ComponentSize.headerHeight)
    .background(Color.cardHeaderBackground)
  }

  // MARK: - Graph Content

  @ViewBuilder
  private var graphContent: some View {
    if viewModel.isLoadingSchemaGraph {
      loadingView
    } else if let graph = viewModel.schemaGraph {
      if graph.isEmpty {
        emptyStateView(message: "No tables found in database")
      } else if !graph.hasRelationships {
        noRelationshipsView(graph: graph)
      } else {
        graphView(graph: graph)
      }
    } else if !viewModel.connectionState.isConnected {
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
          get: { viewModel.schemaGraph ?? SchemaGraph() },
          set: { viewModel.schemaGraph = $0 }
        ),
        scale: $viewModel.visualizerScale,
        offset: $viewModel.visualizerOffset,
        selectedNodeId: $viewModel.selectedGraphNodeId,
        onNodeDoubleClick: { node in
          handleNodeDoubleClick(node)
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

  enum RelationshipType {
    case one
    case many
    case zeroOrOne
    case zeroOrMany
  }

  private func relationshipLegendItem(type: RelationshipType, label: String) -> some View {
    HStack(spacing: Spacing.xs) {
      RelationshipSymbolView(type: type)
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
    if let tableIndex = viewModel.databaseTables.firstIndex(where: {
      $0.schema == node.table.schema && $0.name == node.table.name
    }) {
      // Open left sidebar if not visible
      if !viewModel.isLeftSidebarVisible {
        viewModel.toggleLeftSidebar()
      }
      // Expand the table in sidebar
      if !viewModel.databaseTables[tableIndex].isExpanded {
        viewModel.toggleTableExpansion(tableId: viewModel.databaseTables[tableIndex].id)
      }
    }
  }
}

// MARK: - Relationship Symbol View

/// Draws standard ER notation symbols for relationships
private struct RelationshipSymbolView: View {
  let type: SchemaVisualizerContent.RelationshipType

  var body: some View {
    Canvas { context, size in
      let lineColor = Color.foregroundMuted
      let midY = size.height / 2

      // Draw the line
      var linePath = Path()
      linePath.move(to: CGPoint(x: 0, y: midY))
      linePath.addLine(to: CGPoint(x: size.width, y: midY))
      context.stroke(linePath, with: .color(lineColor), lineWidth: 1)

      // Draw the symbol at the end
      switch type {
      case .one:
        // Single vertical line (|)
        drawOneLine(context: context, at: size.width - 4, midY: midY, color: lineColor)

      case .many:
        // Crow's foot (three lines spreading out)
        drawCrowsFoot(context: context, at: size.width, midY: midY, color: lineColor)

      case .zeroOrOne:
        // Circle + vertical line (O|)
        drawCircle(context: context, at: size.width - 10, midY: midY, color: lineColor)
        drawOneLine(context: context, at: size.width - 4, midY: midY, color: lineColor)

      case .zeroOrMany:
        // Circle + crow's foot (O<)
        drawCircle(context: context, at: size.width - 14, midY: midY, color: lineColor)
        drawCrowsFoot(context: context, at: size.width, midY: midY, color: lineColor)
      }
    }
  }

  private func drawOneLine(
    context: GraphicsContext, at x: CGFloat, midY: CGFloat, color: Color
  ) {
    var path = Path()
    path.move(to: CGPoint(x: x, y: midY - 4))
    path.addLine(to: CGPoint(x: x, y: midY + 4))
    context.stroke(path, with: .color(color), lineWidth: 1)
  }

  private func drawCircle(
    context: GraphicsContext, at x: CGFloat, midY: CGFloat, color: Color
  ) {
    let circleRect = CGRect(x: x - 3, y: midY - 3, width: 6, height: 6)
    context.stroke(Path(ellipseIn: circleRect), with: .color(color), lineWidth: 1)
  }

  private func drawCrowsFoot(
    context: GraphicsContext, at endX: CGFloat, midY: CGFloat, color: Color
  ) {
    let footLength: CGFloat = 6
    let spread: CGFloat = 4

    var path = Path()
    // Center line
    path.move(to: CGPoint(x: endX, y: midY))
    path.addLine(to: CGPoint(x: endX - footLength, y: midY))

    // Upper line
    path.move(to: CGPoint(x: endX, y: midY))
    path.addLine(to: CGPoint(x: endX - footLength, y: midY - spread))

    // Lower line
    path.move(to: CGPoint(x: endX, y: midY))
    path.addLine(to: CGPoint(x: endX - footLength, y: midY + spread))

    context.stroke(path, with: .color(color), lineWidth: 1)
  }
}
