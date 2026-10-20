// ResultGridCoordinatorTests.swift
// The NSTableView coordinator reads rows, NULL text and TSV through ResultGridModel: every
// table row is a displayed (sorted) row.

import AppKit
import Testing

@testable import Dblore

@Suite("Result grid coordinator")
@MainActor
struct ResultGridCoordinatorTests {
  private let result = CellResult(
    columns: [ColumnInfo(name: "id", type: "int4"), ColumnInfo(name: "name", type: "text")],
    rows: [[.int(3), .string("c")], [.int(1), .string("a")], [.int(2), .null]],
    rowCount: 3)

  private func makeGrid(
    sortColumn: String?, ascending: Bool = true
  ) -> (
    ResultGridCoordinator, NSTableView
  ) {
    let coordinator = ResultGridCoordinator()
    let tableView = NSTableView()
    coordinator.update(tableView, result: result, sortColumn: sortColumn, ascending: ascending)
    return (coordinator, tableView)
  }

  private func cell(
    _ grid: (ResultGridCoordinator, NSTableView), row: Int, column: Int
  )
    -> NSTextField?
  {
    let (coordinator, tableView) = grid
    // Table column 0 is the "#" row number column
    let view = coordinator.tableView(
      tableView, viewFor: tableView.tableColumns[column + 1], row: row)
    return (view as? NSTableCellView)?.textField
  }

  @Test("Rows and columns map through the coordinator, sorted rows included")
  func rowColumnMapping() {
    let unsorted = makeGrid(sortColumn: nil)
    #expect(unsorted.0.numberOfRows(in: unsorted.1) == 3)
    #expect(unsorted.1.tableColumns.map { $0.title } == ["#", "id", "name"])
    #expect(cell(unsorted, row: 0, column: 1)?.stringValue == "c")

    let descending = makeGrid(sortColumn: "id", ascending: false)
    #expect((0..<3).map { cell(descending, row: $0, column: 0)?.stringValue } == ["3", "2", "1"])
    #expect(cell(descending, row: 2, column: 1)?.stringValue == "a")
  }

  @Test("Copy of a 2x2 selection is the TSV of the selected displayed rows")
  func tsvCopy() {
    let (coordinator, tableView) = makeGrid(sortColumn: "id")
    tableView.selectRowIndexes(IndexSet([0, 2]), byExtendingSelection: false)
    #expect(coordinator.selectionTSV(tableView) == "1\ta\n3\tc")
  }

  @Test("Referenced Row... appears only when that column has a reference")
  func referencedRowMenuFollowsTheColumn() {
    let (coordinator, _) = makeGrid(sortColumn: nil)
    coordinator.relationSchema = "public"
    coordinator.relationTable = "orders"
    coordinator.foreignKeys = [
      ForeignKey(
        constraintName: "orders_user", sourceSchema: "public", sourceTable: "orders",
        sourceColumns: ["id"], targetSchema: "public", targetTable: "users", targetColumns: ["id"]
      )
    ]

    let idMenu = coordinator.contextMenu(row: 0, column: 0)?.items.map(\.title) ?? []
    let nameMenu = coordinator.contextMenu(row: 0, column: 1)?.items.map(\.title) ?? []
    #expect(idMenu.contains("Referenced Row..."))
    #expect(!nameMenu.contains("Referenced Row..."))
    #expect(coordinator.referencedRowRequest(row: 0, column: 0)?.followsReference == true)

    coordinator.foreignKeys = [
      ForeignKey(
        constraintName: "orders_pair", sourceSchema: "public", sourceTable: "orders",
        sourceColumns: ["id", "tenant"], targetSchema: "public", targetTable: "tenants",
        targetColumns: ["id", "tenant"])
    ]
    let partial = coordinator.contextMenu(row: 0, column: 0)?.items.map(\.title) ?? []
    #expect(!partial.contains("Referenced Row..."))

    coordinator.relationSchema = nil
    coordinator.foreignKeys = [
      ForeignKey(
        constraintName: "orders_user", sourceSchema: "public", sourceTable: "orders",
        sourceColumns: ["id"], targetSchema: "public", targetTable: "users", targetColumns: ["id"]
      )
    ]
    let join = coordinator.contextMenu(row: 0, column: 0)?.items.map(\.title) ?? []
    #expect(!join.contains("Referenced Row..."))
  }

