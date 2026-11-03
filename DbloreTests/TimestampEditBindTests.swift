// TimestampEditBindTests.swift
// A timestamp edited as its display text binds as the instant the editor showed: an UPDATE sent
// at once carries the same text a staged edit would (UTC plain text on MySQL, ISO 8601 UTC on
// PostgreSQL), whatever the server session's zone, and an unchanged value stages nothing.

import Foundation
import Testing

@testable import Dblore

@Suite("Timestamp edit binding")
@MainActor
struct TimestampEditBindTests {
  private static let eventsID = TableRef.postgresql(oid: 16_500)
  /// 2026-10-15 12:00:00.123456 UTC, 19:00:00.123456 in Ho Chi Minh City
  private static let at = Date(timeIntervalSince1970: Double(1_792_065_600_123_456) / 1_000_000)
  private static let zone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!

  /// Data viewer of events(id PK, at) on `type`, one loaded row whose `at` is `value`, confirm
  /// commit style so an edit waits as `pendingInlineEdit`
  private func makeViewModel(
    _ type: DatabaseType, wallClock: Bool = false, value: CellValue = .date(at),
    columnType: String = "TIMESTAMP"
  ) -> NotebookViewModel {
    let viewModel = NotebookViewModel()
    viewModel.toastPresenter = { _, _ in }
    viewModel.viewMode = .editor
    var config = ConnectionConfig(
      databaseType: type, host: "localhost", port: 5432, database: "app", username: "ana",
      password: "x", protectionLevel: .none, safeMode: .silent, protectedMode: false)
    config.applyCommitStyle(.confirm)
    viewModel.notebook.connectionConfig = config
    viewModel.dataViewer = DataViewerState(
      schema: "app", name: "events", orderColumns: ["id"], databaseType: type)
    viewModel.editorResult = CellResult(
      columns: [
        ColumnInfo(
          name: "id", type: "INTEGER",
          origin: ColumnOrigin(tableID: Self.eventsID, columnOrdinal: 1)),
        ColumnInfo(
          name: "at", type: columnType,
          origin: ColumnOrigin(tableID: Self.eventsID, columnOrdinal: 2), wallClock: wallClock),
      ],
      rows: [[.int(1), value]], rowCount: 1, tableName: "events", primaryKeyColumns: ["id"],
      editTarget: EditTarget(
        qualifiedName: type == .mysql ? "`app`.`events`" : "app.events", tableID: Self.eventsID,
        primaryKeyColumns: ["id"], connectionEpoch: 0))
    viewModel.connectionManager = DatabaseConnectionManager()
    return viewModel
  }

  /// The SET value of the UPDATE a grid edit of `at` arms
  private func sentText(_ viewModel: NotebookViewModel, typing text: String) -> String?? {
    let result = viewModel.editorResult!
    CellValue.$displayZone.withValue(Self.zone) {
      viewModel.handleStagedGridCellEdit(row: 0, column: 1, newValue: text, result: result)
    }
    return viewModel.pendingInlineEdit?.statement.values.first
  }

  @Test(
    "A timestamp edit sent at once binds the instant as a staged edit does",
    arguments: [
      // MySQL: UTC plain text, right under the session's pinned +00:00 zone
      (DatabaseType.mysql, false, "2026-10-15 19:00:00.123456", "2026-10-15 12:00:00.123456"),
      (.mysql, false, "2026-10-15 19:00:00.123456+07:00", "2026-10-15 12:00:00.123456"),
      (.mysql, false, "2026-10-15T12:00:00.123456Z", "2026-10-15 12:00:00.123456"),
      (.mysql, true, "2026-10-15 12:00:00.5", "2026-10-15 12:00:00.500000"),
      // PostgreSQL: ISO 8601 UTC (a timestamp column ignores the Z: its wall clock)
      (.postgresql, false, "2026-10-15 19:00:00.123456+07:00", "2026-10-15T12:00:00.123456Z"),
      (.postgresql, true, "2026-10-15 12:00:00", "2026-10-15T12:00:00.000000Z"),
      // Text that reads as no date is sent as typed, for the server to read or refuse
      (.mysql, false, "now", "now"), (.postgresql, false, "infinity", "infinity"),
    ] as [(DatabaseType, Bool, String, String)])
  func directEditBindsInstant(type: DatabaseType, wallClock: Bool, text: String, bound: String) {
    let viewModel = makeViewModel(type, wallClock: wallClock)
    #expect(sentText(viewModel, typing: text) == .some(bound))
    // The edit keeps the typed text, which the refresh after the send reads back
    #expect(viewModel.pendingInlineEdit?.setInputValues == [text])
  }

