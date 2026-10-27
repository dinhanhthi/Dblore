// ResultGridFreezeTests.swift
// The frozen-through column is stored per table by name and resolved against the current column
// order, so it survives reorder, hidden columns and grid rebuilds.

import AppKit
import Testing

@testable import Dblore

@MainActor
@Suite("Result Grid Freeze Tests")
struct ResultGridFreezeTests {
  /// An isolated defaults suite, removed when `body` returns
  private func withDefaults(_ body: (UserDefaults) -> Void) {
    let name = "ace.thi.Dblore.tests.gridColumnPrefs.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    body(defaults)
  }

  private func key(
    host: String = "h", database: String = "app", schema: String = "public",
    table: String = "users"
  ) -> String {
    GridColumnPrefsStore.key(
      for: ConnectionConfig(databaseType: .postgresql, host: host, port: 5432, database: database),
      schema: schema, name: table)
  }

  @Test("The frozen-through name is pinned across reorder, hide and rebuild")
  func pinnedByName() {
    withDefaults { defaults in
      let store = GridColumnPrefsStore(defaults: defaults)
      store.setFrozenThrough("b", for: key())
      // A new store (a relaunch) reads it back
      let stored = GridColumnPrefsStore(defaults: defaults).frozenThrough(for: key())
      #expect(stored == "b")

      let resolve = { (columns: [String], hidden: Set<String>) in
        GridColumnPrefsStore.resolvedFrozenThrough(stored, columns: columns, hidden: hidden)
      }
      // Reorder: still the same column, wherever it moved
      #expect(resolve(["c", "a", "b", "d"], []) == "b")
      // Hidden: the last visible column at or before it
      #expect(resolve(["a", "b", "c"], ["b"]) == "a")
      #expect(resolve(["b", "a", "c"], ["b"]) == nil)
      // Rebuild without the column: no freeze
      #expect(resolve(["a", "c", "d"], []) == nil)

      store.setFrozenThrough(nil, for: key())
      #expect(store.frozenThrough(for: key()) == nil)
    }
  }

  @Test("Another table, schema or connection does not share the frozen column")
  func perTableKeying() {
    withDefaults { defaults in
      let store = GridColumnPrefsStore(defaults: defaults)
      store.setFrozenThrough("id", for: key())
      #expect(store.frozenThrough(for: key(table: "orders")) == nil)
      #expect(store.frozenThrough(for: key(schema: "audit")) == nil)
      #expect(store.frozenThrough(for: key(database: "other")) == nil)
      #expect(store.frozenThrough(for: key(host: "other")) == nil)
      #expect(store.frozenThrough(for: key()) == "id")
    }
  }

  /// Grid columns in on-screen order: "#" then result columns named by `names`
  private func gridColumns(
    _ names: [String], hidden: Set<String> = []
  )
    -> [ResultGridFrozenBand.Column]
  {
    [.init(identifier: ResultGridCoordinator.rowNumberIdentifier, name: nil, isHidden: false)]
      + names.enumerated().map { index, name in
        .init(
          identifier: NSUserInterfaceItemIdentifier(String(index)), name: name,
          isHidden: hidden.contains(name))
      }
  }

  @Test("The pane shows # and the visible columns through the frozen one, in on-screen order")
  func bandColumns() {
    let band = ResultGridFrozenBand(
      columns: gridColumns(["a", "b", "c", "d"], hidden: ["b"]), frozenThrough: "c")
    #expect(band?.identifiers.map(\.rawValue) == ["rowNumber", "0", "2"])
    #expect(band?.end == 3)
    // Hidden frozen-through column: the band ends at the last visible column before it
    let shrunk = ResultGridFrozenBand(
      columns: gridColumns(["a", "b", "c"], hidden: ["b"]), frozenThrough: "b")
    #expect(shrunk?.identifiers.map(\.rawValue) == ["rowNumber", "0"])
    #expect(shrunk?.end == 1)
    #expect(ResultGridFrozenBand(columns: gridColumns(["a", "b"]), frozenThrough: nil) == nil)
    #expect(ResultGridFrozenBand(columns: gridColumns(["a", "b"]), frozenThrough: "x") == nil)
  }

  @Test("Freezing is refused when the band would take more than 2/3 of the grid's width")
  func viewportCap() {
    // "#" (40) and three 100-point columns
    let widths: [CGFloat] = [40, 100, 100, 100]
    #expect(ResultGridFrozenBand.fitsViewport(widths: Array(widths[...2]), viewportWidth: 510))
    // Exactly 2/3 fits
    #expect(ResultGridFrozenBand.fitsViewport(widths: widths, viewportWidth: 510))
    #expect(!ResultGridFrozenBand.fitsViewport(widths: widths, viewportWidth: 500))
    // A grid not laid out yet freezes nothing
    #expect(!ResultGridFrozenBand.fitsViewport(widths: [40, 10], viewportWidth: 0))
  }

