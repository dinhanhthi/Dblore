//
//  SchemaGraphView+HitTesting.swift
//  Dblore
//
//  Hit testing and node geometry for schema graph visualization
//

import AppKit
import SwiftUI

// MARK: - Hit Testing Extension

extension SchemaGraphNSView {

  // MARK: - Node Hit Testing

  func hitTestNode(at point: CGPoint) -> SchemaNode? {
    let canvasPoint = screenToCanvas(point)
    for node in graph.nodes.reversed() {
      if nodeRect(for: node).contains(canvasPoint) {
        return node
      }
    }
    return nil
  }

  /// Hit test for expand button
  func hitTestExpandButton(at point: CGPoint) -> SchemaNode? {
    let canvasPoint = screenToCanvas(point)
    for node in graph.nodes.reversed() {
      if expandButtonRect(for: node).contains(canvasPoint) {
        return node
      }
    }
    return nil
  }

  /// Hit test for resize handle (right edge of node)
  func hitTestResizeHandle(at point: CGPoint) -> SchemaNode? {
    let canvasPoint = screenToCanvas(point)
    for node in graph.nodes.reversed() {
      if resizeHandleRect(for: node).contains(canvasPoint) {
        return node
      }
    }
    return nil
  }

  /// Hit test for left resize handle (left edge of node)
  func hitTestLeftResizeHandle(at point: CGPoint) -> SchemaNode? {
    let canvasPoint = screenToCanvas(point)
    for node in graph.nodes.reversed() {
      if leftResizeHandleRect(for: node).contains(canvasPoint) {
        return node
      }
    }
    return nil
  }

  // MARK: - Edge Hit Testing

  /// Hit test for edges
  func hitTestEdge(at point: CGPoint) -> SchemaEdge? {
    let canvasPoint = screenToCanvas(point)

    for edge in graph.edges {
      if let edgePath = getCachedEdgePath(for: edge.id),
        edgePath.contains(canvasPoint, threshold: 8 / scale)
      {
        return edge
      }
    }
    return nil
  }

  // MARK: - Node Geometry

  /// Calculate node rect - height based on ALL columns, width from node or auto-calculated
  func nodeRect(for node: SchemaNode) -> CGRect {
    let columnsCount = node.table.columns.count
    let height = nodeHeaderHeight + CGFloat(columnsCount) * nodeColumnHeight + nodePadding
    let width = node.width ?? calculateAutoWidth(for: node)

    return CGRect(
      x: node.position.x,
      y: node.position.y,
      width: width,
      height: max(height, 60)
    )
  }

  /// Calculate auto width for a node based on content
  func calculateAutoWidth(for node: SchemaNode) -> CGFloat {
    let columnFont = NSFont.systemFont(ofSize: 9, weight: .regular)
    let typeFont = NSFont.monospacedSystemFont(ofSize: 8, weight: .regular)
    let tableFont = NSFont.systemFont(ofSize: 11, weight: .semibold)

    // Calculate width needed for table name in header (+ 60 for padding + buttons)
    let tableNameWidth =
      (node.table.name as NSString).size(withAttributes: [.font: tableFont]).width + 60

    // Calculate max width needed for columns
    var maxColumnWidth: CGFloat = 0
    let iconAreaWidth: CGFloat = 46  // Space for icons (4 icons * 10 spacing + 6 padding)
    let rightPadding: CGFloat = 8

    for column in node.table.columns {
      let nameWidth = (column.name as NSString).size(withAttributes: [.font: columnFont]).width
      let typeWidth = (column.type as NSString).size(withAttributes: [.font: typeFont]).width
      let totalWidth = iconAreaWidth + nameWidth + columnTypeGap + typeWidth + rightPadding
      maxColumnWidth = max(maxColumnWidth, totalWidth)
    }

    // Use the larger of table name width or column width, clamped to min/max
    let contentWidth = max(tableNameWidth, maxColumnWidth)
    return min(max(contentWidth, nodeMinWidth), nodeMaxWidth)
  }

  /// Calculate expand button rect for a node
  func expandButtonRect(for node: SchemaNode) -> CGRect {
    let nodeR = nodeRect(for: node)
    return CGRect(
      x: nodeR.maxX - expandButtonSize - 6,
      y: nodeR.minY + (nodeHeaderHeight - expandButtonSize) / 2,
      width: expandButtonSize,
      height: expandButtonSize
    )
  }

  /// Calculate resize handle rect for a node (right edge)
  func resizeHandleRect(for node: SchemaNode) -> CGRect {
    let nodeR = nodeRect(for: node)
    return CGRect(
      x: nodeR.maxX - resizeHandleWidth / 2,
      y: nodeR.minY,
      width: resizeHandleWidth,
      height: nodeR.height
    )
  }

  /// Calculate left resize handle rect for a node (left edge)
  func leftResizeHandleRect(for node: SchemaNode) -> CGRect {
    let nodeR = nodeRect(for: node)
    return CGRect(
      x: nodeR.minX - resizeHandleWidth / 2,
      y: nodeR.minY,
      width: resizeHandleWidth,
      height: nodeR.height
    )
  }

  // MARK: - Node Actions

  /// Auto-fit node width to content (double-click on resize handle)
  func autoFitNodeWidth(_ node: SchemaNode, fromLeft: Bool) {
    guard let index = graph.nodes.firstIndex(where: { $0.id == node.id }) else { return }

    let currentWidth = graph.nodes[index].width ?? calculateAutoWidth(for: node)
    let optimalWidth = calculateAutoWidth(for: node)

    if fromLeft {
      // When auto-fitting from left, adjust position to keep right edge fixed
      let widthDiff = currentWidth - optimalWidth
      let newPosition = CGPoint(
        x: graph.nodes[index].position.x + widthDiff,
        y: graph.nodes[index].position.y
      )
      graph.nodes[index].position = newPosition
      onNodeMoved?(node.id, newPosition)
    }

    // Set width to nil to use auto-calculated width
    graph.nodes[index].width = nil
    onNodeResized?(node.id, optimalWidth)
    onNodeDragEnded?()  // Save the changes
    needsDisplay = true
  }
}
