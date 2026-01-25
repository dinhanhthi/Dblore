//
//  SchemaLayoutEngine.swift
//  SQLNotebook
//
//  Force-directed layout algorithm for schema graph visualization
//

import CoreGraphics
import Foundation

/// Engine for calculating layout positions of schema graph nodes
/// Uses a force-directed algorithm to position tables with minimal edge crossings
@MainActor
final class SchemaLayoutEngine {

  // MARK: - Configuration

  /// Strength of repulsion between nodes (higher = more spread out)
  private let repulsionStrength: CGFloat = 15000

  /// Strength of attraction along edges (higher = connected nodes closer)
  private let attractionStrength: CGFloat = 0.008

  /// Damping factor to stabilize the simulation (0-1)
  private let damping: CGFloat = 0.85

  /// Minimum horizontal distance between nodes
  private let minHorizontalDistance: CGFloat = 250

  /// Minimum vertical distance between nodes
  private let minVerticalDistance: CGFloat = 50

  /// Number of iterations to run the simulation
  private let iterations: Int = 200

  /// Base node width for layout calculations
  private let nodeWidth: CGFloat = 200

  /// Node header height
  private let nodeHeaderHeight: CGFloat = 32

  /// Height per column
  private let columnHeight: CGFloat = 18

  /// Padding from canvas edges
  private let canvasPadding: CGFloat = 50

  // MARK: - Public API

  /// Calculate layout for the schema graph
  /// - Parameters:
  ///   - tables: Array of database tables to position
  ///   - foreignKeys: Array of foreign key relationships
  ///   - canvasSize: Size of the canvas to layout within
  /// - Returns: SchemaGraph with calculated positions
  func calculateLayout(
    tables: [DatabaseTable],
    foreignKeys: [ForeignKey],
    canvasSize: CGSize
  ) -> SchemaGraph {
    // Build initial graph
    var graph = SchemaGraph.build(from: tables, foreignKeys: foreignKeys)

    guard !graph.nodes.isEmpty else { return graph }

    // Initialize positions in a grid
    initializePositions(&graph, canvasSize: canvasSize)

    // Run force-directed simulation
    runSimulation(&graph, canvasSize: canvasSize)

    // Move isolated tables closer to the connected group
    positionIsolatedNodesNearConnectedGroup(&graph)

    return graph
  }

  // MARK: - Private Methods

  /// Calculate dynamic node height based on column count
  private func nodeHeight(for table: DatabaseTable) -> CGFloat {
    let columnsCount = table.columns.count
    return nodeHeaderHeight + CGFloat(columnsCount) * columnHeight + 8
  }

  /// Initialize node positions in a grid pattern with proper spacing to avoid overlap
  private func initializePositions(_ graph: inout SchemaGraph, canvasSize: CGSize) {
    let nodeCount = graph.nodes.count
    guard nodeCount > 0 else { return }

    // Sort nodes by connection count (more connected nodes first)
    let connectionCounts = countConnections(graph)
    let sortedIndices = graph.nodes.indices.sorted { i, j in
      let countI = connectionCounts[graph.nodes[i].id] ?? 0
      let countJ = connectionCounts[graph.nodes[j].id] ?? 0
      return countI > countJ
    }

    // Calculate grid dimensions
    let columns = max(1, Int(ceil(sqrt(Double(nodeCount)))))

    // Position nodes in grid with proper spacing
    var currentX: CGFloat = canvasPadding
    var currentY: CGFloat = canvasPadding
    var rowMaxHeight: CGFloat = 0
    var nodesInRow = 0

    for sortedIndex in sortedIndices {
      let nodeH = nodeHeight(for: graph.nodes[sortedIndex].table)

      // Check if we need to start a new row
      if nodesInRow >= columns {
        currentX = canvasPadding
        currentY += rowMaxHeight + minVerticalDistance
        rowMaxHeight = 0
        nodesInRow = 0
      }

      graph.nodes[sortedIndex].position = CGPoint(x: currentX, y: currentY)

      currentX += nodeWidth + minHorizontalDistance
      rowMaxHeight = max(rowMaxHeight, nodeH)
      nodesInRow += 1
    }
  }

  /// Count connections for each node
  private func countConnections(_ graph: SchemaGraph) -> [UUID: Int] {
    var counts: [UUID: Int] = [:]
    for node in graph.nodes {
      counts[node.id] = 0
    }
    for edge in graph.edges {
      counts[edge.sourceNodeId, default: 0] += 1
      counts[edge.targetNodeId, default: 0] += 1
    }
    return counts
  }