  @Test("A header drag never moves # or crosses the band's edge")
  func reorderAcrossEdge() {
    let band = ResultGridFrozenBand(columns: gridColumns(["a", "b", "c", "d"]), frozenThrough: "b")
    #expect(band?.end == 2)
    #expect(!ResultGridFrozenBand.allowsMove(from: 0, to: 1, band: band))
    #expect(!ResultGridFrozenBand.allowsMove(from: 3, to: 2, band: band))
    #expect(!ResultGridFrozenBand.allowsMove(from: 1, to: 3, band: band))
    #expect(ResultGridFrozenBand.allowsMove(from: 3, to: 4, band: band))
    #expect(ResultGridFrozenBand.allowsMove(from: 1, to: 2, band: band))
    // A drag starts with no target column (-1): any column but "#" may start one
    #expect(ResultGridFrozenBand.allowsMove(from: 3, to: -1, band: band))
    #expect(ResultGridFrozenBand.allowsMove(from: 1, to: -1, band: band))
    #expect(!ResultGridFrozenBand.allowsMove(from: 0, to: -1, band: band))
    // Nothing frozen: only "#" stays put
    #expect(ResultGridFrozenBand.allowsMove(from: 3, to: 1, band: nil))
    #expect(!ResultGridFrozenBand.allowsMove(from: 2, to: 0, band: nil))
  }

  private let result = CellResult(
    columns: [
      ColumnInfo(name: "customer_name", type: "text"), ColumnInfo(name: "city", type: "text"),
    ],
    rows: [[.string("a"), .string("b")]], rowCount: 1)

  @Test("Nothing frozen: the header menu offers Freeze only, and no pane is installed")
  func nothingFrozen() {
    let coordinator = ResultGridCoordinator()
    let tableView = NSTableView()
    coordinator.update(tableView, result: result, sortColumn: nil, ascending: true)
    // A grid without the freeze callback has no freeze items
    #expect(coordinator.headerContextMenu(tableColumn: 1, in: tableView) == nil)
    coordinator.onFreezeChange = { _ in }
    let menu = coordinator.headerContextMenu(tableColumn: 1, in: tableView)
    #expect(menu?.items.map(\.title) == ["Freeze Up to This Column"])
    #expect(coordinator.frozenPane == nil)
    #expect(coordinator.frozenBand == nil)
  }

  @Test("Freezing installs the pane and widens the pinned column; unfreezing removes the pane")
  func freezeAndUnfreeze() throws {
    let coordinator = ResultGridCoordinator()
    let grid = ResultGridView.makeTableView(coordinator: coordinator)
    let scrollView = ResultGridScrollView()
    scrollView.documentView = grid
    coordinator.update(grid, result: result, sortColumn: nil, ascending: true)
    let column = grid.tableColumns[1]
    let cell = try #require(column.headerCell as? ResultGridHeaderCell)
    // The name just fits before the pin
    column.width = cell.fittingWidth()
    let unpinnedWidth = column.width

    coordinator.frozenThroughColumn = "customer_name"
    coordinator.update(grid, result: result, sortColumn: nil, ascending: true)
    let pane = try #require(coordinator.frozenPane)
    #expect(scrollView.frozenPane === pane)
    #expect(pane.superview === scrollView)
    #expect(pane.table.tableColumns.map(\.identifier.rawValue) == ["rowNumber", "0"])
    #expect(cell.content.isFrozenThrough)
    #expect(column.width > unpinnedWidth)
    #expect(column.width == cell.fittingWidth())
    #expect(pane.table.tableColumns[1].width == column.width)

    // A width the user narrows stays through a full update (here a sort); the pin stays on
    column.width = cell.fittingWidth() - 20
    let narrowedWidth = column.width
    coordinator.update(grid, result: result, sortColumn: "customer_name", ascending: true)
    #expect(column.width == narrowedWidth)
    #expect(cell.content.isFrozenThrough)

    coordinator.frozenThroughColumn = nil
    coordinator.update(grid, result: result, sortColumn: "customer_name", ascending: true)
    #expect(coordinator.frozenPane == nil)
    #expect(scrollView.frozenPane == nil)
    #expect(pane.superview == nil)
    #expect(!cell.content.isFrozenThrough)
  }
}
