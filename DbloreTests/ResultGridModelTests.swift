// ResultGridModelTests.swift
// The grid model only knows displayed (sorted) rows: every table row index maps to the
// displayed row, never to `result.rows` re-indexed by the display position.

import AppKit
import Foundation
import Testing

@testable import Dblore

@Suite("Result grid model")
@MainActor
struct ResultGridModelTests {
  private let columns = [
    ColumnInfo(name: "id", type: "int4"), ColumnInfo(name: "name", type: "text"),
  ]
  private let rows: [[CellValue]] = [
    [.int(3), .string("c")], [.int(1), .string("a")], [.int(2), .null],
  ]

  private var result: CellResult { CellResult(columns: columns, rows: rows, rowCount: 3) }

  @Test("Ascending and descending sort map table rows and columns to the sorted values")
  func sortMapping() {
    let ascending = ResultGridModel(result: result, sortColumn: "id", ascending: true)
    #expect(ascending.rowCount == 3)
    #expect((0..<3).map { ascending.value(row: $0, column: 0) } == [.int(1), .int(2), .int(3)])
    #expect(ascending.value(row: 0, column: 1) == .string("a"))

    let descending = ResultGridModel(result: result, sortColumn: "id", ascending: false)
    #expect((0..<3).map { descending.value(row: $0, column: 0) } == [.int(3), .int(2), .int(1)])

    let unsorted = ResultGridModel(result: result, sortColumn: nil, ascending: true)
    #expect((0..<3).map { unsorted.row(at: $0) } == rows)
  }

  @Test("Displayed-row lookup returns the sorted row, not result.rows at that index")
  func displayedRowLookup() {
    let model = ResultGridModel(result: result, sortColumn: "id", ascending: true)
    #expect(model.row(at: 0) == [.int(1), .string("a")])
    #expect(model.row(at: 0) != result.rows[0])
  }

