//
//  SchemaGraphView+Export.swift
//  SQLNotebook
//
//  Export to image functionality for schema graph visualization
//

import AppKit
import SwiftUI

// MARK: - Export Extension

extension SchemaGraphNSView {

  /// Render the schema graph to an NSImage with auto-crop to the smallest bounding box containing all cards
  /// - Parameters:
  ///   - padding: Extra padding around the bounding box (default: 40 points)
  ///   - includeBackground: Whether to include the background color and dot pattern (default: true)
  /// - Returns: NSImage containing the rendered schema graph, or nil if no nodes exist
  func renderToImage(padding: CGFloat = 40, includeBackground: Bool = true) -> NSImage? {
    guard !graph.nodes.isEmpty else { return nil }

    // Calculate bounding box of all nodes
    var minX = CGFloat.infinity
    var minY = CGFloat.infinity
    var maxX = -CGFloat.infinity
    var maxY = -CGFloat.infinity

    for node in graph.nodes {
      let rect = nodeRect(for: node)
      minX = min(minX, rect.minX)
      minY = min(minY, rect.minY)
      maxX = max(maxX, rect.maxX)
      maxY = max(maxY, rect.maxY)
    }

    // Add padding
    minX -= padding
    minY -= padding
    maxX += padding
    maxY += padding

    let boundingWidth = maxX - minX
    let boundingHeight = maxY - minY

    // Create image with the bounding box size
    let imageSize = NSSize(width: boundingWidth, height: boundingHeight)
    let image = NSImage(size: imageSize)

    image.lockFocus()
    guard let context = NSGraphicsContext.current?.cgContext else {
      image.unlockFocus()
      return nil
    }

    if includeBackground {
      // Fill background
      context.setFillColor(NSColor(Color.appBackground).cgColor)
      context.fill(CGRect(origin: .zero, size: imageSize))

      // Draw dot pattern background for the visible area
      drawDotPatternForExport(context, size: imageSize, offsetX: minX, offsetY: minY)
    }
    // If not including background, the image will have transparent background

    // Translate to account for the bounding box offset
    context.translateBy(x: -minX, y: -minY)

    // Draw edges first (at scale 1.0)
    drawEdgesForExport(context)

    // Draw nodes
    drawNodesForExport(context)

    image.unlockFocus()

    return image
  }

