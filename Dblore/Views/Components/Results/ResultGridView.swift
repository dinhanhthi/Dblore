//
//  ResultGridView.swift
//  Dblore
//
//  NSTableView-based result grid: view-based cell reuse renders only the visible rows.
//  Columns can be resized and reordered; Cmd+C copies the selected rows as TSV.
//  Double-click or Return edits a cell when `isEditable` (see NotebookViewModel.canEdit).
//  `stagesEdits` stages that commit, and Delete/Backspace, instead of an immediate UPDATE.
//  A click only selects; the details button shown over the hovered cell reports it
//  (`onShowCellDetails`), a header click the sort (`onSortChange`), the filter icon a
//  category filter of the loaded rows (`onValueFilterChange`). "Referenced Row..." opens
//  when the column has a foreign key.
//

import AppKit
import SwiftUI

struct ResultGridView: NSViewRepresentable {
  let result: CellResult
  var sortColumn: String? = nil
  var ascending = true
  /// From `NotebookViewModel.canEdit(result)`; false keeps the grid read-only
  var isEditable = false
  /// Result column indexes that stay read-only when `isEditable` (generated columns)
  var readOnlyColumns: Set<Int> = []
  /// Receives the displayed row values, the result column index and the new text of an edit.
  /// Not called when `stagesEdits` is set.
  var onCommitEdit: ((_ row: [CellValue], _ column: Int, _ newValue: String) -> Void)? =
    nil
  /// Data viewer with a primary-key edit target. Notebook grids leave this false.
  var stagesEdits = false
  /// Staged overlay painted on the loaded rows. Nil shows the result as loaded.
  var changeSet: RowChangeSet? = nil
  /// Page row, result column and new text of a staged cell edit
  var onStageEdit: ((_ row: Int, _ column: Int, _ newValue: String) -> Void)? = nil
  var onStageInsert: (() -> Void)? = nil
  var onStageDuplicate: ((_ rows: [Int]) -> Void)? = nil
  var onStageDelete: ((_ rows: [Int]) -> Void)? = nil
  var onRevertStaged: ((_ rows: [Int]) -> Void)? = nil
  /// Receives the column and direction chosen by a header click (nil column: no sort)
  var onSortChange: ((_ column: String?, _ ascending: Bool) -> Void)? = nil
  /// Category keys hidden per column. Does not change the loaded result or its LIMIT.
  var valueFilter = ColumnValueFilter()
  /// Receives the filter after a value is shown or hidden in the header popover
  var onValueFilterChange: ((ColumnValueFilter) -> Void)? = nil
  /// Receives the displayed row values, its index into `CellResult.rows` and the result column
  /// index of the cell whose details button was clicked
  var onShowCellDetails: ((_ row: [CellValue], _ originalRow: Int, _ column: Int) -> Void)? =
    nil
  /// Receives the result column, its value and the style and color chosen in the context menu;
  /// nil leaves the highlight items out of the menu
  var onHighlightCell:
    ((_ column: Int, _ value: CellValue, _ style: HighlightStyle, _ color: HighlightColor) -> Void)? =
      nil
  /// Receives the context menu's "Clear Highlight"
  var onClearHighlight: (() -> Void)? = nil
  /// Text highlighted in the cells (search)
  var searchQuery = ""
  var caseSensitive = false
  /// Current search match (the one Enter moved to): the grid scrolls to it and shows it on the
  /// current-match color when it is in this result's data. A match on a filtered-out row is
  /// skipped for the next entry in `searchMatches` the grid can show.
  var currentMatch: SearchMatch? = nil
  /// Notebook search hits, in find-next order, used to leave a filtered-out row
  var searchMatches: [SearchMatch] = []
  /// Hand a vertical scroll the grid can't take to the parent (notebook list); false for a
  /// grid that fills its panel (editor)
  var forwardsScrollToParent = true
  /// Effective "Hide Column Types" setting: one-line header without the type line
  var hideColumnTypes = false
  /// Names of result columns hidden in the grid; the result, column indices and edits are
  /// unchanged
  var hiddenColumns: Set<String> = []
  /// Highlight painted on the matching cells or rows; the rows stay unchanged
  var highlight: TableHighlight? = nil
  /// Dialect the highlight is evaluated in (`like` case sensitivity)
  var highlightDialect: DatabaseType = .postgresql
  /// Catalog relation for "Referenced Row...". Nil hides the item (a join, or no edit target).
  var relationSchema: String? = nil
  var relationTable: String? = nil
  var foreignKeys: [ForeignKey] = []
  /// Connection dialect. Only decides whether a NULL component skips the lookup.
  var lookupDialect: SQLDialect = .postgresql
  var onLookupReferencedRow: ReferencedRowLookup? = nil
  var onJumpToReferencedRow: ReferencedRowJump? = nil
  /// Result cell text size. The default reads Settings so a slider move refreshes the grid.
  var fontSize: CGFloat = AppSettings.shared.resultFontSize