  @Test("Display text is on one line and capped at maxDisplayLength characters")
  func flatCappedDisplayText() {
    let max = ResultGridModel.maxDisplayLength
    let exact = String(repeating: "x", count: max)
    let values: [CellValue] = [
      .string("a\nb"), .string("a\r\nb"), .string(exact), .string(exact + "y"),
    ]
    let model = ResultGridModel(
      result: CellResult(
        columns: [ColumnInfo(name: "t", type: "text")], rows: values.map { [$0] },
        rowCount: values.count),
      sortColumn: nil, ascending: true)
    #expect(
      (0..<4).map { model.displayText(row: $0, column: 0) } == [
        "a b", "a b", exact, exact + "…",
      ])
    // Edit and copy keep the full value
    #expect(model.value(row: 1, column: 0).fullString == "a\r\nb")
  }

  @Test("Invisible characters show as marks; the value, TSV and an ASCII cell stay raw")
  func invisibleCharacterMarks() {
    let values: [CellValue] = [
      .string("a\u{200B}b\u{00A0}c"), .string("\u{01}\tx\u{7F}"), .string("plain text"),
    ]
    let result = CellResult(
      columns: [ColumnInfo(name: "t", type: "text")], rows: values.map { [$0] }, rowCount: 3)
    let marked = ResultGridModel(result: result, sortColumn: nil, ascending: true)
    #expect(
      (0..<3).map { marked.displayText(row: $0, column: 0) } == [
        "a\u{2422}b\u{2423}c", "\u{2401}\u{2409}x\u{2421}", "plain text",
      ])
    #expect(
      marked.invisibleCharacterTooltip(row: 1, column: 0)
        == "U+0001 START OF HEADING\nU+0009 HORIZONTAL TABULATION\nU+007F DELETE")
    #expect(marked.invisibleCharacterTooltip(row: 2, column: 0) == nil)
    // Copy and edit read the raw value
    #expect(marked.value(row: 0, column: 0).fullString == "a\u{200B}b\u{00A0}c")
    #expect(
      marked.tsv(rows: IndexSet([0, 1]), columns: [0], neutralizesFormulas: false)
        == "a\u{200B}b\u{00A0}c\n\"\u{01}\tx\u{7F}\"")

    let unmarked = ResultGridModel(
      result: result, sortColumn: nil, ascending: true, marksInvisibleCharacters: false)
    #expect(unmarked.displayText(row: 0, column: 0) == "a\u{200B}b\u{00A0}c")
    #expect(unmarked.invisibleCharacterTooltip(row: 0, column: 0) == nil)
  }

  @Test("A joiner inside an emoji sequence or a word stays; one at an edge or by ASCII is marked")
  func invisibleJoinerContext() {
    let kept = [
      "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}",  // family
      "\u{2764}\u{FE0F}\u{200D}\u{1F525}",  // heart on fire (variation selector)
      "\u{1F469}\u{1F3FD}\u{200D}\u{1F4BB}",  // skin tone modifier
      "\u{0645}\u{06CC}\u{200C}\u{062E}\u{0648}\u{0627}\u{0647}\u{0645}",  // Persian
      "\u{0915}\u{094D}\u{200D}\u{0937}",  // Devanagari conjunct (virama)
      "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}",  // England flag
      "\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}",  // Scotland flag
    ]
    for text in kept {
      #expect(InvisibleCharacters.marked(text) == text)
      #expect(InvisibleCharacters.tooltip(for: text) == nil)
    }
    #expect(InvisibleCharacters.marked("a\u{200D}") == "a\u{2422}")
    #expect(InvisibleCharacters.marked("\u{200C}\u{0645}") == "\u{2422}\u{0645}")
    #expect(InvisibleCharacters.marked("a\u{200D}b") == "a\u{2422}b")
    #expect(InvisibleCharacters.marked("a\u{E0041}") == "a\u{2422}")
    // Only a well-formed subdivision flag keeps its tags: no hidden tag text after a flag
    #expect(InvisibleCharacters.marked("\u{1F3F4} a\u{E0041}") == "\u{1F3F4} a\u{2422}")
    let longRun = "\u{1F3F4}" + String(repeating: "\u{E0061}", count: 20) + "\u{E007F}"
    #expect(
      InvisibleCharacters.marked(longRun)
        == "\u{1F3F4}" + String(repeating: "\u{2422}", count: 21))
    let pirate = "\u{1F3F4}\u{200D}\u{2620}\u{FE0F}"
    #expect(InvisibleCharacters.marked(pirate + "\u{E0041}") == pirate + "\u{2422}")
    #expect(InvisibleCharacters.tooltip(for: "a\u{200D}") == "U+200D ZERO WIDTH JOINER")
  }

  @Test("Direction controls and a soft hyphen are marked and named")
  func invisibleBidiControls() {
    let bidi: [UInt32] = Array(0x202A...0x202E) + Array(0x2066...0x2069) + [0x200E, 0x200F, 0x061C]
    for value in bidi {
      let control = String(Unicode.Scalar(value)!)
      #expect(InvisibleCharacters.marked("a\(control)b") == "a\u{21C4}b", "U+\(value)")
    }
    #expect(InvisibleCharacters.marked("a\u{00AD}b") == "a\u{2422}b")
    #expect(
      InvisibleCharacters.tooltip(for: "x\u{202E}y\u{2066}")
        == "U+202E RIGHT-TO-LEFT OVERRIDE\nU+2066 LEFT-TO-RIGHT ISOLATE")
  }

  @Test("Marks are tinted at their UTF-16 location, except inside a search match")
  func invisibleMarkTintRange() {
    let marked = ResultGridCoordinator.invisibleMarked(
      "\u{1F600}\u{2422}x", textColor: .red, markColor: .blue)
    func color(_ string: NSAttributedString, _ location: Int) -> NSColor? {
      string.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
    }
    #expect(color(marked, 0) == .red)
    #expect(color(marked, 2) == .blue)
    #expect(color(marked, 3) == .red)

    let matched = NSMutableAttributedString(
      string: "\u{2422}\u{2422}", attributes: [.foregroundColor: NSColor.red])
    matched.addAttributes(
      [.backgroundColor: NSColor.yellow, .foregroundColor: NSColor.black],
      range: NSRange(location: 0, length: 1))
    ResultGridCoordinator.tintInvisibleMarks(in: matched, color: .blue)
    #expect(color(matched, 0) == .black)
    #expect(color(matched, 1) == .blue)
  }

  @Test("TSV columns follow the given order")
  func tsvColumnOrder() {
    let model = ResultGridModel(result: result, sortColumn: "id", ascending: true)
    #expect(
      model.tsv(rows: IndexSet([0, 1]), columns: [1, 0], neutralizesFormulas: false)
        == "a\t1\nNULL\t2")
  }

  @Test("Cmd+C TSV prefixes formula-like text when on, never numbers or dates")
  func tsvNeutralizesFormulaText() {
    let date = Date(timeIntervalSince1970: 0)
    let model = ResultGridModel(
      result: CellResult(
        columns: [
          ColumnInfo(name: "t", type: "text"), ColumnInfo(name: "n", type: "int4"),
          ColumnInfo(name: "d", type: "date"),
        ],
        rows: [[.string("=1+1"), .int(-5), .date(date)]], rowCount: 1),
      sortColumn: nil, ascending: true)
    let iso = CellValue.date(date).fullString
    #expect(
      model.tsv(rows: IndexSet([0]), columns: [0, 1, 2], neutralizesFormulas: true)
        == "'=1+1\t-5\t\(iso)")
    #expect(
      model.tsv(rows: IndexSet([0]), columns: [0, 1, 2], neutralizesFormulas: false)
        == "=1+1\t-5\t\(iso)")
  }

  @Test("A displayed row maps back to its index in result.rows")
  func originalRowLookup() {
    let model = ResultGridModel(result: result, sortColumn: "id", ascending: false)
    #expect((0..<3).map { model.originalRow(forDisplayedRow: $0) } == [0, 2, 1])
    #expect(model.originalRow(forDisplayedRow: 3) == nil)
    #expect(model.originalRow(forDisplayedRow: -1) == nil)
  }

  @Test("TSV of a 2x2 selection quotes values containing a tab or a newline")
  func tsvSelection() {
    let result = CellResult(
      columns: columns,
      rows: [
        [.int(2), .string("line1\nline2")], [.int(1), .string("a\tb")], [.int(3), .string("x")],
      ],
      rowCount: 3)
    let model = ResultGridModel(result: result, sortColumn: "id", ascending: true)
    let tsv = model.tsv(rows: IndexSet([0, 1]), columns: [0, 1], neutralizesFormulas: false)
    #expect(tsv == "1\t\"a\tb\"\n2\t\"line1\nline2\"")
  }

  @Test(
    "An original row index maps to its displayed row, by index even for duplicate rows",
    arguments: [true, false])
  func originalToDisplayedRow(ascending: Bool) {
    let result = CellResult(
      columns: columns,
      rows: [
        [.int(2), .string("x")], [.int(1), .string("y")], [.int(2), .string("x")],
        [.int(1), .null],
      ],
      rowCount: 4)
    let model = ResultGridModel(result: result, sortColumn: "id", ascending: ascending)
    let displayed = result.rows.indices.compactMap { model.displayedRow(forOriginalRow: $0) }
    #expect(displayed.count == 4)
    #expect(Set(displayed).count == 4)  // duplicates map to distinct displayed rows
    for (original, row) in zip(result.rows.indices, displayed) {
      #expect(model.row(at: row) == result.rows[original])
    }
    #expect(model.displayedRow(forOriginalRow: 4) == nil)
    #expect(model.displayedRow(forOriginalRow: -1) == nil)

    let unsorted = ResultGridModel(result: result, sortColumn: nil, ascending: true)
    #expect(result.rows.indices.map { unsorted.displayedRow(forOriginalRow: $0) } == [0, 1, 2, 3])
  }

  // MARK: - Display text cache

  /// The uncached algorithm: display string, first 1000 characters, line breaks as spaces
  private func referenceText(_ value: CellValue) -> String {
    let text = value.displayString
    let prefix = text.prefix(1000)
    let flat = prefix.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
      .joined(separator: " ")
    return prefix.endIndex < text.endIndex ? flat + "…" : flat
  }

  @Test("A model rebuilt after an inline edit shows the new value, the old model keeps the old")
  func rebuiltModelShowsEdit() {
    let before = ResultGridModel(result: result, sortColumn: nil, ascending: true)
    #expect(before.displayText(row: 0, column: 1) == "c")  // fills the cache

    var editedRows = rows
    editedRows[0][1] = .string("edited")
    let edited = CellResult(columns: columns, rows: editedRows, rowCount: 3)
    let after = ResultGridModel(result: edited, sortColumn: nil, ascending: true)

    #expect(after.displayText(row: 0, column: 1) == "edited")
    #expect(before.displayText(row: 0, column: 1) == "c")
  }

  @Test("A sorted model caches by displayed row")
  func sortedModelCachesByDisplayedRow() {
    let model = ResultGridModel(result: result, sortColumn: "id", ascending: false)
    for _ in 1...2 {
      #expect(model.displayText(row: 0, column: 0) == "3")
      #expect(model.displayText(row: 0, column: 1) == "c")
      #expect(model.displayText(row: 2, column: 0) == "1")
      #expect(model.displayText(row: 1, column: 1) == "NULL")
    }
  }

  // MARK: - Binary Display As

  private static func bytes(_ hex: String) -> Data {
    let digits = Array(hex.filter { !$0.isWhitespace })
    return Data(
      stride(from: 0, to: digits.count, by: 2).map {
        UInt8(String(digits[$0...$0 + 1]), radix: 16)!
      })
  }

  /// One `bytea` column "b" and a text column "t" holding `values`
  private func binaryResult(_ values: [Data]) -> CellResult {
    CellResult(
      columns: [ColumnInfo(name: "b", type: "bytea"), ColumnInfo(name: "t", type: "text")],
      rows: values.map { [.data($0), .string("x")] }, rowCount: values.count)
  }

  private static let uuidBytes = bytes("6ccd780c baba 1026 9564 5b8c656024db")

  @Test("Display As shows hex or a UUID; Copy Value stays raw base64")
  func binaryFormatApplied() async {
    let result = binaryResult([Self.uuidBytes, Data([1, 2])])
    let hex = ResultGridModel(
      result: result, sortColumn: nil, ascending: true, binaryFormats: ["b": .hex, "t": .hex])
    #expect(hex.displayText(row: 0, column: 0) == "0x6CCD780CBABA102695645B8C656024DB")
    #expect(hex.displayText(row: 1, column: 0) == "0x0102")
    // A format on a text column changes nothing
    #expect(hex.displayText(row: 0, column: 1) == "x")
    #expect(hex.value(row: 0, column: 0).fullString == Self.uuidBytes.base64EncodedString())
    #expect(await hex.displayTextForCopy(row: 0, column: 0) == "0x6CCD780CBABA102695645B8C656024DB")

    let uuid = ResultGridModel(
      result: result, sortColumn: nil, ascending: true, binaryFormats: ["b": .uuid])
    #expect(uuid.displayText(row: 0, column: 0) == "6CCD780C-BABA-1026-9564-5B8C656024DB")
    // Not 16 bytes: the raw fallback
    #expect(uuid.displayText(row: 1, column: 0) == "<2 bytes>")
    #expect(uuid.value(row: 1, column: 0).fullString == Data([1, 2]).base64EncodedString())

    let size = ResultGridModel(result: result, sortColumn: nil, ascending: true)
    #expect(size.binaryFormat(column: 0) == .size)
    #expect(size.displayText(row: 0, column: 0) == "<16 bytes>")
    #expect(size.isBinaryColumn(0))
    #expect(!size.isBinaryColumn(1))
  }

  @Test("Hex text is capped at the grid's display length")
  func binaryHexCapped() {
    let model = ResultGridModel(
      result: binaryResult([Data(count: 100_000)]), sortColumn: nil, ascending: true,
      binaryFormats: ["b": .hex])
    let text = model.displayText(row: 0, column: 0)
    #expect(text.count == ResultGridModel.maxDisplayLength + 1)
    #expect(text.hasSuffix("…"))
  }

  @Test("A format change drops the column's cached text")
  func binaryFormatInvalidatesCache() {
    var model = ResultGridModel(
      result: binaryResult([Self.uuidBytes]), sortColumn: nil, ascending: true)
    #expect(model.displayText(row: 0, column: 0) == "<16 bytes>")  // cached
    #expect(model.displayText(row: 0, column: 1) == "x")

    #expect(model.setBinaryFormats(["b": .uuid]) == IndexSet([0]))
    #expect(model.displayText(row: 0, column: 0) == "6CCD780C-BABA-1026-9564-5B8C656024DB")
    #expect(model.setBinaryFormats(["b": .uuid]) == [])
    // Size is the default: setting it is the same as no format
    #expect(model.setBinaryFormats(["b": .size]) == IndexSet([0]))
    #expect(model.displayText(row: 0, column: 0) == "<16 bytes>")
  }

  @Test(
    "A MessagePack cell shows its size until its off-main decode lands", .timeLimit(.minutes(1)))
  func messagePackDecodesOffMain() async {
    // msgpack.org {"compact":true,"schema":0}, then a truncated fixext4
    let valid = Self.bytes("82 a7 636f6d70616374 c3 a6 736368656d61 00")
    let malformed = Self.bytes("d6 ff 00")
    let model = ResultGridModel(
      result: binaryResult([valid, malformed]), sortColumn: nil, ascending: true,
      binaryFormats: ["b": .messagePack])
    let (landed, continuation) = AsyncStream<[Int]>.makeStream()
    model.onBinaryTextReady = { continuation.yield([$0, $1]) }

    // Measuring (no request) and an on-screen request both show the size at once
    #expect(model.displayText(row: 0, column: 0) == "<\(valid.count) bytes>")
    #expect(model.displayText(row: 0, column: 0, requestsDecode: true) == "<\(valid.count) bytes>")
    #expect(model.displayText(row: 1, column: 0, requestsDecode: true) == "<3 bytes>")

    var cells: Set<[Int]> = []
    for await cell in landed {
      cells.insert(cell)
      if cells.count == 2 { break }
    }
    #expect(cells == [[0, 0], [1, 0]])
    #expect(model.displayText(row: 0, column: 0) == #"{"compact": true, "schema": 0}"#)
    // Bytes that do not decode fall back to the size
    #expect(model.displayText(row: 1, column: 0) == "<3 bytes>")
    // Copy Value stays raw
    #expect(model.value(row: 0, column: 0).fullString == valid.base64EncodedString())
  }

  @Test("Copy as Displayed decodes a MessagePack cell whose text has not landed")
  func copyAsDisplayedDecodesPending() async {
    let valid = Self.bytes("92 01 a1 61")
    let model = ResultGridModel(
      result: binaryResult([valid]), sortColumn: nil, ascending: true,
      binaryFormats: ["b": .messagePack])
    #expect(model.displayText(row: 0, column: 0) == "<4 bytes>")
    #expect(await model.displayTextForCopy(row: 0, column: 0) == #"[1, "a"]"#)
  }

  @Test(
    "A decode pending when the column's format changes never stores its stale text",
    .timeLimit(.minutes(1)))
  func staleBinaryDecodeDropped() async {
    // [1, "a"] as MessagePack; not a Protobuf message, so Protobuf falls back to the size
    let value = Self.bytes("92 01 a1 61")
    var model = ResultGridModel(
      result: binaryResult([value]), sortColumn: nil, ascending: true,
      binaryFormats: ["b": .messagePack])
    let (landed, continuation) = AsyncStream<[Int]>.makeStream()
    model.onBinaryTextReady = { continuation.yield([$0, $1]) }

    #expect(model.displayText(row: 0, column: 0, requestsDecode: true) == "<4 bytes>")
    // The MessagePack decode is still pending: the main actor has not yielded yet
    #expect(model.setBinaryFormats(["b": .protobuf]) == IndexSet([0]))
    #expect(model.displayText(row: 0, column: 0, requestsDecode: true) == "<4 bytes>")

    // Whichever decode finishes first, only the Protobuf one is stored and reported
    for await cell in landed {
      #expect(cell == [0, 0])
      break
    }
    #expect(model.displayText(row: 0, column: 0) == "<4 bytes>")
    #expect(model.displayText(row: 0, column: 0) != #"[1, "a"]"#)
  }

  /// An isolated defaults suite, removed when `body` returns
  private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
    let name = "ace.thi.Dblore.tests.gridColumnPrefs.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    try body(defaults)
  }

  private func storedPrefs(_ defaults: UserDefaults) throws -> [String: GridColumnPrefs] {
    guard let data = defaults.data(forKey: GridColumnPrefsStore.storageKey) else { return [:] }
    return try JSONDecoder().decode([String: GridColumnPrefs].self, from: data)
  }

  @Test("A column's Display As is stored per table; an entry with no preference is removed")
  func binaryFormatStored() throws {
    try withDefaults { defaults in
      let key = GridColumnPrefsStore.key(
        for: ConnectionConfig(databaseType: .mysql, host: "h", port: 3306, database: "app"),
        schema: "app", name: "events")
      let store = GridColumnPrefsStore(defaults: defaults)
      store.setBinaryFormat(.uuidSwappedTime, column: "id", for: key)
      store.setBinaryFormat(.messagePack, column: "payload", for: key)
      // A new store (a relaunch) reads it back; a format alone keeps the entry
      let reloaded = GridColumnPrefsStore(defaults: defaults)
      #expect(
        reloaded.binaryFormats(for: key) == ["id": .uuidSwappedTime, "payload": .messagePack])
      #expect(reloaded.frozenThrough(for: key) == nil)
      let stored = try storedPrefs(defaults)
      #expect(stored[key] != nil)

      // Unfreezing a table that only has formats keeps them
      store.setFrozenThrough("id", for: key)
      store.setFrozenThrough(nil, for: key)
      #expect(store.binaryFormats(for: key).count == 2)

      // Size is the default: it removes the column, then the empty entry
      store.setBinaryFormat(.size, column: "id", for: key)
      store.setBinaryFormat(.size, column: "payload", for: key)
      #expect(store.binaryFormats(for: key).isEmpty)
      let cleared = try storedPrefs(defaults)
      #expect(cleared[key] == nil)
    }
  }

  @Test("A malformed stored entry is dropped alone; the next write keeps the other tables")
  func malformedPrefsEntryDroppedAlone() throws {
    try withDefaults { defaults in
      let json = #"{"k1":{"frozenThrough":"id"},"k2":{"binaryFormats":["hex"]}}"#
      defaults.set(Data(json.utf8), forKey: GridColumnPrefsStore.storageKey)
      let store = GridColumnPrefsStore(defaults: defaults)
      #expect(store.frozenThrough(for: "k1") == "id")
      #expect(store.binaryFormats(for: "k2").isEmpty)

      store.setBinaryFormat(.hex, column: "c", for: "k3")
      let stored = try storedPrefs(defaults)
      #expect(stored["k1"] == GridColumnPrefs(frozenThrough: "id"))
      #expect(stored["k2"] == nil)
      #expect(stored["k3"] == GridColumnPrefs(binaryFormats: ["c": .hex]))
    }
  }

  @Test("Stored preferences without formats, or with an unknown one, still load")
  func binaryFormatDecodesOldEntries() throws {
    let json = #"{"k1":{"frozenThrough":"id"},"k2":{"binaryFormats":{"a":"hex","b":"future"}}}"#
    let all = try JSONDecoder().decode([String: GridColumnPrefs].self, from: Data(json.utf8))
    #expect(all["k1"] == GridColumnPrefs(frozenThrough: "id"))
    #expect(all["k2"] == GridColumnPrefs(binaryFormats: ["a": .hex]))
  }
}