  @Test(
    "Zone-less text in a NULL zoned cell reads in the display zone, as a stored value's does",
    arguments: [
      (DatabaseType.mysql, "2026-10-15 12:00:00.000000"),
      (.postgresql, "2026-10-15T12:00:00.000000Z"),
      // SQLite dates are text: kept as typed
      (.sqlite, "2026-10-15 19:00:00"),
    ] as [(DatabaseType, String)])
  func nullZonedCellReadsDisplayZone(type: DatabaseType, bound: String) {
    let viewModel = makeViewModel(type, value: .null)
    #expect(sentText(viewModel, typing: "2026-10-15 19:00:00") == .some(bound))
  }

  @Test(
    "Zone-less text in a new row's zoned cell reads in the display zone; SQLite keeps it",
    arguments: [DatabaseType.mysql, .postgresql, .sqlite])
  func newRowZonedCellReadsDisplayZone(type: DatabaseType) {
    let viewModel = makeViewModel(type)
    let text = "2026-10-15 19:00:00"
    #expect(viewModel.stageInsert(values: ["id": .int(2)]) == nil)
    let result = viewModel.editorResult!
    CellValue.$displayZone.withValue(Self.zone) {
      viewModel.handleStagedGridCellEdit(row: 1, column: 1, newValue: text, result: result)
    }
    let expected: CellValue =
      type == .sqlite ? .string(text) : .date(Date(timeIntervalSince1970: 1_792_065_600))
    #expect(viewModel.dataViewer?.changeSet?.inserts.first?.values["at"] == expected)
  }