  /// Row height at the default result font size. Larger and smaller faces scale from this
  /// so an untouched setting keeps the 26pt rows the notebook height math expects.
  static let defaultRowHeight: CGFloat = 26

  static func rowHeight(fontSize: CGFloat) -> CGFloat {
    guard fontSize != AppSettings.defaultResultFontSize else { return defaultRowHeight }
    return (defaultRowHeight * fontSize / AppSettings.defaultResultFontSize)
      .rounded(.toNearestOrAwayFromZero)
  }

  /// Row height for the current result font size
  static var rowHeight: CGFloat { rowHeight(fontSize: AppSettings.shared.resultFontSize) }
  /// Rows shown at once by a grid of `height(rowCount:hideColumnTypes:)`; more rows scroll
  /// inside the grid
  static let maxVisibleRows = 15

  /// Height of the rows only (no header), for a grid placed in a List or LazyVStack
  static func rowsHeight(rowCount: Int) -> CGFloat {
    CGFloat(rowCount) * rowHeight
  }

  /// Header height (set on the header view): name and type lines, or the name only
  static func headerHeight(hideColumnTypes: Bool) -> CGFloat {
    hideColumnTypes ? 24 : 44
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
    tableView.gridStyleMask = .solidVerticalGridLineMask
    tableView.gridColor = NSColor(Color.border)
    tableView.allowsColumnResizing = true
    tableView.allowsColumnReordering = true
    tableView.allowsMultipleSelection = true
    tableView.columnAutoresizingStyle = .noColumnAutoresizing
    tableView.style = .plain
    tableView.backgroundColor = NSColor(Color.cellBackground)
    tableView.headerView = ResultGridHeaderView()
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
    let fontChanged = coordinator.noteFontSize(fontSize, tableView: tableView)
    coordinator.isEditable = isEditable
    coordinator.readOnlyColumns = readOnlyColumns
    coordinator.stagesEdits = stagesEdits
    coordinator.onCommitEdit = onCommitEdit
    coordinator.onStageEdit = onStageEdit
    coordinator.onStageInsert = onStageInsert
    coordinator.onStageDuplicate = onStageDuplicate
    coordinator.onStageDelete = onStageDelete
    coordinator.onRevertStaged = onRevertStaged
    coordinator.onSortChange = onSortChange
    coordinator.onValueFilterChange = onValueFilterChange
    coordinator.onShowCellDetails = onShowCellDetails
    coordinator.onHighlightCell = onHighlightCell
    coordinator.onClearHighlight = onClearHighlight
    coordinator.relationSchema = relationSchema
    coordinator.relationTable = relationTable
    coordinator.foreignKeys = foreignKeys
    coordinator.lookupDialect = lookupDialect
    coordinator.onLookupReferencedRow = onLookupReferencedRow
    coordinator.onJumpToReferencedRow = onJumpToReferencedRow
    coordinator.update(
      tableView, result: result, sortColumn: sortColumn, ascending: ascending,
      searchQuery: searchQuery, caseSensitive: caseSensitive, currentMatch: currentMatch,
      hideColumnTypes: hideColumnTypes, hiddenColumns: hiddenColumns,
      highlight: highlight, highlightDialect: highlightDialect, valueFilter: valueFilter,
      searchMatches: searchMatches, changeSet: changeSet)
    // A font-only change skips `update` (the row model is unchanged). `update` may also
    // refresh only staged rows, so reload every visible cell onto the new face.
    if fontChanged {
      tableView.tableColumn(withIdentifier: ResultGridCoordinator.rowNumberIdentifier)?.width =
        ResultGridCoordinator.rowNumberWidth(rowCount: result.rows.count)
      tableView.reloadData()
    }
  }
}

/// Schema and table for "Referenced Row...". A data viewer uses its relation. Otherwise the
/// edit target's catalog name. Nil for a join or a target that has no name.
func referencedRelation(
  dataViewer: DataViewerState?, editTarget: EditTarget?
) -> (
  schema: String, table: String
)? {
  if let dataViewer {
    return (dataViewer.schema, dataViewer.name)
  }
  guard let schema = editTarget?.schema, let table = editTarget?.name else { return nil }
  return (schema, table)
}

/// The view model's lookup and jump, unchanged. The grid does not send its own SQL.
/// The lookup is pinned to `editTarget`'s connection epoch when the result has one.
func referencedRowHandlers(
  _ viewModel: NotebookViewModel, editTarget: EditTarget?
) -> (
  lookup: ReferencedRowLookup, jump: ReferencedRowJump
) {
  let epoch = editTarget?.connectionEpoch
  return (
    { column, schema, table, rowColumns, values in
      try await viewModel.lookupReferencedRow(
        column: column, schema: schema, table: table, rowColumns: rowColumns, values: values,
        expectedEpoch: epoch)
    },
    { column, schema, table, rowColumns, values in
      viewModel.jumpToReferencedRow(
        column: column, schema: schema, table: table, rowColumns: rowColumns, values: values)
    }
  )
}

