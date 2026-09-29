//
//  SchemaGraphView+ColumnConnections.swift
//  Dblore
//
//  Column connection line drawing and hit testing for schema graph
//

import AppKit
import SwiftUI

// MARK: - Column Connection Lines Extension

extension SchemaGraphNSView {

  /// Draw dashed animated lines connecting FK columns between tables
  func drawColumnConnections(_ context: CGContext) {
    clearCachedColumnConnectionPaths()

    for edge in graph.edges {
      guard
        let sourceNode = graph.node(withId: edge.sourceNodeId),
        let targetNode = graph.node(withId: edge.targetNodeId)
      else { continue }

      let sourceRect = nodeRect(for: sourceNode)
      let targetRect = nodeRect(for: targetNode)

      // Get column pairs from the foreign key
      let fk = edge.foreignKey
      let columnPairs = zip(fk.sourceColumns, fk.targetColumns)

      var paths: [ColumnConnectionPath] = []

      for (sourceCol, targetCol) in columnPairs {
        // Find column indices
        guard
          let sourceIndex = sourceNode.table.columns.firstIndex(where: { $0.name == sourceCol }),
          let targetIndex = targetNode.table.columns.firstIndex(where: { $0.name == targetCol })
        else { continue }

        let isHighlighted =
          hoveredColumnConnectionEdgeId == edge.id || selectedColumnConnectionEdgeId == edge.id
        drawColumnConnectionLine(
          context,
          sourceRect: sourceRect,
          targetRect: targetRect,
          sourceColumnIndex: sourceIndex,
          targetColumnIndex: targetIndex,
          isHighlighted: isHighlighted,
          pathOutput: &paths,
          edgeId: edge.id
        )
      }

      storeCachedColumnConnectionPaths(edgeId: edge.id, paths: paths)
    }
  }

  /// Draw a single column connection line with dashed animated style
  func drawColumnConnectionLine(
    _ context: CGContext,
    sourceRect: CGRect,
    targetRect: CGRect,
    sourceColumnIndex: Int,
    targetColumnIndex: Int,
    isHighlighted: Bool,
    pathOutput: inout [ColumnConnectionPath],
    edgeId: UUID
  ) {
    // Calculate Y position for source column - align with vertical center of column name text
    // Text is drawn at y = nodeHeaderHeight + 4 + index * nodeColumnHeight
    // Font size is 9pt, so text height is ~11px. Center = y + fontSize/2 + small offset
    let textVerticalCenter: CGFloat = 5  // Approximate center offset for 9pt font
    let sourceY =
      sourceRect.minY + nodeHeaderHeight + 4 + CGFloat(sourceColumnIndex) * nodeColumnHeight
      + textVerticalCenter

    // Calculate Y position for target column
    let targetY =
      targetRect.minY + nodeHeaderHeight + 4 + CGFloat(targetColumnIndex) * nodeColumnHeight
      + textVerticalCenter

    // Determine connection points based on relative positions
    let sourceCenter = CGPoint(x: sourceRect.midX, y: sourceRect.midY)
    let targetCenter = CGPoint(x: targetRect.midX, y: targetRect.midY)

    var startPoint: CGPoint
    var endPoint: CGPoint

    // Connect from edge of node closest to the other node
    if sourceCenter.x < targetCenter.x {
      // Source is to the left of target
      startPoint = CGPoint(x: sourceRect.maxX, y: sourceY)
      endPoint = CGPoint(x: targetRect.minX, y: targetY)
    } else {
      // Source is to the right of target
      startPoint = CGPoint(x: sourceRect.minX, y: sourceY)
      endPoint = CGPoint(x: targetRect.maxX, y: targetY)
    }

    // Create path with horizontal offset for visual clarity
    let midX = (startPoint.x + endPoint.x) / 2
    let path = [
      startPoint,
      CGPoint(x: midX, y: startPoint.y),
      CGPoint(x: midX, y: endPoint.y),
      endPoint,
    ]

    // Store path for hit testing
    pathOutput.append(
      ColumnConnectionPath(
        edgeId: edgeId,
        sourceColumnIndex: sourceColumnIndex,
        targetColumnIndex: targetColumnIndex,
        path: path
      ))

    // Set line style
    let lineColor: NSColor = isHighlighted ? .systemGreen : edgeColor.withAlphaComponent(0.6)
    let lineWidth: CGFloat = isHighlighted ? 2.0 : 1.0

    context.saveGState()

    // Draw glow effect when highlighted (hovered or selected)
    if isHighlighted {
      context.setShadow(
        offset: .zero,
        blur: 6,
        color: NSColor.systemGreen.withAlphaComponent(0.5).cgColor
      )
    }

    context.setStrokeColor(lineColor.cgColor)
    context.setLineWidth(lineWidth)

    // Set dashed line pattern with animation
    let dashPattern: [CGFloat] = [6, 4]
    let dashPhase = columnConnectionAnimationPhase
    context.setLineDash(phase: dashPhase, lengths: dashPattern)

    // Draw the path
    context.move(to: path[0])
    for i in 1..<path.count {
      context.addLine(to: path[i])
    }
    context.strokePath()

    context.restoreGState()
  }

  /// Hit test for column connection lines
  func hitTestColumnConnection(at point: CGPoint) -> UUID? {
    let canvasPoint = screenToCanvas(point)

    for (edgeId, paths) in getCachedColumnConnectionPaths() {
      for connectionPath in paths {
        if connectionPath.contains(canvasPoint, threshold: 8 / scale) {
          return edgeId
        }
      }
    }
    return nil
  }

  /// Get the column indices that should be highlighted for a given edge
  func highlightedColumnsForEdge(
    _ edgeId: UUID
  ) -> (
    sourceNodeId: UUID, sourceColumns: [Int], targetNodeId: UUID, targetColumns: [Int]
  )? {
    guard let edge = graph.edges.first(where: { $0.id == edgeId }),
      let sourceNode = graph.node(withId: edge.sourceNodeId),
      let targetNode = graph.node(withId: edge.targetNodeId)
    else { return nil }

    let fk = edge.foreignKey
    var sourceIndices: [Int] = []
    var targetIndices: [Int] = []

    for (sourceCol, targetCol) in zip(fk.sourceColumns, fk.targetColumns) {
      if let idx = sourceNode.table.columns.firstIndex(where: { $0.name == sourceCol }) {
        sourceIndices.append(idx)
      }
      if let idx = targetNode.table.columns.firstIndex(where: { $0.name == targetCol }) {
        targetIndices.append(idx)
      }
    }

    return (edge.sourceNodeId, sourceIndices, edge.targetNodeId, targetIndices)
  }
}
