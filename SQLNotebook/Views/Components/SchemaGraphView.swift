//
//  SchemaGraphView.swift
//  SQLNotebook
//
//  Interactive schema graph visualization using Core Graphics
//

import AppKit
import SwiftUI

/// SwiftUI wrapper for the schema graph visualization
struct SchemaGraphView: NSViewRepresentable {
  @Binding var graph: SchemaGraph
  @Binding var scale: CGFloat
  @Binding var offset: CGPoint
  @Binding var selectedNodeId: UUID?
  var searchState: SchemaSearchState
  var onNodeDoubleClick: ((SchemaNode) -> Void)?

  func makeNSView(context: Context) -> SchemaGraphNSView {
    let view = SchemaGraphNSView()
    view.graph = graph
    view.scale = scale
    view.offset = offset
    view.selectedNodeId = selectedNodeId
    view.searchState = searchState
    view.onNodeSelected = { nodeId in
      DispatchQueue.main.async {
        selectedNodeId = nodeId
      }
    }
    view.onNodeMoved = { nodeId, newPosition in
      DispatchQueue.main.async {
        if let index = graph.nodes.firstIndex(where: { $0.id == nodeId }) {
          graph.nodes[index].position = newPosition
        }
      }
    }
    view.onNodeDoubleClick = onNodeDoubleClick
    view.onOffsetChanged = { newOffset in
      DispatchQueue.main.async {
        offset = newOffset
      }
    }
    view.onScaleChanged = { newScale in
      DispatchQueue.main.async {
        scale = newScale
      }
    }
    return view
  }

  func updateNSView(_ nsView: SchemaGraphNSView, context: Context) {
    nsView.graph = graph
    nsView.scale = scale
    nsView.offset = offset
    nsView.selectedNodeId = selectedNodeId
    nsView.searchState = searchState
    nsView.needsDisplay = true
  }
}

// MARK: - Schema Graph NSView

/// Custom NSView that renders the schema graph with Core Graphics
@MainActor
class SchemaGraphNSView: NSView {

  // MARK: - Properties

  var graph: SchemaGraph = SchemaGraph() {
    didSet { needsDisplay = true }
  }

  var scale: CGFloat = 1.0 {
    didSet { needsDisplay = true }
  }

  var offset: CGPoint = .zero {
    didSet { needsDisplay = true }
  }

  var selectedNodeId: UUID? {
    didSet { needsDisplay = true }
  }

  var searchState: SchemaSearchState = SchemaSearchState() {
    didSet { needsDisplay = true }
  }

  var onNodeSelected: ((UUID?) -> Void)?
  var onNodeMoved: ((UUID, CGPoint) -> Void)?
  var onNodeDoubleClick: ((SchemaNode) -> Void)?
  var onOffsetChanged: ((CGPoint) -> Void)?
  var onScaleChanged: ((CGFloat) -> Void)?

  // Node size
  private let nodeWidth: CGFloat = 200
  private let nodeHeaderHeight: CGFloat = 32
  private let nodeColumnHeight: CGFloat = 18
  private let nodeCornerRadius: CGFloat = 8
  private let nodePadding: CGFloat = 8
  private let expandButtonSize: CGFloat = 16

  // Colors (cached for performance)
  private var nodeBackgroundColor: NSColor = .white
  private var nodeHeaderColor: NSColor = .lightGray
  private var nodeBorderColor: NSColor = .gray
  private var nodeSelectedBorderColor: NSColor = .blue
  private var edgeColor: NSColor = .gray
  private var edgeHighlightColor: NSColor = .blue
  private var textColor: NSColor = .black
  private var subtleTextColor: NSColor = .gray
  private var columnTextColor: NSColor = .gray

  // Drag state
  private var isDraggingNode: Bool = false
  private var isDraggingCanvas: Bool = false
  private var draggedNodeId: UUID?
  private var lastMouseLocation: CGPoint = .zero

  // Hover state for edges, expand button, and nodes
  private var hoveredEdgeId: UUID?
  private var hoveredExpandButtonNodeId: UUID?
  private var hoveredNodeId: UUID?
  private var trackingArea: NSTrackingArea?

