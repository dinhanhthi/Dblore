//
//  ResultGridFrozenPane.swift
//  Dblore
//
//  Frozen leading columns of the result grid: a second table in its own scroll view, laid over
//  the left edge of the grid's scroll view. It shows the "#" gutter and the visible result
//  columns up to the frozen-through column (by name, in the grid's current order). The grid
//  keeps every column; at horizontal offset 0 the pane covers exactly the same columns, and a
//  horizontal scroll slides the other columns under it.
//
//  The grid's scroll view owns scrolling: wheel and trackpad events over the pane go to it, and
//  the vertical offset is mirrored through clip-view bounds notifications. The coordinator is
//  the data source and delegate of both tables; the pane mirrors selection, column widths,
//  sort, row and header heights, and draws the grid's selection emphasis (a click in the pane
//  hands the keyboard focus to the grid). Frames are AppKit only: no SwiftUI state is measured
//  or written, so a live window resize stays one layout pass.
//

import AppKit
import SwiftUI

/// Leading grid columns frozen through one result column, resolved by name against the grid's
/// current column order and hidden columns
struct ResultGridFrozenBand {
  /// One table column of the grid, in on-screen order
  struct Column {
    let identifier: NSUserInterfaceItemIdentifier
    /// Result column name; nil for the "#" gutter
    let name: String?
    let isHidden: Bool
  }

  /// "#" and the visible result columns up to the frozen-through one, in on-screen order
  let identifiers: [NSUserInterfaceItemIdentifier]
  /// Table-column index (hidden columns counted) of the last frozen column
  let end: Int

  /// Nil when nothing is frozen: no name, a name that is no longer a column, or no visible
  /// column at or before it (`GridColumnPrefsStore.resolvedFrozenThrough`)
  init?(columns: [Column], frozenThrough: String?) {
    let hidden = Set(columns.filter(\.isHidden).compactMap(\.name))
    guard
      let resolved = GridColumnPrefsStore.resolvedFrozenThrough(
        frozenThrough, columns: columns.compactMap(\.name), hidden: hidden),
      let end = columns.firstIndex(where: { $0.name == resolved && !$0.isHidden })
    else { return nil }
    self.end = end
    identifiers = columns[...end].filter { !$0.isHidden }.map(\.identifier)
  }

  /// Largest share of the grid's visible width the band may take when a column is frozen
  nonisolated static let maxViewportShare: CGFloat = 2.0 / 3.0

  /// Whether a band of the visible columns with `widths` ("#" through the frozen-through one)
  /// fits in `maxViewportShare` of a grid `viewportWidth` wide. A grid not laid out yet
  /// (width 0) fits nothing.
  nonisolated static func fitsViewport(widths: [CGFloat], viewportWidth: CGFloat) -> Bool {
    viewportWidth > 0 && widths.reduce(0, +) <= viewportWidth * maxViewportShare
  }

  /// Whether a header drag may move table column `from` to `to`: "#" stays first, and no
  /// column crosses the band's edge (only the freeze command changes the frozen set). `to` is
  /// -1 when a drag starts: any column but "#" may start one.
  static func allowsMove(from: Int, to: Int, band: ResultGridFrozenBand?) -> Bool {
    guard from != 0, to != 0 else { return false }
    guard to >= 0, let band else { return true }
    return (from <= band.end) == (to <= band.end)
  }
}

/// Scroll view of the frozen pane: a subview of the grid's `ResultGridScrollView`, placed by its
/// `tile()` over the clip view's left edge, as wide as the frozen columns
final class ResultGridFrozenPane: NSScrollView {
  /// The pane's table. Data source and delegate: the grid's coordinator.
  let table: ResultGridTableView
  private weak var grid: ResultGridTableView?
  private let edge = ResultGridFrozenEdge()
  /// Set while the pane changes one side itself (selection, width, sort, scroll)
  private(set) var isMirroring = false
  private var firstResponderObservation: NSKeyValueObservation?
  private weak var observedWindow: NSWindow?

