//
//  SchemaGraphView+ColumnDrag.swift
//  Dblore
//
//  Foreign-key drag: each column row has a grip at its right end (a band clear of the resize
//  handles, shown on the hovered row, crosshair cursor). Dragging from it draws a line; dropped
//  on a column of another table, it stages a foreign key from the grip's column to that column.
//  The grips show only when the diagram edits and the engine changes foreign keys (not SQLite).
//

import AppKit
import SwiftUI

/// A column row of a node
struct SchemaColumnRef: Equatable {
  let nodeId: UUID
  let index: Int
}

extension SchemaGraphNSView {
  /// The engine changes foreign keys from the diagram: the rows keep a gutter for the grip
  var reservesColumnGrips: Bool {
    onEditAction != nil && foreignKeyDisabledReason == nil
  }

  /// Grips show, are hit-tested and start drags (the connection can change tables now)
  var showsColumnGrips: Bool {
    reservesColumnGrips && editDisabledReason == nil
  }

  var isDraggingForeignKey: Bool { foreignKeyDragSource != nil }

  // MARK: - Mouse

  /// Starts a drag from the grip under `point`; false when there is none
  func beginForeignKeyDrag(at point: CGPoint) -> Bool {
    guard let (node, index) = hitTestColumnGrip(at: point) else { return false }
    foreignKeyDragSource = SchemaColumnRef(nodeId: node.id, index: index)
    foreignKeyDropTarget = nil
    foreignKeyDragPoint = screenToCanvas(point)
    isDraggingNode = false
    isDraggingCanvas = false
    needsDisplay = true
    return true
  }

  func continueForeignKeyDrag(at point: CGPoint) {
    guard let source = foreignKeyDragSource else { return }
    foreignKeyDragPoint = screenToCanvas(point)
    let target = hitTestColumn(at: point).flatMap { node, index in
      node.id == source.nodeId ? nil : SchemaColumnRef(nodeId: node.id, index: index)
    }
    foreignKeyDropTarget = target
    needsDisplay = true
  }

  /// Ends the drag: dropped on a column of another table, stages the foreign key
  func endForeignKeyDrag() {
    defer {
      foreignKeyDragSource = nil
      foreignKeyDropTarget = nil
      needsDisplay = true
    }
    guard let source = foreignKeyDragSource, let target = foreignKeyDropTarget,
      let sourceNode = graph.nodes.first(where: { $0.id == source.nodeId }),
      let targetNode = graph.nodes.first(where: { $0.id == target.nodeId }),
      sourceNode.table.columns.indices.contains(source.index),
      targetNode.table.columns.indices.contains(target.index)
    else { return }
    onEditAction?(
      .addForeignKey(
        from: sourceNode, column: sourceNode.table.columns[source.index].name,
        to: targetNode, targetColumn: targetNode.table.columns[target.index].name))
  }

  /// Hover, after the resize handles' own: the row under the pointer shows its grip; over the
  /// grip the cursor is a crosshair. The crosshair is set, not pushed: the resize cursors' pushes
  /// and pops in the same move would otherwise pop it in their place. True when something to
  /// redraw changed.
  func updateColumnGripHover(at point: CGPoint) -> Bool {
    let row =
      showsColumnGrips
      ? hitTestColumn(at: point).map { SchemaColumnRef(nodeId: $0.node.id, index: $0.index) }
      : nil
    let grip = hitTestColumnGrip(at: point).map {
      SchemaColumnRef(nodeId: $0.node.id, index: $0.index)
    }
    var changed = false
    if hoveredColumn != row {
      hoveredColumn = row
      changed = true
    }
    if grip != hoveredGripColumn {
      if grip != nil {
        NSCursor.crosshair.set()
      } else {
        leaveColumnGripCursor()
      }
      hoveredGripColumn = grip
      changed = true
    }
    return changed
  }

  /// The pointer left the view: no row hovered, the crosshair goes
  func clearColumnGripHover() -> Bool {
    let changed = hoveredColumn != nil || hoveredGripColumn != nil
    if hoveredGripColumn != nil { leaveColumnGripCursor() }
    hoveredColumn = nil
    hoveredGripColumn = nil
    return changed
  }

  /// Back to the arrow, unless a resize handle's cursor took over in the same move
  private func leaveColumnGripCursor() {
    guard hoveredResizeHandleNodeId == nil, hoveredLeftResizeHandleNodeId == nil else { return }
    NSCursor.arrow.set()
  }

  // MARK: - Drawing

  /// The grip of a column row: shown on the hovered row, the drag's source and its drop target
  func drawColumnGrip(_ context: CGContext, node: SchemaNode, index: Int) {
    guard showsColumnGrips else { return }
    let ref = SchemaColumnRef(nodeId: node.id, index: index)
    let isSource = foreignKeyDragSource == ref
    let isTarget = foreignKeyDropTarget == ref
    guard isSource || isTarget || (!isDraggingForeignKey && hoveredColumn == ref) else { return }
    let grip = columnGripRect(for: node, index: index)
    let dot = CGRect(x: grip.midX - 3.5, y: grip.minY + 2, width: 7, height: 7)
    context.saveGState()
    context.setStrokeColor(edgeHighlightColor.cgColor)
    context.setLineWidth(1.2)
    if isSource || isTarget || hoveredGripColumn == ref {
      context.setFillColor(edgeHighlightColor.cgColor)
      context.fillEllipse(in: dot)
    }
    context.strokeEllipse(in: dot)
    context.restoreGState()
  }

  /// The line of a running drag, from the source grip to the pointer (in canvas coordinates)
  func drawForeignKeyDrag(_ context: CGContext) {
    guard let source = foreignKeyDragSource,
      let node = graph.nodes.first(where: { $0.id == source.nodeId })
    else { return }
    let grip = columnGripRect(for: node, index: source.index)
    let start = CGPoint(x: grip.midX, y: grip.minY + 5.5)
    context.saveGState()
    context.setStrokeColor(edgeHighlightColor.cgColor)
    context.setLineWidth(1.5)
    context.setLineDash(phase: 0, lengths: [5, 3])
    context.move(to: start)
    context.addLine(to: foreignKeyDragPoint)
    context.strokePath()
    context.restoreGState()
  }
}