/// The match the grid should highlight. When `match` is a table-data row `valueFilter` hides,
/// the notebook search moves to the next hit that is still on screen, so find-next does not
/// stay on a row the grid cannot show. Nil when that hit is not drawn in the grid.
@MainActor
func gridSearchMatchOnScreen(
  _ match: SearchMatch?,
  result: CellResult,
  sortColumn: String?,
  ascending: Bool,
  valueFilter: ColumnValueFilter,
  viewModel: NotebookViewModel
) -> SearchMatch? {
  guard let match else { return nil }
  let model = ResultGridModel(
    result: result, sortColumn: sortColumn, ascending: ascending, valueFilter: valueFilter)
  guard let shown = model.shownSearchMatch(match, matches: viewModel.searchState.matches) else {
    return nil
  }
  if shown.id != match.id,
    let index = viewModel.searchState.matches.firstIndex(where: { $0.id == shown.id }),
    index != viewModel.searchState.currentMatchIndex
  {
    viewModel.searchState.currentMatchIndex = index
    if shown.cellId != match.cellId {
      viewModel.selectedCellId = shown.cellId
    }
    // Terminal: grids assign this match. They must not call back into this function,
    // or two cells that each hide the other's hit re-enter until the main thread overflows.
    NotificationCenter.default.post(
      name: .highlightSearchMatch,
      object: nil,
      userInfo: [
        "match": shown,
        "query": viewModel.searchState.query,
        "caseSensitive": viewModel.searchState.isCaseSensitive,
        "viewModelId": viewModel.id,
        "resolved": true,
      ])
  }
  guard shown.cellId == match.cellId, shown.isInResultGrid else { return nil }
  return shown
}

/// A match published with `resolved: true`. This grid draws it only when the row is still
/// on screen. It does not search onward — the publisher already picked the match.
@MainActor
func assignedSearchMatch(
  _ match: SearchMatch?,
  cellId: UUID,
  result: CellResult,
  sortColumn: String?,
  ascending: Bool,
  valueFilter: ColumnValueFilter
) -> SearchMatch? {
  guard let match, match.cellId == cellId, match.isInResultGrid else { return nil }
  guard case .tableData(let row, _) = match.matchType else { return match }
  let model = ResultGridModel(
    result: result, sortColumn: sortColumn, ascending: ascending, valueFilter: valueFilter)
  return model.displayedRow(forOriginalRow: row) != nil ? match : nil
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
  nonisolated static func shouldForward(
    deltaY: CGFloat, offsetY: CGFloat, maxOffsetY: CGFloat
  ) -> Bool {
    maxOffsetY < 1 || (deltaY > 0 && offsetY < 1) || (deltaY < 0 && offsetY > maxOffsetY - 1)
  }

  /// One scroll event's hand-off. `locksForward` is nil when the event must not choose
  /// (no delta, or Shift+wheel). The view locks that choice for the rest of the gesture.
  nonisolated static func scrollHandOff(
    deltaX: CGFloat,
    deltaY: CGFloat,
    phase: NSEvent.Phase,
    momentumPhase: NSEvent.Phase,
    modifiers: NSEvent.ModifierFlags,
    offsetY: CGFloat,
    maxOffsetY: CGFloat,
    forwardsToParent: Bool
  ) -> (startsGesture: Bool, locksForward: Bool?) {
    let startsGesture =
      phase == .mayBegin || phase == .began || (phase.isEmpty && momentumPhase.isEmpty)
    let locksForward: Bool? =
      (deltaX != 0 || deltaY != 0) && !modifiers.contains(.shift)
      ? forwardsToParent && abs(deltaY) > abs(deltaX)
        && shouldForward(deltaY: deltaY, offsetY: offsetY, maxOffsetY: maxOffsetY)
      : nil
    return (startsGesture, locksForward)
  }

  override func scrollWheel(with event: NSEvent) {
    let insets = contentView.contentInsets
    let bounds = contentView.bounds
    let maxOffsetY =
      (documentView?.frame.height ?? 0) + insets.top + insets.bottom - bounds.height
    let handOff = Self.scrollHandOff(
      deltaX: event.scrollingDeltaX,
      deltaY: event.scrollingDeltaY,
      phase: event.phase,
      momentumPhase: event.momentumPhase,
      modifiers: event.modifierFlags,
      offsetY: bounds.origin.y + insets.top,
      maxOffsetY: maxOffsetY,
      forwardsToParent: forwardsToParent)
    if handOff.startsGesture { forwardsGesture = nil }
    if forwardsGesture == nil, let locksForward = handOff.locksForward {
      forwardsGesture = locksForward
    }
    if forwardsGesture == true {
      nextResponder?.scrollWheel(with: event)
    } else {
      super.scrollWheel(with: event)
    }
  }
}

