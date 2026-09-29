//
//  SchemaLayoutEngine.swift
//  Dblore
//
//  Force-directed layout algorithm for schema graph visualization
//  with edge routing to avoid node intersections
//

import CoreGraphics
import Foundation

/// Engine for calculating layout positions of schema graph nodes
/// Uses a force-directed algorithm to position tables with minimal edge crossings
@MainActor
final class SchemaLayoutEngine {

  // MARK: - Configuration

  /// Strength of repulsion between nodes (higher = more spread out)
  private let repulsionStrength: CGFloat = 20000

  /// Strength of attraction along edges (higher = connected nodes closer)
  private let attractionStrength: CGFloat = 0.006

  /// Damping factor to stabilize the simulation (0-1)
  private let damping: CGFloat = 0.85

  /// Minimum horizontal distance between nodes (increased for edge routing space)
  private let minHorizontalDistance: CGFloat = 300

  /// Minimum vertical distance between nodes
  private let minVerticalDistance: CGFloat = 80

  /// Number of iterations to run the simulation
  private let iterations: Int = 300

  /// Base node width for layout calculations
  private let nodeWidth: CGFloat = 200

  /// Node header height
  private let nodeHeaderHeight: CGFloat = 32

  /// Height per column
  private let columnHeight: CGFloat = 18

  /// Padding from canvas edges
  private let canvasPadding: CGFloat = 50

  /// Edge routing margin around nodes
  private let edgeRoutingMargin: CGFloat = 40

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

