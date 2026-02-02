//
//  SchemaGraphView+Drawing.swift
//  SQLNotebook
//
//  Edge and background drawing for schema graph visualization
//

import AppKit
import SwiftUI

// MARK: - Drawing Extension

extension SchemaGraphNSView {

  // MARK: - Dot Pattern Background

  func drawDotPattern(_ context: CGContext) {
    let dotSpacing: CGFloat = 20  // Space between dots
    let dotRadius: CGFloat = 1.0  // Small dot size
    let dotColor = NSColor(Color.foregroundMuted).withAlphaComponent(0.15)

    context.saveGState()
    context.setFillColor(dotColor.cgColor)

    // Calculate visible area in canvas coordinates
    let visibleRect = CGRect(
      x: -offset.x / scale,
      y: -offset.y / scale,
      width: bounds.width / scale,
      height: bounds.height / scale
    )

    // Adjust dot spacing based on scale for consistent visual density
    let adjustedSpacing = dotSpacing / scale

    // Calculate start positions (aligned to grid)
    let startX = floor(visibleRect.minX / adjustedSpacing) * adjustedSpacing
    let startY = floor(visibleRect.minY / adjustedSpacing) * adjustedSpacing

    // Apply transform for canvas coordinates
    context.translateBy(x: offset.x, y: offset.y)
    context.scaleBy(x: scale, y: scale)

    // Draw dots in the visible area
    var x = startX
    while x <= visibleRect.maxX {
      var y = startY
      while y <= visibleRect.maxY {
        let dotRect = CGRect(
          x: x - dotRadius,
          y: y - dotRadius,
          width: dotRadius * 2,
          height: dotRadius * 2
        )
        context.fillEllipse(in: dotRect)
        y += adjustedSpacing
      }
      x += adjustedSpacing
    }

    context.restoreGState()
  }

  // MARK: - Edge Drawing

  func drawEdges(_ context: CGContext) {
    // Collect all node rects for obstacle avoidance
    let allNodeRects: [CGRect] = graph.nodes.map { nodeRect(for: $0) }

    for edge in graph.edges {
      guard
        let sourceNode = graph.node(withId: edge.sourceNodeId),
        let targetNode = graph.node(withId: edge.targetNodeId)
      else { continue }

      // Edge is highlighted if:
      // - Connected to selected node
      // - Currently hovered
      // - Has passed hover delay (highlightedEdgeId)
      // - Was clicked (selectedEdgeId)
      let isHighlighted =
        selectedNodeId == edge.sourceNodeId || selectedNodeId == edge.targetNodeId
        || hoveredEdgeId == edge.id
        || highlightedEdgeId == edge.id
        || selectedEdgeId == edge.id

      let sourceRect = nodeRect(for: sourceNode)
      let targetRect = nodeRect(for: targetNode)

      // Draw orthogonal path with obstacle avoidance
      drawOrthogonalEdge(
        context,
        edge: edge,
        from: sourceRect,
        to: targetRect,
        highlighted: isHighlighted,
        obstacleRects: allNodeRects
      )
    }
  }

  /// Draw orthogonal edge with obstacle avoidance
  func drawOrthogonalEdge(
    _ context: CGContext,
    edge: SchemaEdge,
    from sourceRect: CGRect,
    to targetRect: CGRect,
    highlighted: Bool,
    obstacleRects: [CGRect]
  ) {
    // Use edge router to find a path that avoids other nodes
    let routedPath = edgeRouter.routeEdge(
      from: sourceRect,
      to: targetRect,
      avoiding: obstacleRects,
      edgeId: edge.id
    )

    let points = routedPath.points
    guard points.count >= 2 else { return }

    // Store edge path for hit testing
    let edgePath = EdgePath(id: edge.id, points: points)
    storeCachedEdgePath(edgePath)

    // Determine line width and color based on highlight state
    let lineWidth: CGFloat = highlighted ? 1.5 : 0.75
    let strokeColor = highlighted ? edgeHighlightColor : edgeColor

    // Draw glow effect when highlighted (hover or selected)
    if highlighted {
      context.saveGState()
      context.setShadow(
        offset: .zero,
        blur: 4,
        color: edgeHighlightColor.withAlphaComponent(0.5).cgColor
      )
      context.setStrokeColor(edgeHighlightColor.cgColor)
      context.setLineWidth(2.5)
      context.move(to: points[0])
      for i in 1..<points.count {
        context.addLine(to: points[i])
      }
      context.strokePath()
      context.restoreGState()
    }

    // Draw main path
    context.setStrokeColor(strokeColor.cgColor)
    context.setLineWidth(lineWidth)

    context.move(to: points[0])
    for i in 1..<points.count {
      context.addLine(to: points[i])
    }
    context.strokePath()

    // Draw ER notation symbols
    let startPoint = edgePath.startPoint
    let secondPoint = edgePath.secondPoint
    let endPoint = edgePath.endPoint
    let secondToLastPoint = edgePath.secondToLastPoint

    // Source side: "many" (crow's foot) - FK table can have many rows referencing one PK
    // Also draw zero circle to indicate "zero or many" (optional relationship)
    drawZeroCircle(
      context, at: startPoint, from: secondPoint, highlighted: highlighted, offsetDistance: 16)
    drawCrowsFoot(context, at: startPoint, toward: secondPoint, highlighted: highlighted)

    // Target side: "one" (single line) - PK table has one row being referenced
    // Also draw zero circle to indicate "zero or one" possibility
    drawZeroCircle(
      context, at: endPoint, from: secondToLastPoint, highlighted: highlighted, offsetDistance: 14)
    drawOneNotation(context, at: endPoint, from: secondToLastPoint, highlighted: highlighted)
  }

