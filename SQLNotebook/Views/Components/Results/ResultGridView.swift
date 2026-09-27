//
//  ResultGridView.swift
//  SQLNotebook
//
//  NSTableView-based result grid: view-based cell reuse renders only the visible rows.
//  Columns can be resized and reordered; Cmd+C copies the selected rows as TSV.
//  Double-click or Return edits a cell when `isEditable` (see NotebookViewModel.canEdit).
//  A click only selects; the details button shown over the hovered cell reports it
//  (`onShowCellDetails`), a header click the sort (`onSortChange`).
//

import AppKit
import SwiftUI

struct ResultGridView: NSViewRepresentable {
  let result: CellResult
  var sortColumn: String? = nil
  var ascending = true
  /// From `NotebookViewModel.canEdit(result)`; false keeps the grid read-only
  var isEditable = false
  /// Receives the displayed row values, the result column index and the new text of an edit
  var onCommitEdit: ((_ row: [CellValue], _ column: Int, _ newValue: String) -> Void)? =
    nil
  /// Receives the column and direction chosen by a header click (nil column: no sort)
  var onSortChange: ((_ column: String?, _ ascending: Bool) -> Void)? = nil
  /// Receives the displayed row values, its index into `CellResult.rows` and the result column
  /// index of the cell whose details button was clicked
  var onShowCellDetails: ((_ row: [CellValue], _ originalRow: Int, _ column: Int) -> Void)? =
    nil
  /// Text highlighted in the cells (search)
  var searchQuery = ""
  var caseSensitive = false
  /// Current search match (the one Enter moved to): the grid scrolls to it and shows it on the
  /// current-match color when it is in this result's data
  var currentMatch: SearchMatch? = nil
  /// Hand a vertical scroll the grid can't take to the parent (notebook list); false for a
  /// grid that fills its panel (editor)
  var forwardsScrollToParent = true
  /// Effective "Hide Column Types" setting: one-line header without the type line
  var hideColumnTypes = false

  /// Fixed row height of the grid
  static let rowHeight: CGFloat = 26
  /// Rows shown at once by a grid of `height(rowCount:hideColumnTypes:)`; more rows scroll
  /// inside the grid
  static let maxVisibleRows = 15

  /// Height of the rows only (no header), for a grid placed in a List or LazyVStack
  static func rowsHeight(rowCount: Int) -> CGFloat {
    CGFloat(rowCount) * rowHeight
  }

  /// Header height (set on the header view): name and type lines, or the name only; with
  /// types, `ResultGridHeaderCell.typeLineBottomExtra` of room below the type line
  static func headerHeight(hideColumnTypes: Bool) -> CGFloat {
    hideColumnTypes ? 28 : 48 + ResultGridHeaderCell.typeLineBottomExtra
  }

  /// Fixed height of a grid in a List or LazyVStack: at most `maxVisibleRows` rows plus header,
  /// plus the horizontal scroller in the legacy style (it takes its height inside the grid and
  /// would cover the rows; an overlay scroller floats over them)
  static func height(
    rowCount: Int, hideColumnTypes: Bool, scrollerStyle: NSScroller.Style
  ) -> CGFloat {
    let scroller =
      scrollerStyle == .legacy
      ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    return rowsHeight(rowCount: min(rowCount, maxVisibleRows))
      + headerHeight(hideColumnTypes: hideColumnTypes) + scroller
  }

  func makeCoordinator() -> ResultGridCoordinator {
    ResultGridCoordinator()
  }

  /// The grid's table view; alternating rows come from the coordinator's ResultGridRowView
  static func makeTableView(coordinator: ResultGridCoordinator) -> ResultGridTableView {
    let tableView = ResultGridTableView()
    tableView.coordinator = coordinator
    tableView.rowHeight = Self.rowHeight
    tableView.intercellSpacing = NSSize(width: 0, height: 0)
    tableView.usesAlternatingRowBackgroundColors = false
    tableView.allowsColumnResizing = true
    tableView.allowsColumnReordering = true
    tableView.allowsMultipleSelection = true
    tableView.columnAutoresizingStyle = .noColumnAutoresizing
    tableView.style = .plain
    tableView.backgroundColor = NSColor(Color.cellBackground)
    tableView.target = tableView
    tableView.doubleAction = #selector(ResultGridTableView.editClickedCell(_:))
    return tableView
  }

  func makeNSView(context: Context) -> NSScrollView {
    let tableView = Self.makeTableView(coordinator: context.coordinator)
    let scrollView = ResultGridScrollView()
    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false
    scrollView.forwardsToParent = forwardsScrollToParent
    configure(context.coordinator, tableView)
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let tableView = scrollView.documentView as? NSTableView else { return }
    (scrollView as? ResultGridScrollView)?.forwardsToParent = forwardsScrollToParent
    configure(context.coordinator, tableView)
  }

