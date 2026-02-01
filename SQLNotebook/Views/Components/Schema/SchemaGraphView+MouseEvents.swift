//
//  SchemaGraphView+MouseEvents.swift
//  SQLNotebook
//
//  Mouse event handling for schema graph visualization
//

import AppKit
import SwiftUI

// MARK: - Mouse Events Extension

extension SchemaGraphNSView {

  // MARK: - Mouse Down

  func handleMouseDown(with event: NSEvent) {
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

    // Check if clicking on a node first (nodes are rendered on top of connection lines)
    if let node = hitTestNode(at: point) {
      isDraggingNode = true
      isDraggingCanvas = false
      draggedNodeId = node.id
      selectedEdgeId = nil  // Clear edge selection when selecting node
      selectedColumnConnectionEdgeId = nil  // Clear column connection selection
      onNodeSelected?(node.id)
      needsDisplay = true
      return
    }

    // Check if clicking on a column connection line (only when column connections are visible)
    // Only check when not clicking on a node (handled above)
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
    // Only check when not clicking on a node (handled above)
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

    // Clicking on empty canvas
    isDraggingCanvas = true
    isDraggingNode = false
    draggedNodeId = nil
    selectedEdgeId = nil  // Clear edge selection when clicking canvas
    selectedColumnConnectionEdgeId = nil  // Clear column connection selection
    onNodeSelected?(nil)
    needsDisplay = true
  }

  // MARK: - Mouse Dragged

  func handleMouseDragged(with event: NSEvent) {
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

  // MARK: - Mouse Up

  func handleMouseUp(with event: NSEvent) {
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

  // MARK: - Mouse Moved

  func handleMouseMoved(with event: NSEvent) {
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
    // Use local variable to determine if cursor is over a node for blocking line hover
    let isOverNode = hitTestNode(at: point) != nil
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
    // Skip edge hover detection if cursor is over a node (tables are rendered on top of lines)
    if showTableConnections && !isOverNode {
      if let edge = hitTestEdge(at: point) {
        if hoveredEdgeId != edge.id {
          hoveredEdgeId = edge.id
          needsRedraw = true

          // Cancel previous timer and start new one for hover delay
          cancelEdgeHoverTimer()
          highlightedEdgeId = nil  // Reset highlighted edge immediately

          // Start timer to highlight connected tables after delay
          startEdgeHoverTimer(for: edge.id)
        }
      } else if hoveredEdgeId != nil {
        hoveredEdgeId = nil
        highlightedEdgeId = nil  // Clear highlighted edge when not hovering
        cancelEdgeHoverTimer()
        needsRedraw = true
      }
    } else if hoveredEdgeId != nil {
      // Clear edge hover state when table connections are hidden or cursor is over a node
      hoveredEdgeId = nil
      highlightedEdgeId = nil
      cancelEdgeHoverTimer()
      needsRedraw = true
    }

    // Check if hovering over a column connection line (only when column connections are visible)
    // Skip column connection hover detection if cursor is over a node (tables are rendered on top of lines)
    if showColumnConnections && !isOverNode {
      if let edgeId = hitTestColumnConnection(at: point) {
        if hoveredColumnConnectionEdgeId != edgeId {
          hoveredColumnConnectionEdgeId = edgeId
          needsRedraw = true
        }
      } else if hoveredColumnConnectionEdgeId != nil {
        hoveredColumnConnectionEdgeId = nil
        needsRedraw = true
      }
    } else if hoveredColumnConnectionEdgeId != nil {
      // Clear column connection hover state when cursor is over a node or connections hidden
      hoveredColumnConnectionEdgeId = nil
      needsRedraw = true
    }

    if needsRedraw {
      needsDisplay = true
    }
  }

  // MARK: - Mouse Exited

  func handleMouseExited(with event: NSEvent) {
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
    cancelEdgeHoverTimer()

    if needsRedraw {
      needsDisplay = true
    }
  }

  // MARK: - Scroll Wheel (Zoom)

  func handleScrollWheel(with event: NSEvent) {
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

  func handleMagnify(with event: NSEvent) {
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