  /// Run the force-directed simulation with overlap prevention
  private func runSimulation(_ graph: inout SchemaGraph, canvasSize: CGSize) {
    var velocities: [CGPoint] = Array(repeating: .zero, count: graph.nodes.count)

    for _ in 0..<iterations {
      var forces: [CGPoint] = Array(repeating: .zero, count: graph.nodes.count)

      // Repulsion between all pairs of nodes (with overlap prevention)
      for i in 0..<graph.nodes.count {
        for j in (i + 1)..<graph.nodes.count {
          let force = calculateRepulsionWithOverlapPrevention(
            pos1: graph.nodes[i].position,
            height1: nodeHeight(for: graph.nodes[i].table),
            pos2: graph.nodes[j].position,
            height2: nodeHeight(for: graph.nodes[j].table)
          )
          forces[i].x += force.x
          forces[i].y += force.y
          forces[j].x -= force.x
          forces[j].y -= force.y
        }
      }

      // Attraction along edges
      for edge in graph.edges {
        guard
          let sourceIndex = graph.nodes.firstIndex(where: { $0.id == edge.sourceNodeId }),
          let targetIndex = graph.nodes.firstIndex(where: { $0.id == edge.targetNodeId })
        else { continue }

        let force = calculateAttraction(
          graph.nodes[sourceIndex].position,
          graph.nodes[targetIndex].position
        )

        forces[sourceIndex].x += force.x
        forces[sourceIndex].y += force.y
        forces[targetIndex].x -= force.x
        forces[targetIndex].y -= force.y
      }

      // Update velocities and positions
      for i in 0..<graph.nodes.count {
        velocities[i].x = (velocities[i].x + forces[i].x) * damping
        velocities[i].y = (velocities[i].y + forces[i].y) * damping

        let maxVelocity: CGFloat = 40
        let speed = sqrt(velocities[i].x * velocities[i].x + velocities[i].y * velocities[i].y)
        if speed > maxVelocity {
          velocities[i].x = velocities[i].x / speed * maxVelocity
          velocities[i].y = velocities[i].y / speed * maxVelocity
        }

        graph.nodes[i].position.x += velocities[i].x
        graph.nodes[i].position.y += velocities[i].y

        // Keep within reasonable bounds (allow scrolling beyond canvas)
        graph.nodes[i].position.x = max(canvasPadding, graph.nodes[i].position.x)
        graph.nodes[i].position.y = max(canvasPadding, graph.nodes[i].position.y)
      }
    }

    // Final pass: resolve any remaining overlaps
    resolveOverlaps(&graph)
  }

  /// Calculate repulsion with overlap prevention
  private func calculateRepulsionWithOverlapPrevention(
    pos1: CGPoint, height1: CGFloat,
    pos2: CGPoint, height2: CGFloat
  ) -> CGPoint {
    let dx = pos1.x - pos2.x
    let dy = pos1.y - pos2.y
    var distance = sqrt(dx * dx + dy * dy)

    distance = max(distance, 1)

    // Calculate required minimum distance based on node sizes
    let minDistX = nodeWidth + minHorizontalDistance / 2
    let minDistY = (height1 + height2) / 2 + minVerticalDistance

    // Stronger repulsion when nodes are overlapping
    let overlapFactorX = max(0, minDistX - abs(dx))
    let overlapFactorY = max(0, minDistY - abs(dy))
    let overlapBoost = 1 + (overlapFactorX + overlapFactorY) / 50

    let forceMagnitude = (repulsionStrength * overlapBoost) / (distance * distance)

    return CGPoint(
      x: (dx / distance) * forceMagnitude,
      y: (dy / distance) * forceMagnitude
    )
  }

  /// Final pass to resolve any remaining overlaps
  private func resolveOverlaps(_ graph: inout SchemaGraph) {
    let maxPasses = 50
    for _ in 0..<maxPasses {
      var hasOverlap = false

      for i in 0..<graph.nodes.count {
        for j in (i + 1)..<graph.nodes.count {
          let rect1 = nodeRect(for: graph.nodes[i])
          let rect2 = nodeRect(for: graph.nodes[j])

          // Add margin to detect near-overlaps
          let margin: CGFloat = 20
          let expandedRect1 = rect1.insetBy(dx: -margin, dy: -margin)

          if expandedRect1.intersects(rect2) {
            hasOverlap = true

            // Calculate push direction
            let dx = rect2.midX - rect1.midX
            let dy = rect2.midY - rect1.midY

            // Push apart
            let pushX: CGFloat = dx > 0 ? 10 : -10
            let pushY: CGFloat = dy > 0 ? 10 : -10

            graph.nodes[i].position.x -= pushX
            graph.nodes[i].position.y -= pushY
            graph.nodes[j].position.x += pushX
            graph.nodes[j].position.y += pushY

            // Keep within bounds
            graph.nodes[i].position.x = max(canvasPadding, graph.nodes[i].position.x)
            graph.nodes[i].position.y = max(canvasPadding, graph.nodes[i].position.y)
            graph.nodes[j].position.x = max(canvasPadding, graph.nodes[j].position.x)
            graph.nodes[j].position.y = max(canvasPadding, graph.nodes[j].position.y)
          }
        }
      }

      if !hasOverlap { break }
    }
  }