  private func configure(_ coordinator: ResultGridCoordinator, _ tableView: NSTableView) {
    coordinator.isEditable = isEditable
    coordinator.onCommitEdit = onCommitEdit
    coordinator.onSortChange = onSortChange
    coordinator.onShowCellDetails = onShowCellDetails
    coordinator.update(
      tableView, result: result, sortColumn: sortColumn, ascending: ascending,
      searchQuery: searchQuery, caseSensitive: caseSensitive, currentMatch: currentMatch,
      hideColumnTypes: hideColumnTypes)
  }
}

/// Scroll view that hands a vertical scroll gesture to the enclosing scroll view (the notebook
/// list) when the grid can't scroll that way, so the list keeps scrolling over a result.
/// The choice is made once per gesture; horizontal scrolling stays in the grid.
/// `forwardsToParent` false keeps every scroll in the grid (a grid filling its panel).
final class ResultGridScrollView: NSScrollView {
  var forwardsToParent = true
  private var forwardsGesture: Bool?

  /// Whether a vertical scroll of `deltaY` (> 0 toward the top) at `offsetY` (0 = top) goes to
  /// the parent: the content fits, or the grid is already at the edge it scrolls toward
  /// (within 1 pt, for fractional offsets)
  static func shouldForward(deltaY: CGFloat, offsetY: CGFloat, maxOffsetY: CGFloat) -> Bool {
    maxOffsetY < 1 || (deltaY > 0 && offsetY < 1) || (deltaY < 0 && offsetY > maxOffsetY - 1)
  }

  override func scrollWheel(with event: NSEvent) {
    let startsGesture =
      event.phase == .mayBegin || event.phase == .began
      || (event.phase.isEmpty && event.momentumPhase.isEmpty)
    if startsGesture { forwardsGesture = nil }
    let deltaX = event.scrollingDeltaX
    let deltaY = event.scrollingDeltaY
    // Shift+wheel is a horizontal scroll (mouse), handled by the grid
    if forwardsGesture == nil, deltaX != 0 || deltaY != 0, !event.modifierFlags.contains(.shift) {
      let insets = contentView.contentInsets
      let bounds = contentView.bounds
      let maxOffsetY =
        (documentView?.frame.height ?? 0) + insets.top + insets.bottom - bounds.height
      forwardsGesture =
        forwardsToParent && abs(deltaY) > abs(deltaX)
        && Self.shouldForward(
          deltaY: deltaY, offsetY: bounds.origin.y + insets.top, maxOffsetY: maxOffsetY)
    }
    if forwardsGesture == true {
      nextResponder?.scrollWheel(with: event)
    } else {
      super.scrollWheel(with: event)
    }
  }
}

/// Table view that answers the copy: action with the coordinator's TSV, starts an inline edit
/// on double-click or Return (in the last clicked column), and shows one details button over
/// the hovered cell that reports it to the coordinator (the right sidebar).
/// A single tracking area and a single reused button keep hovering cheap on large results.
final class ResultGridTableView: NSTableView {
  weak var coordinator: ResultGridCoordinator?
  private var lastClickedColumn = 0

  /// Side of the details button
  static let detailsButtonSize: CGFloat = 16
  /// Button shown over the hovered cell (subview of the table, hidden when no cell is hovered)
  private(set) lazy var detailsButton: NSButton = makeDetailsButton()
  /// Table row and table (on-screen) column under the details button
  private var hoveredCell: (row: Int, tableColumn: Int)?
  private var hoverTrackingArea: NSTrackingArea?
  /// Clip view whose scrolling moves the details button
  private weak var observedClipView: NSClipView?

  /// Frame of the details button: vertically centered at the trailing edge of the visible part
  /// of `cellRect`; nil when that part is too narrow for the button
  static func detailsButtonFrame(cellRect: NSRect, visibleRect: NSRect) -> NSRect? {
    let visible = cellRect.intersection(visibleRect)
    guard visible.width >= detailsButtonSize + 2 * Spacing.xs else { return nil }
    return NSRect(
      x: visible.maxX - Spacing.xs - detailsButtonSize,
      y: cellRect.midY - detailsButtonSize / 2, width: detailsButtonSize,
      height: detailsButtonSize)
  }

  override func mouseDown(with event: NSEvent) {
    let column = self.column(at: convert(event.locationInWindow, from: nil))
    if column >= 0 { lastClickedColumn = column }
    super.mouseDown(with: event)
  }

  @objc func editClickedCell(_ sender: Any?) {
    edit(row: clickedRow, tableColumn: clickedColumn)
  }

  // MARK: - Details button

  override func updateTrackingAreas() {
    if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
    let area = NSTrackingArea(
      rect: .zero,
      options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self)
    addTrackingArea(area)
    hoverTrackingArea = area
    super.updateTrackingAreas()
  }

  override func mouseMoved(with event: NSEvent) {
    super.mouseMoved(with: event)
    updateDetailsButton(at: convert(event.locationInWindow, from: nil))
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    guard event.trackingArea === hoverTrackingArea else { return }
    updateDetailsButton(at: convert(event.locationInWindow, from: nil))
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    guard event.trackingArea === hoverTrackingArea else { return }
    hideDetailsButton()
  }

