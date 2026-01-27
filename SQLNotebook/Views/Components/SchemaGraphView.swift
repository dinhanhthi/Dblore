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
  @Binding var showTableConnections: Bool
  @Binding var showColumnConnections: Bool
  var searchState: SchemaSearchState
  var onNodeDoubleClick: ((SchemaNode) -> Void)?
  var onNodeDragEnded: (() -> Void)?
  var onViewCreated: ((SchemaGraphNSView) -> Void)?

  func makeNSView(context: Context) -> SchemaGraphNSView {
    let view = SchemaGraphNSView()
    view.graph = graph
    view.scale = scale
    view.offset = offset
    view.selectedNodeId = selectedNodeId
    view.showTableConnections = showTableConnections
    view.showColumnConnections = showColumnConnections
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
    view.onNodeResized = { nodeId, newWidth in
      DispatchQueue.main.async {
        if let index = graph.nodes.firstIndex(where: { $0.id == nodeId }) {
          graph.nodes[index].width = newWidth
        }
      }
    }
    view.onNodeDragEnded = onNodeDragEnded
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
    // Notify parent that view was created
    DispatchQueue.main.async {
      onViewCreated?(view)
    }
    return view
  }

  func updateNSView(_ nsView: SchemaGraphNSView, context: Context) {
    nsView.graph = graph
    nsView.scale = scale
    nsView.offset = offset
    nsView.selectedNodeId = selectedNodeId
    nsView.showTableConnections = showTableConnections
    nsView.showColumnConnections = showColumnConnections
    nsView.searchState = searchState
    nsView.onNodeDragEnded = onNodeDragEnded
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

  var showTableConnections: Bool = true {
    didSet { needsDisplay = true }
  }

  var showColumnConnections: Bool = false {
    didSet {
      updateColumnConnectionAnimation()
      // Clear selection when column connections are hidden
      if !showColumnConnections {
        selectedColumnConnectionEdgeId = nil
        hoveredColumnConnectionEdgeId = nil
      }
      needsDisplay = true
    }
  }

  var onNodeSelected: ((UUID?) -> Void)?
  var onNodeMoved: ((UUID, CGPoint) -> Void)?
  var onNodeResized: ((UUID, CGFloat) -> Void)?
  var onNodeDragEnded: (() -> Void)?
  var onNodeDoubleClick: ((SchemaNode) -> Void)?
  var onOffsetChanged: ((CGPoint) -> Void)?
  var onScaleChanged: ((CGFloat) -> Void)?

  // Node size constraints
  private let nodeMinWidth: CGFloat = 150
  private let nodeMaxWidth: CGFloat = 400
  private let nodeDefaultWidth: CGFloat = 200
  private let nodeHeaderHeight: CGFloat = 32
  private let nodeColumnHeight: CGFloat = 18
  private let nodeCornerRadius: CGFloat = 8
  private let nodePadding: CGFloat = 8
  private let expandButtonSize: CGFloat = 16
  private let resizeHandleWidth: CGFloat = 8
  private let columnTypeGap: CGFloat = 12  // Gap between column name and type

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

  // Column connection line hover and selection state
  private var hoveredColumnConnectionEdgeId: UUID?  // Edge whose column connection is being hovered
  private var selectedColumnConnectionEdgeId: UUID?  // Edge whose column connection is selected (clicked)
  private var columnConnectionAnimationPhase: CGFloat = 0  // Animation phase for dashed lines
  private var columnConnectionAnimationTimer: Timer?  // Timer for dash animation

  // Resize state
  private var isResizingNode: Bool = false
  private var resizingNodeId: UUID?
  private var isResizingFromLeft: Bool = false  // Track if resizing from left edge
  private var hoveredResizeHandleNodeId: UUID?
  private var hoveredLeftResizeHandleNodeId: UUID?

  // Edge router for avoiding node intersections
  private let edgeRouter = SchemaEdgeRouter()

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

  /// Start or stop column connection animation based on showColumnConnections state
  func updateColumnConnectionAnimation() {
    if showColumnConnections {
      startColumnConnectionAnimation()
    } else {
      stopColumnConnectionAnimation()
    }
  }

  private func startColumnConnectionAnimation() {
    guard columnConnectionAnimationTimer == nil else { return }
    columnConnectionAnimationTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) {
      [weak self] _ in
      Task { @MainActor in
        self?.columnConnectionAnimationPhase += 1
        if self?.columnConnectionAnimationPhase ?? 0 > 20 {
          self?.columnConnectionAnimationPhase = 0
        }
        self?.needsDisplay = true
      }
    }
  }

  private func stopColumnConnectionAnimation() {
    columnConnectionAnimationTimer?.invalidate()
    columnConnectionAnimationTimer = nil
    columnConnectionAnimationPhase = 0
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

    // Draw edges first (table connection lines)
    if showTableConnections {
      drawEdges(context)
    }

    // Draw column connection lines if enabled
    if showColumnConnections {
      drawColumnConnections(context)
    }

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
  private func drawOrthogonalEdge(
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
    let points: [CGPoint]  // All waypoints including start and end

    // Legacy accessors for compatibility
    var startPoint: CGPoint { points.first ?? .zero }
    var endPoint: CGPoint { points.last ?? .zero }
    var midPoint1: CGPoint { points.count > 1 ? points[1] : startPoint }
    var midPoint2: CGPoint { points.count > 2 ? points[points.count - 2] : endPoint }

    /// Second point for direction calculation (for ER notation at start)
    var secondPoint: CGPoint { points.count > 1 ? points[1] : startPoint }

    /// Second-to-last point for direction calculation (for ER notation at end)
    var secondToLastPoint: CGPoint { points.count > 1 ? points[points.count - 2] : endPoint }

    init(id: UUID, points: [CGPoint]) {
      self.id = id
      self.points = points
    }

    // Legacy initializer for compatibility
    init(id: UUID, startPoint: CGPoint, midPoint1: CGPoint, midPoint2: CGPoint, endPoint: CGPoint) {
      self.id = id
      self.points = [startPoint, midPoint1, midPoint2, endPoint]
    }

    /// Check if a point is near this edge path
    func contains(_ point: CGPoint, threshold: CGFloat = 8) -> Bool {
      guard points.count >= 2 else { return false }

      for i in 0..<(points.count - 1) {
        if distanceToSegment(point: point, segmentStart: points[i], segmentEnd: points[i + 1])
          < threshold
        {
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

  // MARK: - Column Connection Lines

  /// Cache for column connection paths for hit testing
  private struct ColumnConnectionPath {
    let edgeId: UUID
    let sourceColumnIndex: Int
    let targetColumnIndex: Int
    let path: [CGPoint]  // Points along the path

    func contains(_ point: CGPoint, threshold: CGFloat = 8) -> Bool {
      for i in 0..<(path.count - 1) {
        if distanceToSegment(point: point, segmentStart: path[i], segmentEnd: path[i + 1])
          < threshold
        {
          return true
        }
      }
      return false
    }

    private func distanceToSegment(
      point: CGPoint, segmentStart: CGPoint, segmentEnd: CGPoint
    ) -> CGFloat {
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

  private var cachedColumnConnectionPaths: [UUID: [ColumnConnectionPath]] = [:]

  /// Draw dashed animated lines connecting FK columns between tables
  private func drawColumnConnections(_ context: CGContext) {
    cachedColumnConnectionPaths.removeAll()

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

      cachedColumnConnectionPaths[edge.id] = paths
    }
  }

  /// Draw a single column connection line with dashed animated style
  private func drawColumnConnectionLine(
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
  private func hitTestColumnConnection(at point: CGPoint) -> UUID? {
    let canvasPoint = screenToCanvas(point)

    for (edgeId, paths) in cachedColumnConnectionPaths {
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

  /// Check if a node is connected to the currently selected node
  private func isNodeConnectedToSelectedNode(_ nodeId: UUID) -> Bool {
    guard let selectedId = selectedNodeId, nodeId != selectedId else {
      return false
    }
    // Check if there's an edge connecting this node to the selected node
    return graph.edges.contains { edge in
      (edge.sourceNodeId == nodeId && edge.targetNodeId == selectedId)
        || (edge.sourceNodeId == selectedId && edge.targetNodeId == nodeId)
    }
  }

  /// Get column indices that should be highlighted for a node due to column connection hover or selection
  private func getHighlightedColumnsForNode(_ nodeId: UUID) -> Set<Int> {
    guard showColumnConnections else { return [] }

    // Check both hover and selection states
    let activeEdgeId = hoveredColumnConnectionEdgeId ?? selectedColumnConnectionEdgeId
    guard let edgeId = activeEdgeId else { return [] }

    guard let highlightInfo = highlightedColumnsForEdge(edgeId) else {
      return []
    }

    if nodeId == highlightInfo.sourceNodeId {
      return Set(highlightInfo.sourceColumns)
    } else if nodeId == highlightInfo.targetNodeId {
      return Set(highlightInfo.targetColumns)
    }
    return []
  }

  private func drawNodes(_ context: CGContext) {
    for node in graph.nodes {
      let rect = nodeRect(for: node)
      let isSelected = selectedNodeId == node.id
      let isHovered = hoveredNodeId == node.id
      let isHighlightedByEdge = isNodeHighlightedByEdge(node.id)
      let isConnectedToSelected = isNodeConnectedToSelectedNode(node.id)

      // Draw shadow (stronger when highlighted by edge or hovered)
      // Connected-to-selected nodes use normal shadow (no extra shadow like hover)
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

      // Draw border (highlighted when selected, hovered, connected to highlighted edge,
      // or connected to selected node)
      context.addPath(path)
      let borderColor: NSColor
      let borderWidth: CGFloat
      if isSelected || isHighlightedByEdge {
        borderColor = nodeSelectedBorderColor
        borderWidth = 2
      } else if isConnectedToSelected {
        // Blue border for cards connected to selected node
        borderColor = NSColor.systemBlue
        borderWidth = 1.5
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

    // Get highlighted columns for column connection hover
    let highlightedColumns = getHighlightedColumnsForNode(node.id)

    for (index, column) in columns.enumerated() {
      let y = rect.minY + nodeHeaderHeight + 4 + CGFloat(index) * nodeColumnHeight

      // Check if this column should be highlighted due to column connection hover
      let isColumnHighlighted = highlightedColumns.contains(index)

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

      // Draw column name (with search highlight if matching, or green highlight for FK connection)
      let hasSpecialAttributes = column.isPrimaryKey || column.isIdentity || column.isUnique
      let nameFont = hasSpecialAttributes ? pkFont : columnFont
      // Use green color if highlighted by column connection hover
      let nameColor: NSColor =
        isColumnHighlighted
        ? .systemGreen : (hasSpecialAttributes ? textColor : columnTextColor)
      let namePoint = CGPoint(x: nameStartX, y: y)

      // Check if column name has search match
      let columnMatch = searchState.matches.first {
        $0.nodeId == node.id && $0.matchType == .columnName(columnIndex: index)
      }

      if let match = columnMatch, !searchState.query.isEmpty {
        // Truncate name if needed for search highlight
        let truncatedName = truncateText(
          column.name, font: nameFont, maxWidth: maxNameWidth)
        drawHighlightedText(
          context,
          text: truncatedName,
          at: namePoint,
          font: nameFont,
          textColor: nameColor,
          highlightRange: adjustRangeForTruncation(
            match.matchRange, originalText: column.name, truncatedText: truncatedName),
          isCurrentMatch: searchState.currentMatch?.id == match.id
        )
      } else {
        // Draw with potential green highlight for FK connection, truncated if needed
        let truncatedName = truncateText(column.name, font: nameFont, maxWidth: maxNameWidth)
        let nameAttributes: [NSAttributedString.Key: Any] = [
          .font: isColumnHighlighted ? NSFont.systemFont(ofSize: 9, weight: .semibold) : nameFont,
          .foregroundColor: nameColor,
        ]
        let nameString = NSAttributedString(string: truncatedName, attributes: nameAttributes)
        nameString.draw(at: namePoint)
      }

      // Draw type on the right
      typeString.draw(at: CGPoint(x: typeX, y: y + 1))
    }
  }

  /// Truncate text to fit within maxWidth, adding "..." if needed
  private func truncateText(_ text: String, font: NSFont, maxWidth: CGFloat) -> String {
    let attributes: [NSAttributedString.Key: Any] = [.font: font]
    let fullWidth = (text as NSString).size(withAttributes: attributes).width

    if fullWidth <= maxWidth {
      return text
    }

    let ellipsis = "..."
    let ellipsisWidth = (ellipsis as NSString).size(withAttributes: attributes).width
    let availableWidth = maxWidth - ellipsisWidth

    if availableWidth <= 0 {
      return ellipsis
    }

    // Binary search for the right truncation point
    var low = 0
    var high = text.count

    while low < high {
      let mid = (low + high + 1) / 2
      let truncated = String(text.prefix(mid))
      let width = (truncated as NSString).size(withAttributes: attributes).width

      if width <= availableWidth {
        low = mid
      } else {
        high = mid - 1
      }
    }

    if low == 0 {
      return ellipsis
    }

    return String(text.prefix(low)) + ellipsis
  }

  /// Adjust highlight range for truncated text
  private func adjustRangeForTruncation(
    _ range: Range<String.Index>, originalText: String, truncatedText: String
  ) -> Range<String.Index> {
    // If text wasn't truncated, return original range
    if !truncatedText.hasSuffix("...") {
      return range
    }

    let truncatedWithoutEllipsis = String(truncatedText.dropLast(3))
    let truncatedEndIndex = truncatedWithoutEllipsis.endIndex

    // Adjust range to fit within truncated text
    let adjustedLower = min(range.lowerBound, truncatedEndIndex)
    let adjustedUpper = min(range.upperBound, truncatedEndIndex)

    // Ensure we have a valid range
    if adjustedLower >= adjustedUpper {
      // Range is completely outside truncated text, return empty range at end
      return truncatedWithoutEllipsis.endIndex..<truncatedWithoutEllipsis.endIndex
    }

    return adjustedLower..<adjustedUpper
  }

  /// Draw an SF Symbol at the specified location, vertically centered with the text line
  /// - Parameters:
  ///   - name: SF Symbol name
  ///   - point: Base position (x for horizontal, y is the text baseline position)
  ///   - color: Symbol color
  ///   - font: Font used for sizing the symbol
  ///   - textHeight: Height of the text to center with (default: 11 for 9pt font)
  private func drawSFSymbol(
    _ name: String, at point: CGPoint, color: NSColor, font: NSFont, textHeight: CGFloat = 11
  ) {
    if let symbolImage = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
      let config = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .medium)
      let configuredImage = symbolImage.withSymbolConfiguration(config)

      // Draw the symbol
      let imageSize = CGSize(width: 8, height: 8)
      // Center the icon vertically with the text line
      let centeredY = point.y + (textHeight - imageSize.height) / 2
      let imageRect = CGRect(
        x: point.x, y: centeredY, width: imageSize.width, height: imageSize.height)

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
    // Current match: orange-yellow, Other matches: white (dark) / gray (light)
    let isDarkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let highlightColor: NSColor
    if isCurrentMatch {
      highlightColor = NSColor(red: 1.0, green: 0.835, blue: 0.0, alpha: 1.0)  // #FFD500 orange-yellow
    } else {
      highlightColor =
        isDarkMode
        ? NSColor.white.withAlphaComponent(0.8)
        : NSColor.gray.withAlphaComponent(0.6)
    }

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

    // Highlighted part - use dark text color for better contrast on bright highlight background
    let highlightedTextColor = NSColor.black
    let highlightedAttributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: highlightedTextColor,
      .paragraphStyle: paragraphStyle,
    ]
    let highlightedString = NSAttributedString(
      string: highlightedPart, attributes: highlightedAttributes)
    highlightedString.draw(at: CGPoint(x: point.x + beforeWidth, y: point.y))

    // After highlight part
    if !afterHighlight.isEmpty {
      let afterString = NSAttributedString(string: afterHighlight, attributes: baseAttributes)
      afterString.draw(at: CGPoint(x: point.x + beforeWidth + highlightWidth, y: point.y))
    }
  }

  /// Calculate node rect - height based on ALL columns, width from node or auto-calculated
  private func nodeRect(for node: SchemaNode) -> CGRect {
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
  private func calculateAutoWidth(for node: SchemaNode) -> CGFloat {
    let columnFont = NSFont.systemFont(ofSize: 9, weight: .regular)
    let typeFont = NSFont.monospacedSystemFont(ofSize: 8, weight: .regular)
    let tableFont = NSFont.systemFont(ofSize: 11, weight: .semibold)

    // Calculate width needed for table name in header
    let tableNameWidth =
      (node.table.name as NSString).size(withAttributes: [.font: tableFont]).width + 60  // padding + buttons

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
  private func expandButtonRect(for node: SchemaNode) -> CGRect {
    let nodeR = nodeRect(for: node)
    return CGRect(
      x: nodeR.maxX - expandButtonSize - 6,
      y: nodeR.minY + (nodeHeaderHeight - expandButtonSize) / 2,
      width: expandButtonSize,
      height: expandButtonSize
    )
  }

  /// Calculate resize handle rect for a node (right edge)
  private func resizeHandleRect(for node: SchemaNode) -> CGRect {
    let nodeR = nodeRect(for: node)
    return CGRect(
      x: nodeR.maxX - resizeHandleWidth / 2,
      y: nodeR.minY,
      width: resizeHandleWidth,
      height: nodeR.height
    )
  }

  /// Calculate left resize handle rect for a node (left edge)
  private func leftResizeHandleRect(for node: SchemaNode) -> CGRect {
    let nodeR = nodeRect(for: node)
    return CGRect(
      x: nodeR.minX - resizeHandleWidth / 2,
      y: nodeR.minY,
      width: resizeHandleWidth,
      height: nodeR.height
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

  /// Hit test for resize handle (right edge of node)
  private func hitTestResizeHandle(at point: CGPoint) -> SchemaNode? {
    let canvasPoint = screenToCanvas(point)
    for node in graph.nodes.reversed() {
      if resizeHandleRect(for: node).contains(canvasPoint) {
        return node
      }
    }
    return nil
  }

  /// Hit test for left resize handle (left edge of node)
  private func hitTestLeftResizeHandle(at point: CGPoint) -> SchemaNode? {
    let canvasPoint = screenToCanvas(point)
    for node in graph.nodes.reversed() {
      if leftResizeHandleRect(for: node).contains(canvasPoint) {
        return node
      }
    }
    return nil
  }

  /// Auto-fit node width to content (double-click on resize handle)
  private func autoFitNodeWidth(_ node: SchemaNode, fromLeft: Bool) {
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

    // Check if double-clicking on right resize handle - auto-fit to content
    if event.clickCount == 2 {
      if let node = hitTestResizeHandle(at: point) {
        autoFitNodeWidth(node, fromLeft: false)
        return
      }
      if let node = hitTestLeftResizeHandle(at: point) {
        autoFitNodeWidth(node, fromLeft: true)
        return
      }
    }

    // Check if clicking right resize handle
    if let node = hitTestResizeHandle(at: point) {
      isResizingNode = true
      resizingNodeId = node.id
      isResizingFromLeft = false
      isDraggingNode = false
      isDraggingCanvas = false
      NSCursor.resizeLeftRight.push()
      return
    }

    // Check if clicking left resize handle
    if let node = hitTestLeftResizeHandle(at: point) {
      isResizingNode = true
      resizingNodeId = node.id
      isResizingFromLeft = true
      isDraggingNode = false
      isDraggingCanvas = false
      NSCursor.resizeLeftRight.push()
      return
    }

    // Check if clicking on a column connection line (only when column connections are visible)
    if showColumnConnections, let edgeId = hitTestColumnConnection(at: point) {
      // Select/deselect column connection
      if selectedColumnConnectionEdgeId == edgeId {
        selectedColumnConnectionEdgeId = nil
      } else {
        selectedColumnConnectionEdgeId = edgeId
      }
      // Clear other selections
      selectedEdgeId = nil
      onNodeSelected?(nil)
      needsDisplay = true
      return
    }

    // Check if clicking on an edge (only when table connections are visible)
    if showTableConnections, let edge = hitTestEdge(at: point) {
      // Select/deselect edge
      if selectedEdgeId == edge.id {
        selectedEdgeId = nil
      } else {
        selectedEdgeId = edge.id
      }
      // Clear other selections
      selectedColumnConnectionEdgeId = nil
      onNodeSelected?(nil)
      needsDisplay = true
      return
    }

    if let node = hitTestNode(at: point) {
      isDraggingNode = true
      isDraggingCanvas = false
      draggedNodeId = node.id
      selectedEdgeId = nil  // Clear edge selection when selecting node
      selectedColumnConnectionEdgeId = nil  // Clear column connection selection
      onNodeSelected?(node.id)
    } else {
      isDraggingCanvas = true
      isDraggingNode = false
      draggedNodeId = nil
      selectedEdgeId = nil  // Clear edge selection when clicking canvas
      selectedColumnConnectionEdgeId = nil  // Clear column connection selection
      onNodeSelected?(nil)
    }
    needsDisplay = true
  }

  override func mouseDragged(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    let deltaX = point.x - lastMouseLocation.x

    if isResizingNode, let nodeId = resizingNodeId {
      if let index = graph.nodes.firstIndex(where: { $0.id == nodeId }) {
        let currentWidth = graph.nodes[index].width ?? calculateAutoWidth(for: graph.nodes[index])
        let scaledDelta = deltaX / scale

        if isResizingFromLeft {
          // Resize from left: decrease width when dragging right, increase when dragging left
          // Also need to move the position to keep right edge fixed
          let newWidth = min(max(currentWidth - scaledDelta, nodeMinWidth), nodeMaxWidth)
          let actualWidthChange = currentWidth - newWidth
          // Move position by the actual width change (positive when shrinking, negative when growing)
          let newPosition = CGPoint(
            x: graph.nodes[index].position.x + actualWidthChange,
            y: graph.nodes[index].position.y
          )
          graph.nodes[index].width = newWidth
          graph.nodes[index].position = newPosition
          onNodeResized?(nodeId, newWidth)
          onNodeMoved?(nodeId, newPosition)
        } else {
          // Resize from right: increase width when dragging right
          let newWidth = min(max(currentWidth + scaledDelta, nodeMinWidth), nodeMaxWidth)
          graph.nodes[index].width = newWidth
          onNodeResized?(nodeId, newWidth)
        }
        needsDisplay = true
      }
    } else if isDraggingNode, let nodeId = draggedNodeId {
      let deltaY = point.y - lastMouseLocation.y
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
      let deltaY = point.y - lastMouseLocation.y
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
      // Don't trigger node double-click if clicking on resize handles (already handled in mouseDown)
      let isOnResizeHandle =
        hitTestResizeHandle(at: point) != nil || hitTestLeftResizeHandle(at: point) != nil
      if !isOnResizeHandle, let node = hitTestNode(at: point) {
        onNodeDoubleClick?(node)
      }
    }

    // Notify when node drag or resize ends to save positions
    if isDraggingNode || isResizingNode {
      onNodeDragEnded?()
    }

    // Reset resize cursor
    if isResizingNode {
      NSCursor.pop()
    }

    isDraggingNode = false
    isDraggingCanvas = false
    isResizingNode = false
    isResizingFromLeft = false
    draggedNodeId = nil
    resizingNodeId = nil
  }

  override func mouseMoved(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    var needsRedraw = false

    // Check if hovering over right resize handle (show resize cursor)
    if let node = hitTestResizeHandle(at: point) {
      if hoveredResizeHandleNodeId != node.id {
        hoveredResizeHandleNodeId = node.id
        NSCursor.resizeLeftRight.push()
        needsRedraw = true
      }
    } else if hoveredResizeHandleNodeId != nil {
      hoveredResizeHandleNodeId = nil
      NSCursor.pop()
      needsRedraw = true
    }

    // Check if hovering over left resize handle (show resize cursor)
    if let node = hitTestLeftResizeHandle(at: point) {
      if hoveredLeftResizeHandleNodeId != node.id {
        hoveredLeftResizeHandleNodeId = node.id
        if hoveredResizeHandleNodeId == nil {  // Only push if right handle cursor not already active
          NSCursor.resizeLeftRight.push()
        }
        needsRedraw = true
      }
    } else if hoveredLeftResizeHandleNodeId != nil {
      hoveredLeftResizeHandleNodeId = nil
      if hoveredResizeHandleNodeId == nil {  // Only pop if right handle cursor not active
        NSCursor.pop()
      }
      needsRedraw = true
    }

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

    // Check if hovering over an edge (only when table connections are visible)
    if showTableConnections {
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
    } else if hoveredEdgeId != nil {
      // Clear edge hover state when table connections are hidden
      hoveredEdgeId = nil
      highlightedEdgeId = nil
      edgeHoverTimer?.invalidate()
      edgeHoverTimer = nil
      needsRedraw = true
    }

    // Check if hovering over a column connection line (only when column connections are visible)
    if showColumnConnections {
      if let edgeId = hitTestColumnConnection(at: point) {
        if hoveredColumnConnectionEdgeId != edgeId {
          hoveredColumnConnectionEdgeId = edgeId
          needsRedraw = true
        }
      } else if hoveredColumnConnectionEdgeId != nil {
        hoveredColumnConnectionEdgeId = nil
        needsRedraw = true
      }
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
    if hoveredColumnConnectionEdgeId != nil {
      hoveredColumnConnectionEdgeId = nil
      needsRedraw = true
    }
    if hoveredResizeHandleNodeId != nil {
      hoveredResizeHandleNodeId = nil
      NSCursor.pop()
      needsRedraw = true
    }
    if hoveredLeftResizeHandleNodeId != nil {
      hoveredLeftResizeHandleNodeId = nil
      NSCursor.pop()
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

  // MARK: - Export to Image

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
  private func drawDotPatternForExport(
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
  private func drawEdgesForExport(_ context: CGContext) {
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
  private func drawOrthogonalEdgeForExport(
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
  private func drawNodesForExport(_ context: CGContext) {
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
  private func drawColumnsForExport(_ context: CGContext, node: SchemaNode, rect: CGRect) {
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
