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
}