  init(grid: ResultGridTableView, coordinator: ResultGridCoordinator) {
    self.grid = grid
    table = ResultGridView.makeTableView(coordinator: coordinator)
    super.init(frame: .zero)
    // The frozen set changes only through the freeze command; a click hands focus to the grid
    table.allowsColumnReordering = false
    table.refusesFirstResponder = true
    table.rowHeight = grid.rowHeight
    table.paneGrid = grid
    table.hoverPeer = grid
    grid.hoverPeer = table
    table.dataSource = coordinator
    table.delegate = coordinator
    documentView = table
    hasVerticalScroller = false
    hasHorizontalScroller = false
    horizontalScrollElasticity = .none
    verticalScrollElasticity = grid.enclosingScrollView?.verticalScrollElasticity ?? .automatic
    drawsBackground = false
    addSubview(edge)
    let center = NotificationCenter.default
    contentView.postsBoundsChangedNotifications = true
    center.addObserver(
      self, selector: #selector(paneDidScroll(_:)), name: NSView.boundsDidChangeNotification,
      object: contentView)
    if let gridClip = grid.enclosingScrollView?.contentView {
      gridClip.postsBoundsChangedNotifications = true
      center.addObserver(
        self, selector: #selector(gridDidScroll(_:)), name: NSView.boundsDidChangeNotification,
        object: gridClip)
    }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  // MARK: - Install

  /// Adds the pane over the grid's header clip view (else over its clip view)
  func install(in scrollView: ResultGridScrollView) {
    scrollView.addSubview(self, positioned: .above, relativeTo: gridHeaderClip(in: scrollView))
    scrollView.frozenPane = self
  }

  /// Removes the pane; the grid shows its own leading columns again
  func uninstall() {
    let center = NotificationCenter.default
    center.removeObserver(self, name: NSView.boundsDidChangeNotification, object: contentView)
    if let gridClip = grid?.enclosingScrollView?.contentView {
      center.removeObserver(self, name: NSView.boundsDidChangeNotification, object: gridClip)
    }
    if let observedWindow {
      center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: observedWindow)
      center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: observedWindow)
    }
    observedWindow = nil
    firstResponderObservation = nil
    if grid?.hoverPeer === table { grid?.hoverPeer = nil }
    table.hoverPeer = nil
    if let scrollView = superview as? ResultGridScrollView, scrollView.frozenPane === self {
      scrollView.frozenPane = nil
    }
    removeFromSuperview()
    // After the removal: an inline edit it ends still hands the focus back to the grid
    table.paneGrid = nil
  }

  /// The grid header's clip view when it is a direct subview of `scrollView`, else the clip view
  private func gridHeaderClip(in scrollView: NSScrollView) -> NSView {
    if let clip = grid?.headerView?.superview, clip.superview === scrollView { return clip }
    return scrollView.contentView
  }

  // MARK: - Sync from the grid

  /// Copies the band's columns, the row and header heights, the sort and the selection from the
  /// grid. Reloads the pane only when `reload` (the grid reloaded) or its column set changed.
  func sync(band: ResultGridFrozenBand, reload: Bool) {
    guard let grid else { return }
    if table.rowHeight != grid.rowHeight { table.rowHeight = grid.rowHeight }
    let columnsChanged = syncColumns(band, from: grid)
    syncHeaderHeight(from: grid)
    if table.sortDescriptors != grid.sortDescriptors {
      mirroring { table.sortDescriptors = grid.sortDescriptors }
    }
    if reload || columnsChanged { table.reloadData() }
    mirrorSelection(from: grid)
    if let scrollView = superview as? NSScrollView { layout(over: scrollView) }
  }

  /// True when the column set changed. Titles, header content, widths and sort keys follow the
  /// grid's columns on every call (the header redraws only when one of them changed).
  private func syncColumns(_ band: ResultGridFrozenBand, from grid: NSTableView) -> Bool {
    let source = band.identifiers.compactMap { grid.tableColumn(withIdentifier: $0) }
    var columnsChanged = false
    var headerChanged = false
    mirroring {
      if table.tableColumns.map(\.identifier) != source.map(\.identifier) {
        table.tableColumns.forEach(table.removeTableColumn)
        for column in source {
          let copy = NSTableColumn(identifier: column.identifier)
          // Before the title: the title is stored in the header cell
          copy.headerCell = ResultGridHeaderCell(textCell: column.title)
          table.addTableColumn(copy)
        }
        columnsChanged = true
        headerChanged = true
      }
      for (copy, column) in zip(table.tableColumns, source) {
        if copy.title != column.title { copy.title = column.title }
        if copy.minWidth != column.minWidth { copy.minWidth = column.minWidth }
        if copy.maxWidth != column.maxWidth { copy.maxWidth = column.maxWidth }
        if copy.resizingMask != column.resizingMask { copy.resizingMask = column.resizingMask }
        if copy.sortDescriptorPrototype != column.sortDescriptorPrototype {
          copy.sortDescriptorPrototype = column.sortDescriptorPrototype
        }
        if copy.width != column.width {
          copy.width = column.width
          headerChanged = true
        }
        if let cell = copy.headerCell as? ResultGridHeaderCell,
          let gridCell = column.headerCell as? ResultGridHeaderCell,
          cell.content != gridCell.content
        {
          cell.content = gridCell.content
          headerChanged = true
        }
      }
    }
    if headerChanged, let header = table.headerView {
      header.needsDisplay = true
      header.window?.invalidateCursorRects(for: header)
    }
    return columnsChanged
  }

  /// Same header height as the grid: two lines, or one with Hide Column Types
  private func syncHeaderHeight(from grid: NSTableView) {
    guard let gridHeader = grid.headerView, let header = table.headerView,
      header.frame.height != gridHeader.frame.height
    else { return }
    header.frame.size.height = gridHeader.frame.height
    tile()
  }

  // MARK: - Layout

  /// Over the grid's clip view from its left edge, as wide as the frozen columns (at most the
  /// clip view), at the grid's vertical offset. Frames only, read from AppKit geometry.
  func layout(over scrollView: NSScrollView) {
    keepAboveGridHeader(in: scrollView)
    let clip = scrollView.contentView.frame
    let frame = NSRect(
      x: clip.minX, y: clip.minY, width: min(bandWidth, clip.width), height: clip.height)
    if self.frame != frame { self.frame = frame }
    mirrorVerticalOffset(from: scrollView.contentView, to: self)
  }

  private var bandWidth: CGFloat {
    table.tableColumns.reduce(0) { $0 + $1.width + table.intercellSpacing.width }
  }

  /// The scroll view may re-add its header clip view above the pane
  private func keepAboveGridHeader(in scrollView: NSScrollView) {
    let reference = gridHeaderClip(in: scrollView)
    guard let index = scrollView.subviews.firstIndex(of: self),
      let referenceIndex = scrollView.subviews.firstIndex(of: reference),
      index < referenceIndex
    else { return }
    scrollView.addSubview(self, positioned: .above, relativeTo: reference)
  }

  /// The edge line stays on top at the trailing edge, over the header and the rows
  override func tile() {
    super.tile()
    let frame = NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height)
    if edge.frame != frame { edge.frame = frame }
    if subviews.last !== edge { addSubview(edge, positioned: .above, relativeTo: nil) }
  }

  // MARK: - Scrolling

  /// One owner for momentum and the elastic bounce: the grid's scroll view
  override func scrollWheel(with event: NSEvent) {
    if let gridScroll = grid?.enclosingScrollView {
      gridScroll.scrollWheel(with: event)
    } else {
      super.scrollWheel(with: event)
    }
  }

  @objc private func gridDidScroll(_ notification: Notification) {
    guard let clip = notification.object as? NSClipView else { return }
    mirrorVerticalOffset(from: clip, to: self)
  }

  /// A drag selection near the pane's edge autoscrolls the pane; the grid follows
  @objc private func paneDidScroll(_: Notification) {
    guard let gridScroll = grid?.enclosingScrollView else { return }
    mirrorVerticalOffset(from: contentView, to: gridScroll)
  }

  /// Copies the vertical offset (an elastic overshoot included) and keeps the target's
  /// horizontal offset
  private func mirrorVerticalOffset(from source: NSClipView, to target: NSScrollView) {
    guard !isMirroring else { return }
    let clip = target.contentView
    let y = source.bounds.origin.y
    guard clip.bounds.origin.y != y else { return }
    mirroring {
      clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: y))
      target.reflectScrolledClipView(clip)
    }
  }

  // MARK: - Selection, widths, emphasis

  /// Copies the selection of one table onto the other (rows the target does not have yet are
  /// left out until it reloads)
  func mirrorSelection(from source: NSTableView) {
    guard !isMirroring, let grid else { return }
    let target: NSTableView
    if source === table {
      target = grid
    } else if source === grid {
      target = table
    } else {
      return
    }
    let count = target.numberOfRows
    let rows = source.selectedRowIndexes.filteredIndexSet { $0 < count }
    guard target.selectedRowIndexes != rows else { return }
    mirroring { target.selectRowIndexes(rows, byExtendingSelection: false) }
  }

  /// A column width changed in one table: the same column in the other follows, and the pane
  /// takes the band's new width (a divider drag in the pane header resizes the grid column too)
  func columnDidResize(_ notification: Notification) {
    guard !isMirroring, let grid,
      let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn
    else { return }
    let source = notification.object as AnyObject?
    let target: NSTableView
    if source === table {
      target = grid
    } else if source === grid {
      target = table
    } else {
      return
    }
    if let twin = target.tableColumn(withIdentifier: column.identifier), twin.width != column.width
    {
      mirroring { twin.width = column.width }
    }
    if let scrollView = superview as? NSScrollView { layout(over: scrollView) }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    observeWindow()
  }

  /// The pane's selection emphasis follows the window's key state and the grid's focus
  private func observeWindow() {
    guard window !== observedWindow else { return }
    let center = NotificationCenter.default
    if let observedWindow {
      center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: observedWindow)
      center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: observedWindow)
    }
    observedWindow = window
    firstResponderObservation = nil
    guard let window else { return }
    let selector = #selector(windowKeyDidChange(_:))
    center.addObserver(
      self, selector: selector, name: NSWindow.didBecomeKeyNotification, object: window)
    center.addObserver(
      self, selector: selector, name: NSWindow.didResignKeyNotification, object: window)
    firstResponderObservation = window.observe(\.firstResponder) { [weak self] _, _ in
      MainActor.assumeIsolated { self?.refreshEmphasis() }
    }
  }

  @objc private func windowKeyDidChange(_: Notification) {
    refreshEmphasis()
  }

  private func refreshEmphasis() {
    table.enumerateAvailableRowViews { rowView, _ in
      (rowView as? ResultGridRowView)?.refreshEmphasis()
    }
  }

  private func mirroring(_ body: () -> Void) {
    let wasMirroring = isMirroring
    isMirroring = true
    body()
    isMirroring = wasMirroring
  }
}

/// Line at the band's trailing edge, in the "#" gutter's separator color, so the frozen columns
/// read as pinned when the others slide under them. Clicks pass through to the header divider.
private final class ResultGridFrozenEdge: NSView {
  override func draw(_ dirtyRect: NSRect) {
    ResultGridRowNumberCell.separatorColor.setFill()
    bounds.fill()
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