  @Test("Row Details sends a timestamp field as the instant it shows")
  func rowDetailApplyBindsInstant() throws {
    let viewModel = makeViewModel(.mysql)
    viewModel.dataViewer = nil
    let result = viewModel.editorResult!
    CellValue.$displayZone.withValue(Self.zone) {
      viewModel.showRowDetail(row: result.rows[0], originalRow: 0, result: result, cellId: nil)
      viewModel.rowDetail?.fields[1].text = "2026-10-15 20:00:00"
      viewModel.applyRowDetail()
    }
    #expect(viewModel.pendingInlineEdit?.statement.values == ["2026-10-15 13:00:00.000000", "1"])
    // The panel rebuilds the very statement sent: the sent value becomes its clean original
    let edit = try #require(viewModel.pendingInlineEdit)
    CellValue.$displayZone.withValue(Self.zone) {
      viewModel.rowDetailSent(edit, target: result.editTarget!)
      #expect(viewModel.rowDetail?.fields[1].isDirty == false)
    }
    #expect(
      viewModel.rowDetail?.fields[1].original == .date(Date(timeIntervalSince1970: 1_792_069_200)))
  }

  /// Regression A5: the Cell Value sidebar reads its text as its column shows it (round 2: it
  /// read every zone-less text as the Mac's local time)
  @Test(
    "A Cell Value sidebar edit reads zone-less text as its column shows it",
    arguments: [
      (DatabaseType.postgresql, true, "2026-10-15 12:00:00", "2026-10-15T12:00:00.000000Z"),
      (.mysql, true, "2026-10-15 12:00:00", "2026-10-15 12:00:00.000000"),
      (.postgresql, false, "2026-10-15 19:00:00", "2026-10-15T12:00:00.000000Z"),
      (.mysql, false, "2026-10-15 19:00:00", "2026-10-15 12:00:00.000000"),
    ] as [(DatabaseType, Bool, String, String)])
  func sidebarEditReadsColumnFlag(
    type: DatabaseType, wallClock: Bool, text: String, bound: String
  ) throws {
    let viewModel = makeViewModel(type, wallClock: wallClock)
    viewModel.dataViewer = nil
    let result = viewModel.editorResult!
    viewModel.showGridCellInSidebar(
      row: result.rows[0], originalRow: 0, column: 1, result: result, cellId: nil)
    #expect(viewModel.cellDetailWallClock == wallClock)
    guard
      case .cellInfo(
        let column, let columnType, let value, let table, let rowData, let keys, let id) =
        viewModel.rightSidebarContent
    else { throw CancellationError() }
    CellValue.$displayZone.withValue(Self.zone) {
      // Its editor starts from the grid's text, which reads back as the stored value
      let prefill = CellInfoContent.editableText(
        value, columnType: columnType, wallClock: viewModel.cellDetailWallClock)
      #expect(prefill.text == value.displayString(wallClock: wallClock))
      #expect(prefill.error == nil)
      // As RightSidebarView saves it
      viewModel.handleCellValueEdit(
        columnName: column, columnType: columnType, newValue: text, originalValue: value,
        tableName: table, rowData: rowData, primaryKeyColumns: keys, cellId: id,
        connectionManager: viewModel.connectionManager, wallClock: viewModel.cellDetailWallClock)
    }
    #expect(viewModel.pendingInlineEdit?.statement.values.first == .some(bound))
  }

  /// Regression A5 (round 5): the grid editor checks date-looking text as the sidebar does. Text
  /// the parser refused was sent as typed and read in the server session's zone, not the display
  /// zone: a wall clock the display zone skips, or an impossible date or time
  @Test(
    "A grid edit of date-looking text that reads as no instant sends nothing",
    arguments: [DatabaseType.postgresql, .mysql],
    ["2026-03-08 02:30:00", "2026-03-08 02:30", "2026-02-30 10:00:00", "2026-10-15 25:00:00"])
  func gridEditRefusesUnreadableDate(type: DatabaseType, text: String) throws {
    let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
    for viewer in [true, false] {
      let viewModel = makeViewModel(type)
      var toasts: [String] = []
      viewModel.toastPresenter = { message, _ in toasts.append(message) }
      if !viewer { viewModel.dataViewer = nil }
      let result = viewModel.editorResult!
      viewModel.showGridCellInSidebar(
        row: result.rows[0], originalRow: 0, column: 0, result: result, cellId: nil)
      let shown = viewModel.rightSidebarContent
      CellValue.$displayZone.withValue(losAngeles) {
        viewModel.handleGridCellEdit(
          row: result.rows[0], column: 1, newValue: text, result: result, cellId: nil,
          connectionManager: viewModel.connectionManager)
      }
      #expect(viewModel.pendingInlineEdit == nil, "\(text) viewer: \(viewer)")
      #expect(toasts.count == 1, "\(text) viewer: \(viewer)")
      #expect(viewModel.rightSidebarContent == shown, "\(text) viewer: \(viewer)")
      #expect(viewModel.cellDetailWallClock == false)
    }
  }

  @Test(
    "A new row's date-looking text that reads as no instant stages nothing",
    arguments: [DatabaseType.postgresql, .mysql],
    ["2026-03-08 02:30:00", "2026-02-30 10:00:00", "2026-10-15 25:00:00"])
  func newRowRefusesUnreadableDate(type: DatabaseType, text: String) throws {
    let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let viewModel = makeViewModel(type)
    var toasts: [String] = []
    viewModel.toastPresenter = { message, _ in toasts.append(message) }
    #expect(viewModel.stageInsert(values: ["id": .int(2)]) == nil)
    let result = viewModel.editorResult!
    CellValue.$displayZone.withValue(losAngeles) {
      viewModel.handleStagedGridCellEdit(row: 1, column: 1, newValue: text, result: result)
    }
    #expect(viewModel.dataViewer?.changeSet?.inserts.first?.values["at"] == nil)
    #expect(toasts.count == 1)
  }

  @Test(
    "A minute-only grid edit binds the instant it shows",
    arguments: [
      (DatabaseType.mysql, false, "2026-10-15 12:00:00.000000"),
      (.mysql, true, "2026-10-15 19:00:00.000000"),
      (.postgresql, false, "2026-10-15T12:00:00.000000Z"),
      (.postgresql, true, "2026-10-15T19:00:00.000000Z"),
    ] as [(DatabaseType, Bool, String)])
  func minuteOnlyGridEditBindsInstant(type: DatabaseType, wallClock: Bool, bound: String) {
    let viewModel = makeViewModel(type, wallClock: wallClock)
    let text = "2026-10-15 19:00"
    #expect(sentText(viewModel, typing: text) == .some(bound))
    #expect(viewModel.pendingInlineEdit?.setInputValues == [text])
  }

  @Test(
    "Keywords and other text that reads as no date are still sent as typed",
    arguments: ["now", "infinity", "-infinity", "today"])
  func keywordsSentAsTyped(text: String) {
    let viewModel = makeViewModel(.postgresql)
    #expect(sentText(viewModel, typing: text) == .some(text))
    let nullCell = makeViewModel(.postgresql, value: .null, columnType: "TIMESTAMPTZ")
    #expect(sentText(nullCell, typing: text) == .some(text))
  }

  @Test("A BC timestamp's text is not refused by the grid check")
  func bcTextNotRefused() {
    #expect(
      NotebookViewModel.gridDateRefusal(
        "0044-03-15 12:00:00+00:00 BC", original: .date(Self.at), columnType: "TIMESTAMPTZ",
        wallClock: false, dialect: .postgresql) == nil)
  }

  /// SQLite dates are text: ISO text with a zone typed in a NULL date cell is sent as typed
  @Test(
    "ISO text with a zone in a NULL SQLite date cell is sent as typed",
    arguments: ["2026-10-15T12:00:00Z", "2026-10-15T19:00:00+07:00"])
  func sqliteNullCellSendsISOTextAsTyped(text: String) {
    let viewModel = makeViewModel(.sqlite, value: .null)
    #expect(sentText(viewModel, typing: text) == .some(text))
  }

  /// Regression A5: the Add Row form reads timestamp text as the other new-row paths do
  @Test(
    "Add Row stages timestamp text as a new row's grid cell does",
    arguments: [
      (DatabaseType.mysql, true, "2026-10-15 12:00:00"),
      (.postgresql, true, "2026-10-15 12:00:00"),
      (.postgresql, false, "2026-10-15 19:00:00"),
      // SQLite dates are text: kept as typed
      (.sqlite, false, "2026-10-15T12:00:00Z"),
    ] as [(DatabaseType, Bool, String)])
  func addRowStagesTimestampAsInstant(type: DatabaseType, wallClock: Bool, text: String) async {
    let viewModel = makeViewModel(type, wallClock: wallClock)
    await viewModel.prepareAddRowFields()
    #expect(viewModel.addRowFields.map(\.wallClock) == [false, wallClock])
    guard viewModel.addRowFields.count == 2 else { return }
    viewModel.addRowFields[0].text = "2"
    viewModel.addRowFields[1].text = text
    CellValue.$displayZone.withValue(Self.zone) { viewModel.applyAddRow() }
    let expected: CellValue =
      type == .sqlite ? .string(text) : .date(Date(timeIntervalSince1970: 1_792_065_600))
    #expect(viewModel.dataViewer?.changeSet?.inserts.first?.values["at"] == expected)
  }

  /// Regression A5: the PostgreSQL driver's Double for a timestamp is not always the parser's
  @Test("Set Value with a PostgreSQL timestamp's own text stages nothing")
  func postgresOwnTextStagesNothing() {
    let since2000 = Date(timeIntervalSince1970: 946_684_800)
    for micros: Int64 in [2, 3, 7] {
      let decoded = Date(
        timeInterval: Double(845_380_800_000_000 + micros) / 1_000_000, since: since2000)
      let viewModel = makeViewModel(.postgresql, value: .date(decoded))
      let text = CellValue.date(decoded).displayString(wallClock: false)
      let reason = CellValue.$displayZone.withValue(Self.zone) {
        viewModel.stageEdits(rows: [0], column: "at", values: [.value(.string(text))])
      }
      #expect(reason == nil)
      #expect(viewModel.dataViewer?.changeSet == nil, "\(text)")
    }
  }

  /// Data viewer of events(id PK, at, at_tz) on PostgreSQL: `at` a naive TIMESTAMP, `at_tz` a
  /// TIMESTAMPTZ, both holding `at`, confirm commit style, no data viewer (grid edits send at once)
  private func makeTwoTimestampViewModel() -> NotebookViewModel {
    let viewModel = makeViewModel(.postgresql, wallClock: true)
    viewModel.dataViewer = nil
    viewModel.editorResult = CellResult(
      columns: [
        ColumnInfo(
          name: "id", type: "INTEGER",
          origin: ColumnOrigin(tableID: Self.eventsID, columnOrdinal: 1)),
        ColumnInfo(
          name: "at", type: "TIMESTAMP",
          origin: ColumnOrigin(tableID: Self.eventsID, columnOrdinal: 2), wallClock: true),
        ColumnInfo(
          name: "at_tz", type: "TIMESTAMPTZ",
          origin: ColumnOrigin(tableID: Self.eventsID, columnOrdinal: 3)),
      ],
      rows: [[.int(1), .date(Self.at), .date(Self.at)]], rowCount: 1, tableName: "events",
      primaryKeyColumns: ["id"],
      editTarget: EditTarget(
        qualifiedName: "app.events", tableID: Self.eventsID, primaryKeyColumns: ["id"],
        connectionEpoch: 0))
    return viewModel
  }

  /// Regression A5 (round 3): a grid edit of another column swaps the Cell Value sidebar to that
  /// column's flag; a cancelled edit put back the shown column's value but kept the other flag
  @Test(
    "A cancelled grid edit of another column puts back the sidebar column's flag",
    arguments: [
      // Sidebar on the naive column, grid edit of the zoned one, then the sidebar Edit
      (1, 2, "2026-10-15 12:00:00", "2026-10-15T12:00:00.000000Z"),
      // Sidebar on the zoned column, grid edit of the naive one
      (2, 1, "2026-10-15 19:00:00", "2026-10-15T12:00:00.000000Z"),
    ] as [(Int, Int, String, String)])
  func cancelledGridEditRestoresSidebarFlag(
    shown: Int, edited: Int, text: String, bound: String
  ) throws {
    let viewModel = makeTwoTimestampViewModel()
    let result = viewModel.editorResult!
    viewModel.showGridCellInSidebar(
      row: result.rows[0], originalRow: 0, column: shown, result: result, cellId: nil)
    let shownContent = viewModel.rightSidebarContent
    let shownFlag = result.columns[shown].wallClock
    #expect(viewModel.cellDetailWallClock == shownFlag)
    CellValue.$displayZone.withValue(Self.zone) {
      viewModel.handleGridCellEdit(
        row: result.rows[0], column: edited, newValue: "2026-10-15 21:00:00+07:00",
        result: result, cellId: nil, connectionManager: viewModel.connectionManager)
    }
    #expect(viewModel.pendingInlineEdit != nil)
    #expect(viewModel.cellDetailWallClock == result.columns[edited].wallClock)
    viewModel.cancelPendingQuery()
    #expect(viewModel.rightSidebarContent == shownContent)
    #expect(viewModel.cellDetailWallClock == shownFlag)
    guard
      case .cellInfo(
        let column, let columnType, let value, let table, let rowData, let keys, let id) =
        viewModel.rightSidebarContent
    else { throw CancellationError() }
    CellValue.$displayZone.withValue(Self.zone) {
      viewModel.handleCellValueEdit(
        columnName: column, columnType: columnType, newValue: text, originalValue: value,
        tableName: table, rowData: rowData, primaryKeyColumns: keys, cellId: id,
        connectionManager: viewModel.connectionManager, wallClock: viewModel.cellDetailWallClock)
    }
    #expect(viewModel.pendingInlineEdit?.statement.values.first == .some(bound))
  }

  /// Display zones east and west of UTC
  private static let dateZones = [zone, TimeZone(secondsFromGMT: -7 * 3_600)!]

  /// Regression A5 (round 3): DATE text in a cell with no stored value is sent as typed, never
  /// read as a display-zone instant (which stored the previous or next day)
  @Test(
    "DATE text in a NULL cell is sent as typed",
    arguments: [DatabaseType.postgresql, .mysql], ["2026-10-15 00:00:00", "2026-10-15"])
  func nullDateCellSendsTextAsTyped(type: DatabaseType, text: String) {
    for zone in Self.dateZones {
      let viewModel = makeViewModel(type, value: .null, columnType: "DATE")
      let result = viewModel.editorResult!
      CellValue.$displayZone.withValue(zone) {
        viewModel.handleStagedGridCellEdit(row: 0, column: 1, newValue: text, result: result)
      }
      #expect(viewModel.pendingInlineEdit?.statement.values.first == .some(text), "\(zone)")
    }
  }

  @Test(
    "DATE text in a new row's cell stages as typed",
    arguments: [DatabaseType.postgresql, .mysql], ["2026-10-15 00:00:00", "2026-10-15"])
  func newRowDateCellStagesTextAsTyped(type: DatabaseType, text: String) {
    for zone in Self.dateZones {
      let viewModel = makeViewModel(type, columnType: "DATE")
      #expect(viewModel.stageInsert(values: ["id": .int(2)]) == nil)
      let result = viewModel.editorResult!
      CellValue.$displayZone.withValue(zone) {
        viewModel.handleStagedGridCellEdit(row: 1, column: 1, newValue: text, result: result)
      }
      #expect(
        viewModel.dataViewer?.changeSet?.inserts.first?.values["at"] == .string(text), "\(zone)")
    }
  }

  @Test(
    "DATE text set on a NULL cell stages as typed",
    arguments: [DatabaseType.postgresql, .mysql], ["2026-10-15 00:00:00", "2026-10-15"])
  func setValueOnNullDateStagesTextAsTyped(type: DatabaseType, text: String) {
    for zone in Self.dateZones {
      let viewModel = makeViewModel(type, value: .null, columnType: "DATE")
      let reason = CellValue.$displayZone.withValue(zone) {
        viewModel.stageEdits(rows: [0], column: "at", values: [.value(.string(text))])
      }
      #expect(reason == nil)
      let key = RowChangeSet.RowKey(values: [.int(1)])
      #expect(viewModel.dataViewer?.changeSet?.edits[key]?["at"] == .string(text), "\(zone)")
    }
  }

  /// The form takes `yyyy-MM-dd` only for a DATE field (`NewRowField.validationError`)
  @Test(
    "Row Details sends DATE text of a NULL field as typed",
    arguments: [DatabaseType.postgresql, .mysql])
  func rowDetailNullDateSendsTextAsTyped(type: DatabaseType) {
    let text = "2026-10-15"
    for zone in Self.dateZones {
      let viewModel = makeViewModel(type, value: .null, columnType: "DATE")
      viewModel.dataViewer = nil
      let result = viewModel.editorResult!
      CellValue.$displayZone.withValue(zone) {
        viewModel.showRowDetail(row: result.rows[0], originalRow: 0, result: result, cellId: nil)
        viewModel.rowDetail?.fields[1].isNull = false
        viewModel.rowDetail?.fields[1].text = text
        viewModel.applyRowDetail()
      }
      #expect(viewModel.pendingInlineEdit?.statement.values == [text, "1"], "\(zone)")
    }
  }

  @Test(
    "Pasted and Shortcuts DATE text stays as typed",
    arguments: [DatabaseType.postgresql, .mysql, .duckdb], ["2026-10-15 00:00:00", "2026-10-15"])
  func pastedAndShortcutsDateStayAsTyped(type: DatabaseType, text: String) throws {
    let structure = TableStructure(
      tableID: .postgresql(oid: 1), schema: "s", name: "t",
      columns: [
        TableStructure.Column(ordinal: 1, name: "d", dataType: "date", isNullable: true)
      ], indexes: [], constraints: [])
    for zone in Self.dateZones {
      try CellValue.$displayZone.withValue(zone) {
        let pasted = try PastedRows.cellValue(
          .init(text: text, quoted: false), columnType: "DATE", dialect: type.dialect)
        #expect(pasted == .string(text), "\(zone)")
        let typed = try ShortcutsRunner.cellValues(["d": text], structure: structure, engine: type)
        #expect(typed["d"] == .string(text), "\(zone)")
      }
    }
  }
}