  /// Draw dot pattern for export (similar to drawDotPattern but for export context)
  func drawDotPatternForExport(
    _ context: CGContext, size: NSSize, offsetX: CGFloat, offsetY: CGFloat
  ) {
    let dotSpacing: CGFloat = 20
    let dotRadius: CGFloat = 1.0
    let dotColor = NSColor(Color.foregroundMuted).withAlphaComponent(0.15)

    context.saveGState()
    context.setFillColor(dotColor.cgColor)

    // Calculate visible area
    let visibleRect = CGRect(
      x: offsetX,
      y: offsetY,
      width: size.width,
      height: size.height
    )

    // Calculate start positions (aligned to grid)
    let startX = floor(visibleRect.minX / dotSpacing) * dotSpacing
    let startY = floor(visibleRect.minY / dotSpacing) * dotSpacing

    // Translate for canvas coordinates
    context.translateBy(x: -offsetX, y: -offsetY)

    // Draw dots
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
        y += dotSpacing
      }
      x += dotSpacing
    }

    context.restoreGState()
  }

  /// Draw edges for export (without hover/selection states)
  func drawEdgesForExport(_ context: CGContext) {
    // Collect all node rects for obstacle avoidance
    let allNodeRects: [CGRect] = graph.nodes.map { nodeRect(for: $0) }

    for edge in graph.edges {
      guard
        let sourceNode = graph.node(withId: edge.sourceNodeId),
        let targetNode = graph.node(withId: edge.targetNodeId)
      else { continue }

      let sourceRect = nodeRect(for: sourceNode)
      let targetRect = nodeRect(for: targetNode)

      drawOrthogonalEdgeForExport(
        context,
        edge: edge,
        from: sourceRect,
        to: targetRect,
        obstacleRects: allNodeRects
      )
    }
  }

  /// Draw orthogonal edge for export with obstacle avoidance
  func drawOrthogonalEdgeForExport(
    _ context: CGContext,
    edge: SchemaEdge,
    from sourceRect: CGRect,
    to targetRect: CGRect,
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

    // Draw main path (non-highlighted style)
    context.setStrokeColor(edgeColor.cgColor)
    context.setLineWidth(0.75)

    context.move(to: points[0])
    for i in 1..<points.count {
      context.addLine(to: points[i])
    }
    context.strokePath()

    // Draw ER notation symbols
    let startPoint = routedPath.startPoint
    let secondPoint = routedPath.secondPoint
    let endPoint = routedPath.endPoint
    let secondToLastPoint = routedPath.secondToLastPoint

    drawZeroCircle(
      context, at: startPoint, from: secondPoint, highlighted: false, offsetDistance: 16)
    drawCrowsFoot(context, at: startPoint, toward: secondPoint, highlighted: false)
    drawZeroCircle(
      context, at: endPoint, from: secondToLastPoint, highlighted: false, offsetDistance: 14)
    drawOneNotation(context, at: endPoint, from: secondToLastPoint, highlighted: false)
  }

  /// Draw nodes for export (without hover/selection states)
  func drawNodesForExport(_ context: CGContext) {
    for node in graph.nodes {
      let rect = nodeRect(for: node)

      // Draw shadow
      context.saveGState()
      context.setShadow(
        offset: CGSize(width: 0, height: 2), blur: 4,
        color: NSColor.black.withAlphaComponent(0.15).cgColor)

      // Draw node background
      let path = CGPath(
        roundedRect: rect, cornerWidth: nodeCornerRadius, cornerHeight: nodeCornerRadius,
        transform: nil)
      context.addPath(path)
      context.setFillColor(nodeBackgroundColor.cgColor)
      context.fillPath()

      context.restoreGState()

      // Draw header background
      let headerRect = CGRect(
        x: rect.minX, y: rect.minY, width: rect.width, height: nodeHeaderHeight)
      let headerPath = CGMutablePath()
      headerPath.move(to: CGPoint(x: rect.minX + nodeCornerRadius, y: rect.minY))
      headerPath.addLine(to: CGPoint(x: rect.maxX - nodeCornerRadius, y: rect.minY))
      headerPath.addArc(
        center: CGPoint(x: rect.maxX - nodeCornerRadius, y: rect.minY + nodeCornerRadius),
        radius: nodeCornerRadius, startAngle: -.pi / 2, endAngle: 0, clockwise: false)
      headerPath.addLine(to: CGPoint(x: rect.maxX, y: headerRect.maxY))
      headerPath.addLine(to: CGPoint(x: rect.minX, y: headerRect.maxY))
      headerPath.addLine(to: CGPoint(x: rect.minX, y: rect.minY + nodeCornerRadius))
      headerPath.addArc(
        center: CGPoint(x: rect.minX + nodeCornerRadius, y: rect.minY + nodeCornerRadius),
        radius: nodeCornerRadius, startAngle: .pi, endAngle: -.pi / 2, clockwise: false)
      headerPath.closeSubpath()

      context.addPath(headerPath)
      context.setFillColor(nodeHeaderColor.cgColor)
      context.fillPath()

      // Draw border (default style)
      context.addPath(path)
      context.setStrokeColor(nodeBorderColor.cgColor)
      context.setLineWidth(1)
      context.strokePath()

      // Draw table name
      let tableName = node.table.name
      let tableFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
      let tablePoint = CGPoint(x: rect.minX + 10, y: rect.minY + 8)
      let tableAttributes: [NSAttributedString.Key: Any] = [
        .font: tableFont,
        .foregroundColor: textColor,
      ]
      let tableString = NSAttributedString(string: tableName, attributes: tableAttributes)
      tableString.draw(at: tablePoint)

      // Draw column count badge
      let columnCount = node.table.columns.count
      let countFont = NSFont.systemFont(ofSize: 9, weight: .medium)
      let countAttributes: [NSAttributedString.Key: Any] = [
        .font: countFont,
        .foregroundColor: subtleTextColor,
      ]
      let countString = NSAttributedString(string: "\(columnCount)", attributes: countAttributes)
      let countSize = countString.size()
      let countPoint = CGPoint(x: rect.maxX - countSize.width - 10, y: rect.minY + 10)
      countString.draw(at: countPoint)

      // Draw columns
      drawColumnsForExport(context, node: node, rect: rect)
    }
  }

  /// Draw columns for export (without search highlighting)
  func drawColumnsForExport(_ context: CGContext, node: SchemaNode, rect: CGRect) {
    let columns = node.table.columns
    let columnFont = NSFont.systemFont(ofSize: 9, weight: .regular)
    let pkFont = NSFont.systemFont(ofSize: 9, weight: .medium)
    let typeFont = NSFont.monospacedSystemFont(ofSize: 8, weight: .regular)
    let iconFont = NSFont.systemFont(ofSize: 8, weight: .medium)

    for (index, column) in columns.enumerated() {
      let y = rect.minY + nodeHeaderHeight + 4 + CGFloat(index) * nodeColumnHeight

      // Draw column attribute icons
      var iconX = rect.minX + 6
      let iconSpacing: CGFloat = 10

      if column.isPrimaryKey {
        drawSFSymbol("key.fill", at: CGPoint(x: iconX, y: y), color: .systemYellow, font: iconFont)
        iconX += iconSpacing
      }

      if column.isIdentity {
        drawSFSymbol("number", at: CGPoint(x: iconX, y: y), color: .systemBlue, font: iconFont)
        iconX += iconSpacing
      }

      if column.isUnique {
        drawSFSymbol("touchid", at: CGPoint(x: iconX, y: y), color: .systemPurple, font: iconFont)
        iconX += iconSpacing
      }

      if column.isNullable {
        drawSFSymbol("diamond", at: CGPoint(x: iconX, y: y), color: subtleTextColor, font: iconFont)
      } else {
        drawSFSymbol(
          "diamond.fill", at: CGPoint(x: iconX, y: y), color: .systemGray, font: iconFont)
      }
      iconX += iconSpacing

      // Calculate available width for column name
      let typeAttributes: [NSAttributedString.Key: Any] = [
        .font: typeFont,
        .foregroundColor: subtleTextColor.withAlphaComponent(0.7),
      ]
      let typeString = NSAttributedString(string: column.type, attributes: typeAttributes)
      let typeSize = typeString.size()
      let typeX = rect.maxX - typeSize.width - 8
      let nameStartX = iconX + 2
      let maxNameWidth = typeX - nameStartX - columnTypeGap

      // Draw column name (truncated if needed)
      let hasSpecialAttributes = column.isPrimaryKey || column.isIdentity || column.isUnique
      let nameFont = hasSpecialAttributes ? pkFont : columnFont
      let nameColor = hasSpecialAttributes ? textColor : columnTextColor
      let namePoint = CGPoint(x: nameStartX, y: y)

      let truncatedName = truncateText(column.name, font: nameFont, maxWidth: maxNameWidth)
      let nameAttributes: [NSAttributedString.Key: Any] = [
        .font: nameFont,
        .foregroundColor: nameColor,
      ]
      let nameString = NSAttributedString(string: truncatedName, attributes: nameAttributes)
      nameString.draw(at: namePoint)

      // Draw type on the right
      typeString.draw(at: CGPoint(x: typeX, y: y + 1))
    }
  }
}