/// Header view with an opaque background (distinct from the body, same as the "#" gutter) and a bottom border. Super (not called) draws a
/// translucent background over the fill, so the header cells are drawn here.
/// A click on a column's filter icon opens the value popover and does not sort.
final class ResultGridHeaderView: NSTableHeaderView {
  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if let hit = filterButton(at: point) {
      (tableView as? ResultGridTableView)?.coordinator?.showColumnFilter(
        resultColumn: hit.column, relativeTo: hit.rect, of: self)
      return
    }
    super.mouseDown(with: event)
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    guard let tableView else { return }
    for index in tableView.tableColumns.indices {
      guard let button = filterButtonRect(tableColumn: index) else { continue }
      addCursorRect(button, cursor: .pointingHand)
    }
  }

  /// Result column index and button rect when `point` is on a filter icon
  private func filterButton(at point: NSPoint) -> (column: Int, rect: NSRect)? {
    guard let tableView else { return nil }
    for index in tableView.tableColumns.indices {
      guard let button = filterButtonRect(tableColumn: index)?.insetBy(dx: -2, dy: -2),
        button.contains(point),
        let resultColumn = Int(tableView.tableColumns[index].identifier.rawValue)
      else { continue }
      return (resultColumn, button)
    }
    return nil
  }

  private func filterButtonRect(tableColumn index: Int) -> NSRect? {
    guard let tableView, tableView.tableColumns.indices.contains(index) else { return nil }
    let column = tableView.tableColumns[index]
    guard !column.isHidden, let cell = column.headerCell as? ResultGridHeaderCell else {
      return nil
    }
    var columnRect = headerRect(ofColumn: index)
    if index == draggedColumn { columnRect.origin.x += draggedDistance }
    return cell.filterButtonRect(columnRect: columnRect, headerBounds: bounds)
  }

  override func draw(_ dirtyRect: NSRect) {
    ResultGridRowNumberCell.backgroundColor.setFill()
    dirtyRect.fill()
    if let tableView {
      for (index, column) in tableView.tableColumns.enumerated() where !column.isHidden {
        var rect = headerRect(ofColumn: index)
        if index == draggedColumn { rect.origin.x += draggedDistance }
        guard rect.intersects(dirtyRect) else { continue }
        column.headerCell.draw(withFrame: rect, in: self)
        // The "#" header cell draws its own, stronger separator
        guard column.identifier != ResultGridCoordinator.rowNumberIdentifier else { continue }
        NSColor(Color.border).setFill()
        NSRect(x: rect.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
      }
    }
    NSColor(Color.border).setFill()
    NSRect(x: bounds.minX, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
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
  /// Row currently drawn with the hover background
  private(set) var hoveredRow = -1
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

  /// Right-click menu of the cell under the pointer (none on the "#" gutter or outside the
  /// rows); an unselected row becomes the selection first, as in Finder
  override func menu(for event: NSEvent) -> NSMenu? {
    let point = convert(event.locationInWindow, from: nil)
    let row = row(at: point)
    let tableColumn = column(at: point)
    guard row >= 0, tableColumn >= 0,
      let column = Int(tableColumns[tableColumn].identifier.rawValue)
    else { return nil }
    if !selectedRowIndexes.contains(row) {
      selectRowIndexes([row], byExtendingSelection: false)
    }
    return coordinator?.contextMenu(row: row, column: column)
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
    setHoveredRow(-1)
    hideDetailsButton()
  }

  /// Shows the details button over the cell at `point` (table coordinates), or hides it when
  /// the point is on no visible cell or a cell is being edited
  func updateDetailsButton(at point: NSPoint) {
    let row = row(at: point)
    setHoveredRow(visibleRect.contains(point) ? row : -1)
    let tableColumn = column(at: point)
    guard row >= 0, tableColumn >= 0, visibleRect.contains(point),
      coordinator?.isEditing != true,
      tableColumns[tableColumn].identifier != ResultGridCoordinator.rowNumberIdentifier,
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

  private func setHoveredRow(_ row: Int) {
    guard row != hoveredRow else { return }
    let previous = hoveredRow
    hoveredRow = row
    for (index, hovered) in [(previous, false), (row, true)]
    where index >= 0 && index < numberOfRows {
      (rowView(atRow: index, makeIfNecessary: false) as? ResultGridRowView)?.isHovered = hovered
    }
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
    if coordinator?.handleDeleteKey(event, tableView: self) == true { return }
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