  /// Calculate node rect for overlap detection
  private func nodeRect(for node: SchemaNode) -> CGRect {
    let height = nodeHeight(for: node.table)
    return CGRect(
      x: node.position.x,
      y: node.position.y,
      width: nodeWidth,
      height: height
    )
  }

  /// Calculate repulsion force between two nodes
  private func calculateRepulsion(_ pos1: CGPoint, _ pos2: CGPoint) -> CGPoint {
    let dx = pos1.x - pos2.x
    let dy = pos1.y - pos2.y
    var distance = sqrt(dx * dx + dy * dy)

    // Prevent division by zero and enforce minimum distance
    distance = max(distance, 1)

    // Force magnitude (inverse square law)
    let forceMagnitude = repulsionStrength / (distance * distance)

    // Normalize and scale
    return CGPoint(
      x: (dx / distance) * forceMagnitude,
      y: (dy / distance) * forceMagnitude
    )
  }

  /// Calculate attraction force along an edge
  private func calculateAttraction(_ pos1: CGPoint, _ pos2: CGPoint) -> CGPoint {
    let dx = pos2.x - pos1.x
    let dy = pos2.y - pos1.y
    let distance = sqrt(dx * dx + dy * dy)

    // Only attract if beyond minimum horizontal distance
    guard distance > minHorizontalDistance else { return .zero }

    // Linear attraction
    let forceMagnitude = (distance - minHorizontalDistance) * attractionStrength

    // Normalize and scale
    return CGPoint(
      x: (dx / distance) * forceMagnitude,
      y: (dy / distance) * forceMagnitude
    )
  }

  /// Build adjacency list for quick edge lookup
  private func buildAdjacencyList(_ graph: SchemaGraph) -> [UUID: Set<UUID>] {
    var adjacency: [UUID: Set<UUID>] = [:]

    for node in graph.nodes {
      adjacency[node.id] = []
    }

    for edge in graph.edges {
      adjacency[edge.sourceNodeId, default: []].insert(edge.targetNodeId)
      adjacency[edge.targetNodeId, default: []].insert(edge.sourceNodeId)
    }

    return adjacency
  }

  /// Position isolated nodes (no relationships) near the connected group
  private func positionIsolatedNodesNearConnectedGroup(_ graph: inout SchemaGraph) {
    let connectedNodeIds = Set(graph.edges.flatMap { [$0.sourceNodeId, $0.targetNodeId] })

    // Get isolated node indices
    let isolatedIndices = graph.nodes.indices.filter {
      !connectedNodeIds.contains(graph.nodes[$0].id)
    }

    guard !isolatedIndices.isEmpty else { return }

    // If all nodes are isolated, no need to reposition
    let connectedIndices = graph.nodes.indices.filter {
      connectedNodeIds.contains(graph.nodes[$0].id)
    }
    guard !connectedIndices.isEmpty else { return }

    // Calculate bounding box of connected nodes
    let connectedBounds = calculateBoundingBox(
      for: connectedIndices.map { graph.nodes[$0] }
    )

    // Position isolated nodes to the right of the connected group
    let startX = connectedBounds.maxX + minHorizontalDistance
    var currentX = startX
    var currentY = connectedBounds.minY
    var rowMaxHeight: CGFloat = 0

    // Calculate how many columns we can fit for isolated nodes
    let maxRowWidth: CGFloat = 800  // Max width for isolated nodes area
    var rowWidth: CGFloat = 0

    for isolatedIndex in isolatedIndices {
      let nodeH = nodeHeight(for: graph.nodes[isolatedIndex].table)

      // Check if we need to start a new row
      if rowWidth + nodeWidth > maxRowWidth && rowWidth > 0 {
        currentX = startX
        currentY += rowMaxHeight + minVerticalDistance
        rowMaxHeight = 0
        rowWidth = 0
      }

      graph.nodes[isolatedIndex].position = CGPoint(x: currentX, y: currentY)

      currentX += nodeWidth + minHorizontalDistance / 2
      rowWidth += nodeWidth + minHorizontalDistance / 2
      rowMaxHeight = max(rowMaxHeight, nodeH)
    }

    // Final overlap resolution for isolated nodes
    resolveOverlaps(&graph)
  }

  /// Calculate bounding box for a set of nodes
  private func calculateBoundingBox(for nodes: [SchemaNode]) -> CGRect {
    guard !nodes.isEmpty else { return .zero }

    var minX = CGFloat.infinity
    var minY = CGFloat.infinity
    var maxX = -CGFloat.infinity
    var maxY = -CGFloat.infinity

    for node in nodes {
      let rect = nodeRect(for: node)
      minX = min(minX, rect.minX)
      minY = min(minY, rect.minY)
      maxX = max(maxX, rect.maxX)
      maxY = max(maxY, rect.maxY)
    }

    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }
}