  /// Run the force-directed simulation with overlap prevention and edge-node avoidance
  private func runSimulation(_ graph: inout SchemaGraph, canvasSize: CGSize) {
    var velocities: [CGPoint] = Array(repeating: .zero, count: graph.nodes.count)

    // Build node rects cache for edge-node intersection checking
    _ = graph.nodes.map { nodeRect(for: $0) }

    for iteration in 0..<iterations {
      var forces: [CGPoint] = Array(repeating: .zero, count: graph.nodes.count)

      // Temperature decreases over time (simulated annealing)
      let temperature = 1.0 - CGFloat(iteration) / CGFloat(iterations)

      // Repulsion between all pairs of nodes (with overlap prevention)
      for i in 0..<graph.nodes.count {
        for j in (i + 1)..<graph.nodes.count {
          let force = calculateRepulsionWithOverlapPrevention(
            pos1: graph.nodes[i].position,
            height1: nodeHeight(for: graph.nodes[i].table),
            width1: graph.nodes[i].width ?? nodeWidth,
            pos2: graph.nodes[j].position,
            height2: nodeHeight(for: graph.nodes[j].table),
            width2: graph.nodes[j].width ?? nodeWidth
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

        // Add force to move nodes that block edge paths
        let edgeNodeForce = calculateEdgeNodeAvoidanceForce(
          graph: graph,
          edge: edge,
          sourceIndex: sourceIndex,
          targetIndex: targetIndex
        )
        for (nodeIndex, force) in edgeNodeForce {
          forces[nodeIndex].x += force.x * 0.5
          forces[nodeIndex].y += force.y * 0.5
        }
      }

      // Update velocities and positions with temperature scaling
      for i in 0..<graph.nodes.count {
        velocities[i].x = (velocities[i].x + forces[i].x) * damping
        velocities[i].y = (velocities[i].y + forces[i].y) * damping

        let maxVelocity: CGFloat = 40 * (0.3 + 0.7 * temperature)
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

    // Final pass: resolve any remaining overlaps with stronger separation
    resolveOverlaps(&graph)
  }

  /// Calculate forces to push nodes away from edge paths they might be blocking
  private func calculateEdgeNodeAvoidanceForce(
    graph: SchemaGraph,
    edge: SchemaEdge,
    sourceIndex: Int,
    targetIndex: Int
  ) -> [(Int, CGPoint)] {
    var forces: [(Int, CGPoint)] = []

    let sourceNode = graph.nodes[sourceIndex]
    let targetNode = graph.nodes[targetIndex]
    let sourceRect = nodeRect(for: sourceNode)
    let targetRect = nodeRect(for: targetNode)

    // Calculate edge path (simplified - just check if nodes are in the way)
    let sourceCenter = CGPoint(x: sourceRect.midX, y: sourceRect.midY)
    let targetCenter = CGPoint(x: targetRect.midX, y: targetRect.midY)

    // Check each node (except source and target) if it blocks the edge
    for (nodeIndex, node) in graph.nodes.enumerated() {
      guard nodeIndex != sourceIndex && nodeIndex != targetIndex else { continue }

      let nodeR = nodeRect(for: node).insetBy(dx: -edgeRoutingMargin, dy: -edgeRoutingMargin)

      // Check if this node's bounding box intersects with the edge path
      if lineIntersectsRect(from: sourceCenter, to: targetCenter, rect: nodeR) {
        // Calculate push direction - perpendicular to the edge
        let edgeDx = targetCenter.x - sourceCenter.x
        let edgeDy = targetCenter.y - sourceCenter.y
        let edgeLength = sqrt(edgeDx * edgeDx + edgeDy * edgeDy)

        guard edgeLength > 0 else { continue }

        // Perpendicular direction (rotated 90 degrees)
        let perpX = -edgeDy / edgeLength
        let perpY = edgeDx / edgeLength

        // Determine which side of the edge the node center is on
        let nodeCenter = CGPoint(x: nodeR.midX, y: nodeR.midY)
        let toNodeX = nodeCenter.x - sourceCenter.x
        let toNodeY = nodeCenter.y - sourceCenter.y
        let crossProduct = edgeDx * toNodeY - edgeDy * toNodeX

        // Push in the perpendicular direction (same side as the node is on)
        let pushStrength: CGFloat = 500
        let direction = crossProduct > 0 ? 1.0 : -1.0
        let pushForce = CGPoint(
          x: perpX * pushStrength * direction,
          y: perpY * pushStrength * direction
        )
        forces.append((nodeIndex, pushForce))
      }
    }

    return forces
  }

  /// Check if a line segment intersects a rectangle
  private func lineIntersectsRect(from p1: CGPoint, to p2: CGPoint, rect: CGRect) -> Bool {
    // Check if line segment intersects any of the 4 edges of the rectangle
    let topLeft = CGPoint(x: rect.minX, y: rect.minY)
    let topRight = CGPoint(x: rect.maxX, y: rect.minY)
    let bottomLeft = CGPoint(x: rect.minX, y: rect.maxY)
    let bottomRight = CGPoint(x: rect.maxX, y: rect.maxY)

    return lineSegmentsIntersect(p1, p2, topLeft, topRight)
      || lineSegmentsIntersect(p1, p2, topRight, bottomRight)
      || lineSegmentsIntersect(p1, p2, bottomRight, bottomLeft)
      || lineSegmentsIntersect(p1, p2, bottomLeft, topLeft)
      || rect.contains(p1) || rect.contains(p2)
  }

  /// Check if two line segments intersect
  private func lineSegmentsIntersect(
    _ p1: CGPoint, _ p2: CGPoint,
    _ p3: CGPoint, _ p4: CGPoint
  ) -> Bool {
    let d1 = direction(p3, p4, p1)
    let d2 = direction(p3, p4, p2)
    let d3 = direction(p1, p2, p3)
    let d4 = direction(p1, p2, p4)

    if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0))
      && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
    {
      return true
    }

    if d1 == 0 && onSegment(p3, p4, p1) { return true }
    if d2 == 0 && onSegment(p3, p4, p2) { return true }
    if d3 == 0 && onSegment(p1, p2, p3) { return true }
    if d4 == 0 && onSegment(p1, p2, p4) { return true }

    return false
  }

  private func direction(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint) -> CGFloat {
    (p3.x - p1.x) * (p2.y - p1.y) - (p2.x - p1.x) * (p3.y - p1.y)
  }

  private func onSegment(_ p1: CGPoint, _ p2: CGPoint, _ p: CGPoint) -> Bool {
    p.x >= min(p1.x, p2.x) && p.x <= max(p1.x, p2.x)
      && p.y >= min(p1.y, p2.y) && p.y <= max(p1.y, p2.y)
  }

  /// Calculate repulsion with overlap prevention using actual node dimensions
  private func calculateRepulsionWithOverlapPrevention(
    pos1: CGPoint, height1: CGFloat, width1: CGFloat,
    pos2: CGPoint, height2: CGFloat, width2: CGFloat
  ) -> CGPoint {
    let dx = pos1.x - pos2.x
    let dy = pos1.y - pos2.y
    var distance = sqrt(dx * dx + dy * dy)

    distance = max(distance, 1)

    // Calculate required minimum distance based on actual node sizes
    let avgWidth = (width1 + width2) / 2
    let minDistX = avgWidth + minHorizontalDistance
    let minDistY = (height1 + height2) / 2 + minVerticalDistance

    // Check for actual rectangle overlap
    let rect1 = CGRect(x: pos1.x, y: pos1.y, width: width1, height: height1)
    let rect2 = CGRect(x: pos2.x, y: pos2.y, width: width2, height: height2)
    let expandedRect1 = rect1.insetBy(dx: -minHorizontalDistance / 2, dy: -minVerticalDistance / 2)

    // Much stronger repulsion when rectangles actually overlap
    var overlapBoost: CGFloat = 1.0
    if expandedRect1.intersects(rect2) {
      // Calculate overlap amount
      let overlapX = min(expandedRect1.maxX, rect2.maxX) - max(expandedRect1.minX, rect2.minX)
      let overlapY = min(expandedRect1.maxY, rect2.maxY) - max(expandedRect1.minY, rect2.minY)
      overlapBoost = 1 + (max(0, overlapX) + max(0, overlapY)) / 20
    } else {
      // Standard distance-based boost
      let overlapFactorX = max(0, minDistX - abs(dx))
      let overlapFactorY = max(0, minDistY - abs(dy))
      overlapBoost = 1 + (overlapFactorX + overlapFactorY) / 100
    }

    let forceMagnitude = (repulsionStrength * overlapBoost) / (distance * distance)

    return CGPoint(
      x: (dx / distance) * forceMagnitude,
      y: (dy / distance) * forceMagnitude
    )
  }

  /// Final pass to resolve any remaining overlaps with proper separation
  private func resolveOverlaps(_ graph: inout SchemaGraph) {
    let maxPasses = 100
    let margin: CGFloat = minHorizontalDistance / 2

    for _ in 0..<maxPasses {
      var hasOverlap = false
      var maxOverlap: CGFloat = 0

      for i in 0..<graph.nodes.count {
        for j in (i + 1)..<graph.nodes.count {
          let rect1 = nodeRect(for: graph.nodes[i])
          let rect2 = nodeRect(for: graph.nodes[j])

          // Add margin for proper spacing between nodes
          let expandedRect1 = rect1.insetBy(dx: -margin, dy: -minVerticalDistance / 2)

          if expandedRect1.intersects(rect2) {
            hasOverlap = true

            // Calculate actual overlap amounts
            let overlapX = min(expandedRect1.maxX, rect2.maxX) - max(expandedRect1.minX, rect2.minX)
            let overlapY = min(expandedRect1.maxY, rect2.maxY) - max(expandedRect1.minY, rect2.minY)
            maxOverlap = max(maxOverlap, max(overlapX, overlapY))

            // Calculate push direction based on center positions
            let dx = rect2.midX - rect1.midX
            let dy = rect2.midY - rect1.midY

            // Push proportionally to overlap, with minimum push amount
            let pushStrength = max(15, min(overlapX, overlapY) / 2)

            // Prefer horizontal separation for better edge routing
            var pushX: CGFloat = 0
            var pushY: CGFloat = 0

            if abs(dx) > abs(dy) || overlapX > overlapY {
              // Push horizontally
              pushX = dx > 0 ? pushStrength : -pushStrength
              pushY = dy > 0 ? pushStrength * 0.3 : -pushStrength * 0.3
            } else {
              // Push vertically
              pushX = dx > 0 ? pushStrength * 0.3 : -pushStrength * 0.3
              pushY = dy > 0 ? pushStrength : -pushStrength
            }

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

      // Stop early if no overlap or overlap is minimal
      if !hasOverlap || maxOverlap < 5 { break }
    }
  }

  /// Calculate node rect for overlap detection using actual node dimensions
  private func nodeRect(for node: SchemaNode) -> CGRect {
    let height = nodeHeight(for: node.table)
    let width = node.width ?? nodeWidth
    return CGRect(
      x: node.position.x,
      y: node.position.y,
      width: width,
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