  /// Shows the details button over the cell at `point` (table coordinates), or hides it when
  /// the point is on no visible cell or a cell is being edited
  func updateDetailsButton(at point: NSPoint) {
    let row = row(at: point)
    let tableColumn = column(at: point)
    guard row >= 0, tableColumn >= 0, visibleRect.contains(point),
      coordinator?.isEditing != true,
      let frame = Self.detailsButtonFrame(
        cellRect: frameOfCell(atColumn: tableColumn, row: row), visibleRect: visibleRect)
    else {
      hideDetailsButton()
      return
    }
    hoveredCell = (row, tableColumn)
    let button = detailsButton
    if button.frame != frame { button.frame = frame }
    // Row views added while scrolling would cover the button
    if subviews.last !== button { addSubview(button, positioned: .above, relativeTo: nil) }
    button.isHidden = false
  }

  private func hideDetailsButton() {
    hoveredCell = nil
    detailsButton.isHidden = true
  }

  /// Button position from the current mouse location (after a scroll or a column change)
  @objc private func refreshDetailsButton(_ notification: Notification? = nil) {
    guard let window, hoveredCell != nil else { return }
    updateDetailsButton(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
  }

  @objc private func showHoveredCellDetails(_ sender: Any?) {
    guard let hoveredCell, tableColumns.indices.contains(hoveredCell.tableColumn),
      let column = Int(tableColumns[hoveredCell.tableColumn].identifier.rawValue)
    else { return }
    selectRowIndexes([hoveredCell.row], byExtendingSelection: false)
    coordinator?.showCellDetails(row: hoveredCell.row, column: column)
  }

  private func makeDetailsButton() -> NSButton {
    let button = ResultGridDetailsButton()
    button.isBordered = false
    button.image = NSImage(
      systemSymbolName: "arrow.up.left.and.arrow.down.right",
      accessibilityDescription: "Show details")
    button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
    button.imagePosition = .imageOnly
    button.contentTintColor = NSColor(Color.foregroundMuted)
    button.toolTip = "Show details"
    button.target = self
    button.action = #selector(showHoveredCellDetails(_:))
    button.isHidden = true
    addSubview(button)
    return button
  }

  override func reloadData() {
    super.reloadData()
    // Row indexes may point at other rows now
    if hoveredCell != nil { hideDetailsButton() }
  }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    // Scroll (clip view bounds) and column resize or move; selector observers go with the table
    let center = NotificationCenter.default
    let refresh = #selector(refreshDetailsButton(_:))
    let columnNames = [
      NSTableView.columnDidResizeNotification, NSTableView.columnDidMoveNotification,
    ]
    if let observedClipView {
      center.removeObserver(
        self, name: NSView.boundsDidChangeNotification, object: observedClipView)
    }
    for name in columnNames { center.removeObserver(self, name: name, object: self) }
    observedClipView = superview as? NSClipView
    if let observedClipView {
      observedClipView.postsBoundsChangedNotifications = true
      center.addObserver(
        self, selector: refresh, name: NSView.boundsDidChangeNotification,
        object: observedClipView)
    }
    for name in columnNames {
      center.addObserver(self, selector: refresh, name: name, object: self)
    }
  }

  override func keyDown(with event: NSEvent) {
    let isReturn = event.keyCode == 36 || event.keyCode == 76
    if isReturn, selectedRowIndexes.count == 1,
      edit(row: selectedRow, tableColumn: lastClickedColumn)
    {
      return
    }
    super.keyDown(with: event)
  }

  @discardableResult
  private func edit(row: Int, tableColumn: Int) -> Bool {
    guard let coordinator, row >= 0, tableColumns.indices.contains(tableColumn),
      let column = Int(tableColumns[tableColumn].identifier.rawValue)
    else { return false }
    guard coordinator.beginEditing(self, row: row, column: column) else { return false }
    hideDetailsButton()
    return true
  }

  @objc func copy(_ sender: Any?) {
    coordinator?.copySelection(self)
  }

  override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
    if item.action == #selector(copy(_:)) {
      return !selectedRowIndexes.isEmpty
    }
    return super.validateUserInterfaceItem(item)
  }
}

/// Details button with a subtle rounded background, drawn at display time so it follows the
/// light or dark appearance
final class ResultGridDetailsButton: NSButton {
  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .pointingHand)
  }

  override func draw(_ dirtyRect: NSRect) {
    let path = NSBezierPath(
      roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: CornerRadius.sm,
      yRadius: CornerRadius.sm)
    NSColor(isHighlighted ? Color.cellBackgroundHover : Color.cardBackground).setFill()
    path.fill()
    NSColor(Color.border).setStroke()
    path.lineWidth = 0.5
    path.stroke()
    super.draw(dirtyRect)
  }
}