  func drawCrowsFoot(
    _ context: CGContext, at point: CGPoint, toward midPoint: CGPoint, highlighted: Bool
  ) {
    let footSize: CGFloat = 8
    let spreadAngle: CGFloat = .pi / 6

    let strokeColor = highlighted ? edgeHighlightColor : edgeColor
    let lineWidth: CGFloat = highlighted ? 1.5 : 0.75

    context.setStrokeColor(strokeColor.cgColor)
    context.setLineWidth(lineWidth)

    let dx = midPoint.x - point.x
    let dy = midPoint.y - point.y
    let baseAngle = atan2(dy, dx)

    let centerEnd = CGPoint(
      x: point.x + footSize * cos(baseAngle),
      y: point.y + footSize * sin(baseAngle)
    )
    let upperEnd = CGPoint(
      x: point.x + footSize * cos(baseAngle + spreadAngle),
      y: point.y + footSize * sin(baseAngle + spreadAngle)
    )
    let lowerEnd = CGPoint(
      x: point.x + footSize * cos(baseAngle - spreadAngle),
      y: point.y + footSize * sin(baseAngle - spreadAngle)
    )

    context.move(to: point)
    context.addLine(to: centerEnd)
    context.strokePath()

    context.move(to: point)
    context.addLine(to: upperEnd)
    context.strokePath()

    context.move(to: point)
    context.addLine(to: lowerEnd)
    context.strokePath()
  }

  /// Draw "one" notation - a single vertical line perpendicular to the connection
  func drawOneNotation(
    _ context: CGContext, at point: CGPoint, from midPoint: CGPoint, highlighted: Bool
  ) {
    let lineLength: CGFloat = 8
    let offsetDist: CGFloat = 6

    let strokeColor = highlighted ? edgeHighlightColor : edgeColor
    let lineWidth: CGFloat = highlighted ? 1.5 : 0.75

    context.setStrokeColor(strokeColor.cgColor)
    context.setLineWidth(lineWidth)

    let dx = point.x - midPoint.x
    let dy = point.y - midPoint.y
    let length = sqrt(dx * dx + dy * dy)

    guard length > 0 else { return }

    let nx = dx / length
    let ny = dy / length

    // Line center is offset back from the endpoint
    let lineCenter = CGPoint(
      x: point.x - nx * offsetDist,
      y: point.y - ny * offsetDist
    )

    // Perpendicular direction
    let perpX = -ny * (lineLength / 2)
    let perpY = nx * (lineLength / 2)

    let lineStart = CGPoint(x: lineCenter.x + perpX, y: lineCenter.y + perpY)
    let lineEnd = CGPoint(x: lineCenter.x - perpX, y: lineCenter.y - perpY)

    context.move(to: lineStart)
    context.addLine(to: lineEnd)
    context.strokePath()
  }

  /// Draw "zero or" notation - a small circle on the line (indicates optional)
  func drawZeroCircle(
    _ context: CGContext, at point: CGPoint, from midPoint: CGPoint, highlighted: Bool,
    offsetDistance: CGFloat = 14
  ) {
    let circleRadius: CGFloat = 4

    let strokeColor = highlighted ? edgeHighlightColor : edgeColor
    let lineWidth: CGFloat = highlighted ? 1.5 : 0.75

    context.setStrokeColor(strokeColor.cgColor)
    context.setFillColor(nodeBackgroundColor.cgColor)
    context.setLineWidth(lineWidth)

    let dx = point.x - midPoint.x
    let dy = point.y - midPoint.y
    let length = sqrt(dx * dx + dy * dy)

    guard length > 0 else { return }

    let nx = dx / length
    let ny = dy / length

    // Circle center is offset back from the endpoint
    let circleCenter = CGPoint(
      x: point.x - nx * offsetDistance,
      y: point.y - ny * offsetDistance
    )

    let circleRect = CGRect(
      x: circleCenter.x - circleRadius,
      y: circleCenter.y - circleRadius,
      width: circleRadius * 2,
      height: circleRadius * 2
    )

    // Draw filled circle with stroke
    context.addEllipse(in: circleRect)
    context.drawPath(using: .fillStroke)
  }
}
