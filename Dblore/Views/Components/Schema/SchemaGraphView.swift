//
//  SchemaGraphView.swift
//  Dblore
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

// MARK: - Edge Path for Hit Testing

/// Represents an edge path with waypoints for hit testing
struct EdgePath {
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

// MARK: - Column Connection Path for Hit Testing

/// Represents a column connection path for hit testing
struct ColumnConnectionPath {
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

// MARK: - Schema Graph NSView

/// Custom NSView that renders the schema graph with Core Graphics
@MainActor
class SchemaGraphNSView: NSView {

  // MARK: - Public Properties

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

  // MARK: - Callbacks

  var onNodeSelected: ((UUID?) -> Void)?
  var onNodeMoved: ((UUID, CGPoint) -> Void)?
  var onNodeResized: ((UUID, CGFloat) -> Void)?
  var onNodeDragEnded: (() -> Void)?
  var onNodeDoubleClick: ((SchemaNode) -> Void)?
  var onOffsetChanged: ((CGPoint) -> Void)?
  var onScaleChanged: ((CGFloat) -> Void)?

  // MARK: - Node Size Constants (internal for extensions)

  let nodeMinWidth: CGFloat = 150
  let nodeMaxWidth: CGFloat = 400
  let nodeDefaultWidth: CGFloat = 200
  let nodeHeaderHeight: CGFloat = 32
  let nodeColumnHeight: CGFloat = 18
  let nodeCornerRadius: CGFloat = 8
  let nodePadding: CGFloat = 8
  let expandButtonSize: CGFloat = 16
  let resizeHandleWidth: CGFloat = 8
  let columnTypeGap: CGFloat = 12  // Gap between column name and type

  // MARK: - Colors (internal for extensions)

  var nodeBackgroundColor: NSColor = .white
  var nodeHeaderColor: NSColor = .lightGray
  var nodeBorderColor: NSColor = .gray
  var nodeSelectedBorderColor: NSColor = .blue
  var edgeColor: NSColor = .gray
  var edgeHighlightColor: NSColor = .blue
  var textColor: NSColor = .black
  var subtleTextColor: NSColor = .gray
  var columnTextColor: NSColor = .gray

  // MARK: - Drag State (internal for extensions)

  var isDraggingNode: Bool = false
  var isDraggingCanvas: Bool = false
  var draggedNodeId: UUID?
  var lastMouseLocation: CGPoint = .zero

  // MARK: - Hover State (internal for extensions)

  var hoveredEdgeId: UUID?
  var hoveredExpandButtonNodeId: UUID?
  var hoveredNodeId: UUID?
  private var trackingArea: NSTrackingArea?

  // MARK: - Edge Hover State (internal for extensions)

  private var edgeHoverTimer: Timer?
  var highlightedEdgeId: UUID?  // Edge that has passed the hover delay
  var selectedEdgeId: UUID?  // Edge that was clicked
  private let edgeHoverDelay: TimeInterval = 0.3  // 300ms delay before highlighting tables

  // MARK: - Column Connection State (internal for extensions)

  var hoveredColumnConnectionEdgeId: UUID?  // Edge whose column connection is being hovered
  var selectedColumnConnectionEdgeId: UUID?  // Edge whose column connection is selected (clicked)
  var columnConnectionAnimationPhase: CGFloat = 0  // Animation phase for dashed lines
  private var columnConnectionAnimationTimer: Timer?  // Timer for dash animation

  // MARK: - Resize State (internal for extensions)

  var isResizingNode: Bool = false
  var resizingNodeId: UUID?
  var isResizingFromLeft: Bool = false  // Track if resizing from left edge
  var hoveredResizeHandleNodeId: UUID?
  var hoveredLeftResizeHandleNodeId: UUID?

  // MARK: - Edge Router

  let edgeRouter = SchemaEdgeRouter()

  // MARK: - Edge Path Cache

  private var cachedEdgePaths: [UUID: EdgePath] = [:]
  private var cachedColumnConnectionPaths: [UUID: [ColumnConnectionPath]] = [:]

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

  // MARK: - Column Connection Animation

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

  // MARK: - Colors

  func updateColors() {
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

  func screenToCanvas(_ point: CGPoint) -> CGPoint {
    CGPoint(
      x: (point.x - offset.x) / scale,
      y: (point.y - offset.y) / scale
    )
  }

  // MARK: - Edge Path Cache Methods

  func storeCachedEdgePath(_ path: EdgePath) {
    cachedEdgePaths[path.id] = path
  }

  func getCachedEdgePath(for id: UUID) -> EdgePath? {
    cachedEdgePaths[id]
  }

  func clearCachedColumnConnectionPaths() {
    cachedColumnConnectionPaths.removeAll()
  }

  func storeCachedColumnConnectionPaths(edgeId: UUID, paths: [ColumnConnectionPath]) {
    cachedColumnConnectionPaths[edgeId] = paths
  }

  func getCachedColumnConnectionPaths() -> [UUID: [ColumnConnectionPath]] {
    cachedColumnConnectionPaths
  }

  // MARK: - Edge Hover Timer Methods

  func startEdgeHoverTimer(for edgeId: UUID) {
    edgeHoverTimer = Timer.scheduledTimer(withTimeInterval: edgeHoverDelay, repeats: false) {
      [weak self] _ in
      Task { @MainActor in
        self?.highlightedEdgeId = edgeId
        self?.needsDisplay = true
      }
    }
  }

  func cancelEdgeHoverTimer() {
    edgeHoverTimer?.invalidate()
    edgeHoverTimer = nil
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

  // MARK: - Mouse Events (delegate to extension)

  override func mouseDown(with event: NSEvent) {
    handleMouseDown(with: event)
  }

  override func mouseDragged(with event: NSEvent) {
    handleMouseDragged(with: event)
  }

  override func mouseUp(with event: NSEvent) {
    handleMouseUp(with: event)
  }

  override func mouseMoved(with event: NSEvent) {
    handleMouseMoved(with: event)
  }

  override func mouseExited(with event: NSEvent) {
    handleMouseExited(with: event)
  }

  override func scrollWheel(with event: NSEvent) {
    handleScrollWheel(with: event)
  }

  override func magnify(with event: NSEvent) {
    handleMagnify(with: event)
  }
}