  /// `SELECT id, customer_id AS cid, total AS customer_id, tenant AS t FROM orders`
  private func aliasedGrid() -> ResultGridCoordinator {
    let aliased = CellResult(
      columns: ["id", "cid", "customer_id", "t"].map { ColumnInfo(name: $0, type: "int4") },
      rows: [[.int(1), .int(9), .int(500), .int(3)]], rowCount: 1)
    let coordinator = ResultGridCoordinator()
    coordinator.update(NSTableView(), result: aliased, sortColumn: nil, ascending: true)
    coordinator.relationSchema = "public"
    coordinator.relationTable = "orders"
    coordinator.baseColumnNames = ["id", "customer_id", "total", "tenant"]
    return coordinator
  }

  private let customerKey = ForeignKey(
    constraintName: "orders_customer", sourceSchema: "public", sourceTable: "orders",
    sourceColumns: ["customer_id"], targetSchema: "public", targetTable: "customers",
    targetColumns: ["id"])

  @Test("An aliased key column offers its reference under the base column name")
  func aliasedColumnOffersReference() throws {
    let coordinator = aliasedGrid()
    coordinator.foreignKeys = [customerKey]
    #expect(coordinator.referencedForeignKey(column: 1)?.constraintName == "orders_customer")
    let request = try #require(coordinator.referencedRowRequest(row: 0, column: 1))
    #expect(request.column == "customer_id")
    #expect(request.values["customer_id"] == .int(9))
    #expect(request.foreignKey.targetTable == "customers")
    #expect(request.followsReference)
    let query = try #require(
      ForeignKeyLookup.lookupSQL(
        for: request.foreignKey, values: request.values, dialect: .postgresql))
    #expect(query.parameters["fk1"] == .text("9"))
  }

  @Test("A column renamed to a key column's name is not that key")
  func renamedColumnIsNotTheKey() {
    let coordinator = aliasedGrid()
    coordinator.foreignKeys = [customerKey]
    // Column 2 is `total AS customer_id`
    #expect(coordinator.referencedForeignKey(column: 2) == nil)
    #expect(coordinator.referencedRowRequest(row: 0, column: 2) == nil)
  }

  @Test("A composite key needs every source column through the base names")
  func compositeKeyThroughAliases() {
    let coordinator = aliasedGrid()
    let pair = ForeignKey(
      constraintName: "orders_pair", sourceSchema: "public", sourceTable: "orders",
      sourceColumns: ["customer_id", "tenant"], targetSchema: "public", targetTable: "accounts",
      targetColumns: ["id", "tenant"])
    coordinator.foreignKeys = [pair]
    #expect(coordinator.referencedForeignKey(column: 1)?.constraintName == "orders_pair")
    #expect(coordinator.referencedForeignKey(column: 3)?.constraintName == "orders_pair")
    #expect(coordinator.referencedRowRequest(row: 0, column: 3)?.values["tenant"] == .int(3))

    coordinator.baseColumnNames = ["id", "customer_id", "total", nil]
    #expect(coordinator.referencedForeignKey(column: 1) == nil)
    #expect(coordinator.referencedForeignKey(column: 3) == nil)
  }

  @Test("A NULL component stays on the menu and is not a lookup")
  func nullComponentIsNotALookup() {
    let (coordinator, _) = makeGrid(sortColumn: nil)
    coordinator.relationSchema = "public"
    coordinator.relationTable = "orders"
    coordinator.foreignKeys = [
      ForeignKey(
        constraintName: "orders_name", sourceSchema: "public", sourceTable: "orders",
        sourceColumns: ["name"], targetSchema: "public", targetTable: "names",
        targetColumns: ["name"])
    ]

    let menu = coordinator.contextMenu(row: 2, column: 1)?.items.map(\.title) ?? []
    #expect(menu.contains("Referenced Row..."))
    #expect(coordinator.referencedRowRequest(row: 2, column: 1)?.followsReference == false)
    #expect(coordinator.referencedRowRequest(row: 0, column: 1)?.followsReference == true)
  }

  @Test("Copy follows the on-screen column order after a column is moved")
  func tsvCopyColumnOrder() {
    let (coordinator, tableView) = makeGrid(sortColumn: "id")
    tableView.moveColumn(2, toColumn: 1)
    tableView.selectRowIndexes(IndexSet([0, 2]), byExtendingSelection: false)
    #expect(coordinator.selectionTSV(tableView) == "a\t1\nc\t3")
  }

  @Test("The \"#\" column numbers the displayed rows, stays first and is not copied")
  func rowNumberColumn() {
    let (coordinator, tableView) = makeGrid(sortColumn: "id", ascending: false)
    let rowNumber = tableView.tableColumns[0]
    #expect(rowNumber.identifier == ResultGridCoordinator.rowNumberIdentifier)
    #expect(rowNumber.sortDescriptorPrototype == nil)
    let numbers = (0..<3).map {
      (coordinator.tableView(tableView, viewFor: rowNumber, row: $0) as? NSTableCellView)?
        .textField?.stringValue
    }
    #expect(numbers == ["1", "2", "3"])
    #expect(!coordinator.tableView(tableView, shouldReorderColumn: 0, toColumn: 1))
    #expect(!coordinator.tableView(tableView, shouldReorderColumn: 2, toColumn: 0))
    #expect(coordinator.tableView(tableView, shouldReorderColumn: 2, toColumn: 1))
    tableView.selectRowIndexes(IndexSet([0]), byExtendingSelection: false)
    #expect(coordinator.selectionTSV(tableView) == "3\tc")
  }

  private func fitWidth(
    _ values: [CellValue], headerWidth: CGFloat = 0, minWidth: CGFloat = 40
  ) -> CGFloat {
    let result = CellResult(
      columns: [ColumnInfo(name: "c", type: "text")], rows: values.map { [$0] },
      rowCount: values.count)
    return ResultGridCoordinator.fitWidth(
      column: 0, model: ResultGridModel(result: result, sortColumn: nil, ascending: true),
      headerWidth: headerWidth, minWidth: minWidth)
  }

  @Test("A staged cell commit calls the stage callback and not the immediate update")
  func stagedCommitUsesStageCallback() {
    let (coordinator, _) = makeGrid(sortColumn: "id")
    coordinator.isEditable = true
    coordinator.stagesEdits = true
    var immediate: [String] = []
    var staged: [(Int, Int, String)] = []
    coordinator.onCommitEdit = { _, _, value in immediate.append(value) }
    coordinator.onStageEdit = { staged.append(($0, $1, $2)) }

    // Displayed row 0 is id 1 (result.rows[1]); unchanged text sends nothing
    coordinator.commitEdit(row: 0, column: 1, newValue: "a")
    coordinator.commitEdit(row: 0, column: 1, newValue: "new")

    #expect(immediate.isEmpty)
    #expect(staged.count == 1)
    #expect(staged.first?.0 == 1)
    #expect(staged.first?.1 == 1)
    #expect(staged.first?.2 == "new")
  }

  @Test("Without staging, a cell commit still calls the immediate update")
  func unstagedCommitUsesImmediateUpdate() {
    let (coordinator, _) = makeGrid(sortColumn: "id")
    coordinator.isEditable = true
    var immediate: [([CellValue], Int, String)] = []
    var staged = 0
    coordinator.onCommitEdit = { immediate.append(($0, $1, $2)) }
    coordinator.onStageEdit = { _, _, _ in staged += 1 }

    coordinator.commitEdit(row: 0, column: 1, newValue: "new")

    #expect(staged == 0)
    #expect(immediate.count == 1)
    #expect(immediate.first?.0 == [.int(1), .string("a")])
    #expect(immediate.first?.1 == 1)
    #expect(immediate.first?.2 == "new")
  }

  @Test("Delete and Backspace stage a delete of the selected rows when staging is on")
  func deleteKeyStagesSelectedRows() throws {
    let coordinator = ResultGridCoordinator()
    let tableView = ResultGridView.makeTableView(coordinator: coordinator)
    coordinator.update(tableView, result: result, sortColumn: nil, ascending: true)
    tableView.selectRowIndexes(IndexSet([0, 2]), byExtendingSelection: false)
    var deleted: [[Int]] = []
    coordinator.onStageDelete = { deleted.append($0) }

    coordinator.stagesEdits = false
    tableView.keyDown(with: try deleteKey(code: 51, characters: "\u{7F}"))
    #expect(deleted.isEmpty)

    coordinator.stagesEdits = true
    tableView.keyDown(with: try deleteKey(code: 51, characters: "\u{7F}"))
    tableView.keyDown(with: try deleteKey(code: 117, characters: "\u{F728}"))
    #expect(deleted == [[0, 2], [0, 2]])
  }

  @Test("A MongoDB grid offers no SQL copies (INSERT, IN list)")
  func mongoGridHasNoSQLCopies() {
    let (coordinator, _) = makeGrid(sortColumn: nil)
    coordinator.lookupDialect = .mongodb
    let titles = coordinator.contextMenu(row: 0, column: 0)?.items.map(\.title) ?? []
    #expect(titles.contains("Copy Value"))
    #expect(!titles.contains("Copy as INSERT"))
    #expect(!titles.contains("Copy as IN list"))
  }

  @Test("Staging adds row actions that call the stage callbacks; a notebook grid does not")
  func stagingContextMenuCallsStageCallbacks() {
    let (coordinator, tableView) = makeGrid(sortColumn: nil)
    var inserted = 0
    var duplicated: [[Int]] = []
    var deleted: [[Int]] = []
    var reverted: [[Int]] = []
    coordinator.onStageInsert = { inserted += 1 }
    coordinator.onStageDuplicate = { duplicated.append($0) }
    coordinator.onStageDelete = { deleted.append($0) }
    coordinator.onRevertStaged = { reverted.append($0) }

    let plain = coordinator.contextMenu(row: 0, column: 0)?.items.map(\.title) ?? []
    #expect(plain.contains("Copy Value"))
    #expect(!plain.contains("Add Row"))
    #expect(!plain.contains("Duplicate Row(s)"))
    #expect(!plain.contains("Delete Row(s)"))
    #expect(!plain.contains("Revert Selected"))

    coordinator.stagesEdits = true
    tableView.selectRowIndexes(IndexSet([0, 2]), byExtendingSelection: false)
    let menu = coordinator.contextMenu(row: 0, column: 0)
    let titles = menu?.items.map(\.title) ?? []
    #expect(titles.contains("Copy Value"))
    #expect(titles.contains("Copy as INSERT"))
    #expect(titles.contains("Add Row"))
    #expect(titles.contains("Duplicate Row(s)"))
    #expect(titles.contains("Delete Row(s)"))
    #expect(titles.contains("Revert Selected"))

    invoke(menu?.items.first { $0.title == "Add Row" })
    invoke(menu?.items.first { $0.title == "Duplicate Row(s)" })
    invoke(menu?.items.first { $0.title == "Delete Row(s)" })
    invoke(menu?.items.first { $0.title == "Revert Selected" })
    #expect(inserted == 1)
    #expect(duplicated == [[0, 2]])
    #expect(deleted == [[0, 2]])
    #expect(reverted == [[0, 2]])
  }

  @Test("\"Show Row Details\" follows \"See More\" only when the row callback is set")
  func cellMenuShowRowDetails() {
    let (coordinator, _) = makeGrid(sortColumn: nil)
    let plain = coordinator.contextMenu(row: 0, column: 0)?.items.map(\.title) ?? []
    #expect(!plain.contains("Show Row Details"))

    coordinator.onShowRowDetails = { _, _ in }
    let titles = coordinator.contextMenu(row: 0, column: 0)?.items.map(\.title) ?? []
    let seeMore = titles.firstIndex(of: "See More")
    #expect(seeMore != nil)
    #expect(titles.firstIndex(of: "Show Row Details") == seeMore.map { $0 + 1 })
  }

  @Test("The \"#\" gutter menu needs the row callback and a displayed row")
  func gutterMenuWithoutStaging() {
    let (coordinator, _) = makeGrid(sortColumn: nil)
    #expect(coordinator.gutterContextMenu(row: 0) == nil)

    coordinator.onShowRowDetails = { _, _ in }
    #expect(coordinator.gutterContextMenu(row: 0)?.items.map(\.title) == ["Show Row Details"])
    #expect(coordinator.gutterContextMenu(row: 3) == nil)
    #expect(coordinator.gutterContextMenu(row: -1) == nil)
  }

  @Test("With staging, the gutter menu adds the row-level staging actions")
  func gutterMenuWithStaging() {
    let (coordinator, tableView) = makeGrid(sortColumn: nil)
    var duplicated: [[Int]] = []
    var deleted: [[Int]] = []
    var reverted: [[Int]] = []
    coordinator.onShowRowDetails = { _, _ in }
    coordinator.onStageDuplicate = { duplicated.append($0) }
    coordinator.onStageDelete = { deleted.append($0) }
    coordinator.onRevertStaged = { reverted.append($0) }
    coordinator.stagesEdits = true
    tableView.selectRowIndexes(IndexSet([0, 2]), byExtendingSelection: false)

    let menu = coordinator.gutterContextMenu(row: 0)
    let titles = menu?.items.filter { !$0.isSeparatorItem }.map(\.title) ?? []
    #expect(titles == ["Show Row Details", "Duplicate Row(s)", "Delete Row(s)", "Revert Selected"])

    invoke(menu?.items.first { $0.title == "Duplicate Row(s)" })
    invoke(menu?.items.first { $0.title == "Delete Row(s)" })
    invoke(menu?.items.first { $0.title == "Revert Selected" })
    #expect(duplicated == [[0, 2]])
    #expect(deleted == [[0, 2]])
    #expect(reverted == [[0, 2]])
  }

  @Test("\"Show Row Details\" sends the displayed row and its original index under a sort")
  func showRowDetailsUnderSort() {
    let (coordinator, _) = makeGrid(sortColumn: "id")
    var shown: [([CellValue], Int)] = []
    coordinator.onShowRowDetails = { shown.append(($0, $1)) }

    // Displayed row 0 is id 1 (result.rows[1]), displayed row 2 is id 3 (result.rows[0])
    invoke(coordinator.gutterContextMenu(row: 0)?.items.first { $0.title == "Show Row Details" })
    invoke(
      coordinator.contextMenu(row: 2, column: 1)?.items.first { $0.title == "Show Row Details" })

    #expect(shown.count == 2)
    #expect(shown.first?.0 == [.int(1), .string("a")])
    #expect(shown.first?.1 == 1)
    #expect(shown.last?.0 == [.int(3), .string("c")])
    #expect(shown.last?.1 == 0)
  }

  @Test("Update applies a change set so the staged row tint and value show")
  func updateAppliesChangeSet() throws {
    let (coordinator, tableView) = makeGrid(sortColumn: nil)
    var set = RowChangeSet(
      target: EditTarget(
        qualifiedName: "public.t", tableID: .postgresql(oid: 1), primaryKeyColumns: ["id"]))
    set.stageDelete(row: RowChangeSet.RowKey(values: [.int(3)]))
    try set.stageEdit(
      row: RowChangeSet.RowKey(values: [.int(1)]), column: "name", value: .string("z"),
      original: .string("a"))

    #expect(
      coordinator.update(
        tableView, result: result, sortColumn: nil, ascending: true, changeSet: set))

    let deleted = coordinator.tableView(tableView, rowViewForRow: 0) as? ResultGridRowView
    let edited = coordinator.tableView(tableView, rowViewForRow: 1) as? ResultGridRowView
    #expect(deleted?.stagingState == .deleted)
    #expect(edited?.stagingState == .edited)
    #expect(edited?.editedColumns == IndexSet(integer: 1))
    #expect(cell((coordinator, tableView), row: 1, column: 1)?.stringValue == "z")
    #expect(cell((coordinator, tableView), row: 0, column: 0)?.stringValue == "3")
  }

  // MARK: - Selection summary

  /// The summary the coordinator reports after `change`, without the debounce delay
  private func reportedSummary(
    _ coordinator: ResultGridCoordinator, after change: () -> Void
  ) async -> ResultSelectionSummary? {
    coordinator.selectionSummaryDebounce = .zero
    return await withCheckedContinuation { continuation in
      coordinator.onSelectionSummaryChange = { summary in
        coordinator.onSelectionSummaryChange = nil
        continuation.resume(returning: summary)
      }
      change()
    }
  }

  @Test("Two selected rows report count, sum and average of the clicked column, sorted rows")
  func selectionSummaryOfClickedColumn() async {
    let (coordinator, tableView) = makeGrid(sortColumn: "id")
    coordinator.clickedColumn = 0
    let summary = await reportedSummary(coordinator) {
      tableView.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
    }
    #expect(summary?.columnName == "id")
    #expect(summary?.count == 2)
    #expect(summary?.sum == 3)
    #expect(summary?.average == Decimal(string: "1.5"))
    #expect(summary?.minimum == 1)
    #expect(summary?.maximum == 2)
  }

  @Test("One selected row reports no summary")
  func selectionSummaryNeedsTwoRows() async {
    let (coordinator, tableView) = makeGrid(sortColumn: nil)
    coordinator.clickedColumn = 0
    let summary = await reportedSummary(coordinator) {
      tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
    }
    #expect(summary == nil)
  }

  @Test("Without a clicked column the summary is the row count only")
  func selectionSummaryWithoutColumn() async {
    let (coordinator, tableView) = makeGrid(sortColumn: nil)
    let summary = await reportedSummary(coordinator) {
      tableView.selectRowIndexes(IndexSet([0, 1, 2]), byExtendingSelection: false)
    }
    #expect(summary == ResultSelectionSummary(rowCount: 3))
  }

  @Test("A click maps the table column to the result column; the \"#\" gutter is no column")
  func clickedColumnMapping() async {
    let (coordinator, tableView) = makeGrid(sortColumn: nil)
    tableView.selectRowIndexes(IndexSet([0, 2]), byExtendingSelection: false)
    let name = await reportedSummary(coordinator) {
      coordinator.noteClickedColumn(tableColumn: 2, in: tableView)
    }
    #expect(coordinator.clickedColumn == 1)
    #expect(name?.columnName == "name")
    #expect(name?.sum == nil)
    let gutter = await reportedSummary(coordinator) {
      coordinator.noteClickedColumn(tableColumn: 0, in: tableView)
    }
    #expect(coordinator.clickedColumn == nil)
    #expect(gutter == ResultSelectionSummary(rowCount: 2))
  }

  @Test("Document (JSON) cells count as non-numeric")
  func jsonCellsAreNotNumeric() async {
    let documents = CellResult(
      columns: [ColumnInfo(name: "doc", type: "numeric")],
      rows: [[.json("{\"a\":1}")], [.json("2")]], rowCount: 2)
    let coordinator = ResultGridCoordinator()
    let tableView = NSTableView()
    coordinator.update(tableView, result: documents, sortColumn: nil, ascending: true)
    coordinator.clickedColumn = 0
    let summary = await reportedSummary(coordinator) {
      tableView.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
    }
    #expect(summary?.count == 2)
    #expect(summary?.nonNullCount == 2)
    #expect(summary?.numericCount == 0)
    #expect(summary?.sum == nil)
  }

  @Test("New columns forget the clicked column; the grid going away clears the summary")
  func selectionSummaryResets() async {
    let (coordinator, tableView) = makeGrid(sortColumn: nil)
    coordinator.clickedColumn = 1
    let other = CellResult(
      columns: [ColumnInfo(name: "total", type: "int4")], rows: [[.int(1)], [.int(2)]],
      rowCount: 2)
    coordinator.update(tableView, result: other, sortColumn: nil, ascending: true)
    #expect(coordinator.clickedColumn == nil)
    let summary = await reportedSummary(coordinator) {
      coordinator.selectionSummaryGridDidDisappear()
    }
    #expect(summary == nil)
  }

  private func deleteKey(code: UInt16, characters: String) throws -> NSEvent {
    guard
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: code)
    else {
      Issue.record("Could not make a key event")
      throw TestError.deleteKey
    }
    return event
  }

  private func invoke(_ item: NSMenuItem?) {
    guard let item, let action = item.action else {
      Issue.record("missing menu item")
      return
    }
    _ = item.target?.perform(action, with: item)
  }

  private enum TestError: Error { case deleteKey }
}