  // Hover delay for highlighting connected tables
  private var edgeHoverTimer: Timer?
  private var highlightedEdgeId: UUID?  // Edge that has passed the hover delay
  private var selectedEdgeId: UUID?  // Edge that was clicked
  private let edgeHoverDelay: TimeInterval = 0.3  // 300ms delay before highlighting tables

  // MARK: - Initialization

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setupView()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupView()
  }

  private func setupView() {
    wantsLayer = true
    layer?.masksToBounds = true
    updateColors()
    setupTrackingArea()
  }

  private func setupTrackingArea() {
    if let existingArea = trackingArea {
      removeTrackingArea(existingArea)
    }
    trackingArea = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    if let area = trackingArea {
      addTrackingArea(area)
    }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    setupTrackingArea()
  }

  private func updateColors() {
    nodeBackgroundColor = NSColor(Color.cardBackground)
    nodeHeaderColor = NSColor(Color.schemaNodeHeader)
    nodeBorderColor = NSColor(Color.schemaNodeBorder)
    nodeSelectedBorderColor = NSColor(Color.accent)
    edgeColor = NSColor(Color.foregroundMuted).withAlphaComponent(0.5)
    edgeHighlightColor = NSColor(Color.accent)
    textColor = NSColor(Color.foreground)
    subtleTextColor = NSColor(Color.foregroundMuted)
    columnTextColor = NSColor(Color.schemaColumnText)
    layer?.backgroundColor = NSColor(Color.appBackground).cgColor
  }

  // MARK: - Coordinate Transforms

  private func screenToCanvas(_ point: CGPoint) -> CGPoint {
    CGPoint(
      x: (point.x - offset.x) / scale,
      y: (point.y - offset.y) / scale
    )
  }

  // MARK: - Drawing

  override var isFlipped: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }

    updateColors()

    // Clear background
    context.setFillColor(NSColor(Color.appBackground).cgColor)
    context.fill(bounds)

    // Draw dot pattern on background
    drawDotPattern(context)

    // Clip to bounds
    context.clip(to: bounds)

    // Apply transform
    context.saveGState()
    context.translateBy(x: offset.x, y: offset.y)
    context.scaleBy(x: scale, y: scale)

    // Draw edges first
    drawEdges(context)

    // Draw nodes
    drawNodes(context)

    context.restoreGState()
  }

  // MARK: - Dot Pattern Background

  private func drawDotPattern(_ context: CGContext) {
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

  private func drawEdges(_ context: CGContext) {
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

      // Draw orthogonal path with 90-degree turns
      drawOrthogonalEdge(
        context,
        edge: edge,
        from: sourceRect,
        to: targetRect,
        highlighted: isHighlighted
      )
    }
  }

  /// Draw orthogonal edge with proper 90-degree turns
  private func drawOrthogonalEdge(
    _ context: CGContext,
    edge: SchemaEdge,
    from sourceRect: CGRect,
    to targetRect: CGRect,
    highlighted: Bool
  ) {
    let sourceCenter = CGPoint(x: sourceRect.midX, y: sourceRect.midY)
    let targetCenter = CGPoint(x: targetRect.midX, y: targetRect.midY)

    let dx = targetCenter.x - sourceCenter.x
    let dy = targetCenter.y - sourceCenter.y

    var startPoint: CGPoint
    var endPoint: CGPoint
    var midPoint1: CGPoint
    var midPoint2: CGPoint

    if abs(dx) > abs(dy) {
      // Horizontal dominant
      if dx > 0 {
        startPoint = CGPoint(x: sourceRect.maxX, y: sourceRect.midY)
        endPoint = CGPoint(x: targetRect.minX, y: targetRect.midY)
      } else {
        startPoint = CGPoint(x: sourceRect.minX, y: sourceRect.midY)
        endPoint = CGPoint(x: targetRect.maxX, y: targetRect.midY)
      }
      let midX = (startPoint.x + endPoint.x) / 2
      midPoint1 = CGPoint(x: midX, y: startPoint.y)
      midPoint2 = CGPoint(x: midX, y: endPoint.y)
    } else {
      // Vertical dominant
      if dy > 0 {
        startPoint = CGPoint(x: sourceRect.midX, y: sourceRect.maxY)
        endPoint = CGPoint(x: targetRect.midX, y: targetRect.minY)
      } else {
        startPoint = CGPoint(x: sourceRect.midX, y: sourceRect.minY)
        endPoint = CGPoint(x: targetRect.midX, y: targetRect.maxY)
      }
      let midY = (startPoint.y + endPoint.y) / 2
      midPoint1 = CGPoint(x: startPoint.x, y: midY)
      midPoint2 = CGPoint(x: endPoint.x, y: midY)
    }

    // Store edge path for hit testing
    let edgePath = EdgePath(
      id: edge.id,
      startPoint: startPoint,
      midPoint1: midPoint1,
      midPoint2: midPoint2,
      endPoint: endPoint
    )
    cachedEdgePaths[edge.id] = edgePath

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
      context.move(to: startPoint)
      context.addLine(to: midPoint1)
      context.addLine(to: midPoint2)
      context.addLine(to: endPoint)
      context.strokePath()
      context.restoreGState()
    }

    // Draw main path
    context.setStrokeColor(strokeColor.cgColor)
    context.setLineWidth(lineWidth)

    context.move(to: startPoint)
    context.addLine(to: midPoint1)
    context.addLine(to: midPoint2)
    context.addLine(to: endPoint)
    context.strokePath()

    // Draw ER notation symbols
    // Source side: "many" (crow's foot) - FK table can have many rows referencing one PK
    // Also draw zero circle to indicate "zero or many" (optional relationship)
    drawZeroCircle(
      context, at: startPoint, from: midPoint1, highlighted: highlighted, offsetDistance: 16)
    drawCrowsFoot(context, at: startPoint, toward: midPoint1, highlighted: highlighted)

    // Target side: "one" (single line) - PK table has one row being referenced
    // Also draw zero circle to indicate "zero or one" possibility
    drawZeroCircle(
      context, at: endPoint, from: midPoint2, highlighted: highlighted, offsetDistance: 14)
    drawOneNotation(context, at: endPoint, from: midPoint2, highlighted: highlighted)
  }

  private func drawCrowsFoot(
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
  private func drawOneNotation(
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
  private func drawZeroCircle(
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

  // MARK: - Edge Path Cache for Hit Testing

  private struct EdgePath {
    let id: UUID
    let startPoint: CGPoint
    let midPoint1: CGPoint
    let midPoint2: CGPoint
    let endPoint: CGPoint

    /// Check if a point is near this edge path
    func contains(_ point: CGPoint, threshold: CGFloat = 8) -> Bool {
      // Check distance to each segment
      let segments = [
        (startPoint, midPoint1),
        (midPoint1, midPoint2),
        (midPoint2, endPoint),
      ]

      for (p1, p2) in segments {
        if distanceToSegment(point: point, segmentStart: p1, segmentEnd: p2) < threshold {
          return true
        }
      }
      return false
    }

    private func distanceToSegment(
      point: CGPoint, segmentStart: CGPoint, segmentEnd: CGPoint
    )
      -> CGFloat
    {
      let dx = segmentEnd.x - segmentStart.x
      let dy = segmentEnd.y - segmentStart.y
      let lengthSquared = dx * dx + dy * dy

      if lengthSquared == 0 {
        return hypot(point.x - segmentStart.x, point.y - segmentStart.y)
      }

      var t = ((point.x - segmentStart.x) * dx + (point.y - segmentStart.y) * dy) / lengthSquared
      t = max(0, min(1, t))

      let nearestX = segmentStart.x + t * dx
      let nearestY = segmentStart.y + t * dy

      return hypot(point.x - nearestX, point.y - nearestY)
    }
  }

  private var cachedEdgePaths: [UUID: EdgePath] = [:]

  /// Hit test for edges
  private func hitTestEdge(at point: CGPoint) -> SchemaEdge? {
    let canvasPoint = screenToCanvas(point)

    for edge in graph.edges {
      if let edgePath = cachedEdgePaths[edge.id],
        edgePath.contains(canvasPoint, threshold: 8 / scale)
      {
        return edge
      }
    }
    return nil
  }

  // MARK: - Node Drawing

  /// Check if a node should be highlighted due to edge hover/selection
  private func isNodeHighlightedByEdge(_ nodeId: UUID) -> Bool {
    // Check if node is connected to highlighted edge (after hover delay)
    if let edgeId = highlightedEdgeId ?? selectedEdgeId,
      let edge = graph.edges.first(where: { $0.id == edgeId })
    {
      return edge.sourceNodeId == nodeId || edge.targetNodeId == nodeId
    }
    return false
  }

  private func drawNodes(_ context: CGContext) {
    for node in graph.nodes {
      let rect = nodeRect(for: node)
      let isSelected = selectedNodeId == node.id
      let isHovered = hoveredNodeId == node.id
      let isHighlightedByEdge = isNodeHighlightedByEdge(node.id)

      // Draw shadow (stronger when highlighted by edge or hovered)
      context.saveGState()
      if isHighlightedByEdge {
        context.setShadow(
          offset: CGSize(width: 0, height: 3), blur: 8,
          color: edgeHighlightColor.withAlphaComponent(0.4).cgColor)
      } else if isHovered && !isSelected {
        context.setShadow(
          offset: CGSize(width: 0, height: 3), blur: 6,
          color: NSColor.white.withAlphaComponent(0.2).cgColor)
      } else {
        context.setShadow(
          offset: CGSize(width: 0, height: 2), blur: 4,
          color: NSColor.black.withAlphaComponent(0.15).cgColor)
      }

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

      // Draw border (highlighted when selected, hovered, or connected to highlighted edge)
      context.addPath(path)
      let borderColor: NSColor
      let borderWidth: CGFloat
      if isSelected || isHighlightedByEdge {
        borderColor = nodeSelectedBorderColor
        borderWidth = 2
      } else if isHovered {
        // Lighter border on hover (more visible in dark mode)
        borderColor = nodeBorderColor.blended(withFraction: 0.5, of: .white) ?? nodeBorderColor
        borderWidth = 1.5
      } else {
        borderColor = nodeBorderColor
        borderWidth = 1
      }
      context.setStrokeColor(borderColor.cgColor)
      context.setLineWidth(borderWidth)
      context.strokePath()

      // Draw table name (with search highlight if matching)
      let tableName = node.table.name
      let tableFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
      let tablePoint = CGPoint(x: rect.minX + 10, y: rect.minY + 8)

      // Check if table name has search match
      let tableNameMatch = searchState.matches.first {
        $0.nodeId == node.id && $0.matchType == .tableName
      }

      if let match = tableNameMatch, !searchState.query.isEmpty {
        drawHighlightedText(
          context,
          text: tableName,
          at: tablePoint,
          font: tableFont,
          textColor: textColor,
          highlightRange: match.matchRange,
          isCurrentMatch: searchState.currentMatch?.id == match.id
        )
      } else {
        let tableAttributes: [NSAttributedString.Key: Any] = [
          .font: tableFont,
          .foregroundColor: textColor,
        ]
        let tableString = NSAttributedString(string: tableName, attributes: tableAttributes)
        tableString.draw(at: tablePoint)
      }

      // Draw expand button (arrow.up.left.and.arrow.down.right icon)
      let expandButtonRect = expandButtonRect(for: node)
      drawExpandButton(
        context, in: expandButtonRect, isHovered: hoveredExpandButtonNodeId == node.id)

      // Draw column count badge (moved to left of expand button)
      let columnCount = node.table.columns.count
      let countFont = NSFont.systemFont(ofSize: 9, weight: .medium)
      let countAttributes: [NSAttributedString.Key: Any] = [
        .font: countFont,
        .foregroundColor: subtleTextColor,
      ]
      let countString = NSAttributedString(string: "\(columnCount)", attributes: countAttributes)
      let countSize = countString.size()
      let countPoint = CGPoint(x: expandButtonRect.minX - countSize.width - 6, y: rect.minY + 10)
      countString.draw(at: countPoint)

      // Draw ALL columns
      drawColumns(context, node: node, rect: rect)
    }
  }

  private func drawColumns(_ context: CGContext, node: SchemaNode, rect: CGRect) {
    let columns = node.table.columns
    let columnFont = NSFont.systemFont(ofSize: 9, weight: .regular)
    let pkFont = NSFont.systemFont(ofSize: 9, weight: .medium)
    let typeFont = NSFont.monospacedSystemFont(ofSize: 8, weight: .regular)
    let iconFont = NSFont.systemFont(ofSize: 8, weight: .medium)

    for (index, column) in columns.enumerated() {
      let y = rect.minY + nodeHeaderHeight + 4 + CGFloat(index) * nodeColumnHeight

      // Draw column attribute icons (SF Symbols)
      var iconX = rect.minX + 6
      let iconSpacing: CGFloat = 10

      // Primary key icon (yellow key)
      if column.isPrimaryKey {
        drawSFSymbol("key.fill", at: CGPoint(x: iconX, y: y), color: .systemYellow, font: iconFont)
        iconX += iconSpacing
      }

      // Identity icon (number symbol)
      if column.isIdentity {
        drawSFSymbol("number", at: CGPoint(x: iconX, y: y), color: .systemBlue, font: iconFont)
        iconX += iconSpacing
      }

      // Unique icon (touchid symbol)
      if column.isUnique {
        drawSFSymbol("touchid", at: CGPoint(x: iconX, y: y), color: .systemPurple, font: iconFont)
        iconX += iconSpacing
      }

      // Nullable / Non-nullable icon (diamond)
      if column.isNullable {
        drawSFSymbol("diamond", at: CGPoint(x: iconX, y: y), color: subtleTextColor, font: iconFont)
      } else {
        drawSFSymbol(
          "diamond.fill", at: CGPoint(x: iconX, y: y), color: .systemGray, font: iconFont)
      }
      iconX += iconSpacing

      // Draw column name (with search highlight if matching)
      let hasSpecialAttributes = column.isPrimaryKey || column.isIdentity || column.isUnique
      let nameFont = hasSpecialAttributes ? pkFont : columnFont
      let nameColor = hasSpecialAttributes ? textColor : columnTextColor
      let namePoint = CGPoint(x: iconX + 2, y: y)

      // Check if column name has search match
      let columnMatch = searchState.matches.first {
        $0.nodeId == node.id && $0.matchType == .columnName(columnIndex: index)
      }

      if let match = columnMatch, !searchState.query.isEmpty {
        drawHighlightedText(
          context,
          text: column.name,
          at: namePoint,
          font: nameFont,
          textColor: nameColor,
          highlightRange: match.matchRange,
          isCurrentMatch: searchState.currentMatch?.id == match.id
        )
      } else {
        let nameAttributes: [NSAttributedString.Key: Any] = [
          .font: nameFont,
          .foregroundColor: nameColor,
        ]
        let nameString = NSAttributedString(string: column.name, attributes: nameAttributes)
        nameString.draw(at: namePoint)
      }

      // Draw type on the right
      let typeAttributes: [NSAttributedString.Key: Any] = [
        .font: typeFont,
        .foregroundColor: subtleTextColor.withAlphaComponent(0.7),
      ]
      let typeString = NSAttributedString(string: column.type, attributes: typeAttributes)
      let typeSize = typeString.size()
      typeString.draw(at: CGPoint(x: rect.maxX - typeSize.width - 8, y: y + 1))
    }
  }

  /// Draw an SF Symbol at the specified location
  private func drawSFSymbol(_ name: String, at point: CGPoint, color: NSColor, font: NSFont) {
    if let symbolImage = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
      let config = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .medium)
      let configuredImage = symbolImage.withSymbolConfiguration(config)

      // Draw the symbol
      let imageSize = CGSize(width: 8, height: 8)
      let imageRect = CGRect(origin: point, size: imageSize)

      // Apply color tint
      let tintedImage = configuredImage?.copy() as? NSImage
      tintedImage?.lockFocus()
      color.set()
      NSRect(origin: .zero, size: tintedImage?.size ?? .zero).fill(using: .sourceAtop)
      tintedImage?.unlockFocus()

      tintedImage?.draw(in: imageRect)
    }
  }

  /// Draw text with highlighted search match (zoom-independent highlight)
  /// The highlight background is drawn using absolute pixel values to maintain consistent size at any zoom level
  private func drawHighlightedText(
    _ context: CGContext,
    text: String,
    at point: CGPoint,
    font: NSFont,
    textColor: NSColor,
    highlightRange: Range<String.Index>,
    isCurrentMatch: Bool
  ) {
    // Create attributed string for the full text
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineBreakMode = .byClipping

    let baseAttributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: textColor,
      .paragraphStyle: paragraphStyle,
    ]

    // Calculate positions for highlight
    let beforeHighlight = String(text[..<highlightRange.lowerBound])
    let highlightedPart = String(text[highlightRange])
    let afterHighlight = String(text[highlightRange.upperBound...])

    // Measure text widths
    let beforeWidth =
      (beforeHighlight as NSString).size(withAttributes: baseAttributes).width
    let highlightWidth =
      (highlightedPart as NSString).size(withAttributes: baseAttributes).width
    let textHeight = (text as NSString).size(withAttributes: baseAttributes).height

    // Draw highlight background (using fixed pixel values, not scaled)
    // Save state to apply inverse scale for highlight rect
    context.saveGState()

    // Calculate highlight rect in canvas coordinates
    let highlightPadding: CGFloat = 1
    let highlightRect = CGRect(
      x: point.x + beforeWidth - highlightPadding,
      y: point.y - 1,
      width: highlightWidth + highlightPadding * 2,
      height: textHeight + 2
    )

    // Draw highlight with rounded corners
    let highlightColor =
      isCurrentMatch
      ? NSColor.systemYellow.withAlphaComponent(0.8)  // Current match: bright yellow
      : NSColor.systemYellow.withAlphaComponent(0.4)  // Other matches: dimmer yellow

    context.setFillColor(highlightColor.cgColor)
    let highlightPath = CGPath(
      roundedRect: highlightRect, cornerWidth: 2, cornerHeight: 2, transform: nil)
    context.addPath(highlightPath)
    context.fillPath()

    // Draw border for current match
    if isCurrentMatch {
      context.setStrokeColor(NSColor.systemOrange.cgColor)
      context.setLineWidth(1)
      context.addPath(highlightPath)
      context.strokePath()
    }

    context.restoreGState()

    // Draw the text on top
    // Before highlight part
    if !beforeHighlight.isEmpty {
      let beforeString = NSAttributedString(string: beforeHighlight, attributes: baseAttributes)
      beforeString.draw(at: point)
    }

    // Highlighted part (same attributes, the background provides the highlight)
    let highlightedString = NSAttributedString(string: highlightedPart, attributes: baseAttributes)
    highlightedString.draw(at: CGPoint(x: point.x + beforeWidth, y: point.y))

    // After highlight part
    if !afterHighlight.isEmpty {
      let afterString = NSAttributedString(string: afterHighlight, attributes: baseAttributes)
      afterString.draw(at: CGPoint(x: point.x + beforeWidth + highlightWidth, y: point.y))
    }
  }

  /// Calculate node rect - height based on ALL columns
  private func nodeRect(for node: SchemaNode) -> CGRect {
    let columnsCount = node.table.columns.count
    let height = nodeHeaderHeight + CGFloat(columnsCount) * nodeColumnHeight + nodePadding

    return CGRect(
      x: node.position.x,
      y: node.position.y,
      width: nodeWidth,
      height: max(height, 60)
    )
  }

  /// Calculate expand button rect for a node
  private func expandButtonRect(for node: SchemaNode) -> CGRect {
    let nodeR = nodeRect(for: node)
    return CGRect(
      x: nodeR.maxX - expandButtonSize - 6,
      y: nodeR.minY + (nodeHeaderHeight - expandButtonSize) / 2,
      width: expandButtonSize,
      height: expandButtonSize
    )
  }

  /// Draw expand button with hover effect
  private func drawExpandButton(_ context: CGContext, in rect: CGRect, isHovered: Bool) {
    // Draw background on hover
    if isHovered {
      context.setFillColor(NSColor.white.withAlphaComponent(0.2).cgColor)
      let bgPath = CGPath(
        roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil)
      context.addPath(bgPath)
      context.fillPath()
    }

    // Draw the expand icon (arrow.up.left.and.arrow.down.right)
    let iconFont = NSFont.systemFont(ofSize: 10, weight: .medium)
    drawSFSymbol(
      "arrow.up.left.and.arrow.down.right",
      at: CGPoint(x: rect.minX + 4, y: rect.minY + 4),
      color: isHovered ? textColor : subtleTextColor,
      font: iconFont
    )
  }

  // MARK: - Hit Testing

  private func hitTestNode(at point: CGPoint) -> SchemaNode? {
    let canvasPoint = screenToCanvas(point)
    for node in graph.nodes.reversed() {
      if nodeRect(for: node).contains(canvasPoint) {
        return node
      }
    }
    return nil
  }

  /// Hit test for expand button
  private func hitTestExpandButton(at point: CGPoint) -> SchemaNode? {
    let canvasPoint = screenToCanvas(point)
    for node in graph.nodes.reversed() {
      if expandButtonRect(for: node).contains(canvasPoint) {
        return node
      }
    }
    return nil
  }

  // MARK: - Mouse Events

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    lastMouseLocation = point

    // Check if clicking expand button first
    if let node = hitTestExpandButton(at: point) {
      // Trigger the same action as double-click
      onNodeDoubleClick?(node)
      return
    }

    // Check if clicking on an edge
    if let edge = hitTestEdge(at: point) {
      // Select/deselect edge
      if selectedEdgeId == edge.id {
        selectedEdgeId = nil
      } else {
        selectedEdgeId = edge.id
      }
      // Clear node selection when selecting edge
      onNodeSelected?(nil)
      needsDisplay = true
      return
    }

    if let node = hitTestNode(at: point) {
      isDraggingNode = true
      isDraggingCanvas = false
      draggedNodeId = node.id
      selectedEdgeId = nil  // Clear edge selection when selecting node
      onNodeSelected?(node.id)
    } else {
      isDraggingCanvas = true
      isDraggingNode = false
      draggedNodeId = nil
      selectedEdgeId = nil  // Clear edge selection when clicking canvas
      onNodeSelected?(nil)
    }
    needsDisplay = true
  }

  override func mouseDragged(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    let deltaX = point.x - lastMouseLocation.x
    let deltaY = point.y - lastMouseLocation.y

    if isDraggingNode, let nodeId = draggedNodeId {
      if let index = graph.nodes.firstIndex(where: { $0.id == nodeId }) {
        let newPosition = CGPoint(
          x: graph.nodes[index].position.x + deltaX / scale,
          y: graph.nodes[index].position.y + deltaY / scale
        )
        graph.nodes[index].position = newPosition
        onNodeMoved?(nodeId, newPosition)
        needsDisplay = true
      }
    } else if isDraggingCanvas {
      offset.x += deltaX
      offset.y += deltaY
      onOffsetChanged?(offset)
      needsDisplay = true
    }

    lastMouseLocation = point
  }

  override func mouseUp(with event: NSEvent) {
    if event.clickCount == 2 {
      let point = convert(event.locationInWindow, from: nil)
      if let node = hitTestNode(at: point) {
        onNodeDoubleClick?(node)
      }
    }

    isDraggingNode = false
    isDraggingCanvas = false
    draggedNodeId = nil
  }

  override func mouseMoved(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    var needsRedraw = false

    // Check if hovering over an expand button
    if let node = hitTestExpandButton(at: point) {
      if hoveredExpandButtonNodeId != node.id {
        hoveredExpandButtonNodeId = node.id
        needsRedraw = true
      }
    } else if hoveredExpandButtonNodeId != nil {
      hoveredExpandButtonNodeId = nil
      needsRedraw = true
    }

    // Check if hovering over a node (for hover effect)
    if let node = hitTestNode(at: point) {
      if hoveredNodeId != node.id {
        hoveredNodeId = node.id
        needsRedraw = true
      }
    } else if hoveredNodeId != nil {
      hoveredNodeId = nil
      needsRedraw = true
    }

    // Check if hovering over an edge
    if let edge = hitTestEdge(at: point) {
      if hoveredEdgeId != edge.id {
        hoveredEdgeId = edge.id
        needsRedraw = true

        // Cancel previous timer and start new one for hover delay
        edgeHoverTimer?.invalidate()
        highlightedEdgeId = nil  // Reset highlighted edge immediately

        // Start timer to highlight connected tables after delay
        edgeHoverTimer = Timer.scheduledTimer(withTimeInterval: edgeHoverDelay, repeats: false) {
          [weak self] _ in
          Task { @MainActor in
            self?.highlightedEdgeId = edge.id
            self?.needsDisplay = true
          }
        }
      }
    } else if hoveredEdgeId != nil {
      hoveredEdgeId = nil
      highlightedEdgeId = nil  // Clear highlighted edge when not hovering
      edgeHoverTimer?.invalidate()
      edgeHoverTimer = nil
      needsRedraw = true
    }

    if needsRedraw {
      needsDisplay = true
    }
  }

  override func mouseExited(with event: NSEvent) {
    var needsRedraw = false
    if hoveredEdgeId != nil {
      hoveredEdgeId = nil
      needsRedraw = true
    }
    if hoveredExpandButtonNodeId != nil {
      hoveredExpandButtonNodeId = nil
      needsRedraw = true
    }
    if hoveredNodeId != nil {
      hoveredNodeId = nil
      needsRedraw = true
    }
    if highlightedEdgeId != nil {
      highlightedEdgeId = nil
      needsRedraw = true
    }
    edgeHoverTimer?.invalidate()
    edgeHoverTimer = nil

    if needsRedraw {
      needsDisplay = true
    }
  }

  // MARK: - Scroll Wheel (Zoom)

  override func scrollWheel(with event: NSEvent) {
    let mouseLocation = convert(event.locationInWindow, from: nil)
    let canvasPointBefore = screenToCanvas(mouseLocation)

    // Scroll = zoom
    let delta = event.scrollingDeltaY * 0.02
    let newScale = max(0.25, min(3.0, scale * (1 + delta)))

    if newScale != scale {
      scale = newScale

      let canvasPointAfter = CGPoint(
        x: (mouseLocation.x - offset.x) / scale,
        y: (mouseLocation.y - offset.y) / scale
      )

      offset.x += (canvasPointAfter.x - canvasPointBefore.x) * scale
      offset.y += (canvasPointAfter.y - canvasPointBefore.y) * scale

      onScaleChanged?(scale)
      onOffsetChanged?(offset)
      needsDisplay = true
    }
  }

  // MARK: - Magnify Gesture (Trackpad pinch)

  override func magnify(with event: NSEvent) {
    let mouseLocation = convert(event.locationInWindow, from: nil)
    let canvasPointBefore = screenToCanvas(mouseLocation)

    let newScale = max(0.25, min(3.0, scale * (1 + event.magnification)))

    if newScale != scale {
      scale = newScale

      let canvasPointAfter = CGPoint(
        x: (mouseLocation.x - offset.x) / scale,
        y: (mouseLocation.y - offset.y) / scale
      )

      offset.x += (canvasPointAfter.x - canvasPointBefore.x) * scale
      offset.y += (canvasPointAfter.y - canvasPointBefore.y) * scale

      onScaleChanged?(scale)
      onOffsetChanged?(offset)
      needsDisplay = true
    }
  }
}
