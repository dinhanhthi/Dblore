// ResultGridCopyFormatTests.swift
// Cmd+C copies the selected grid cells in the "Copy rows as" format. The default (TSV, no
// header) stays the selection TSV; CSV quotes like the export; Markdown escapes backslashes,
// pipes, &, < and > and line breaks; JSON keeps the column order and escapes as
// JSONSerialization does; the formula neutralizer applies to TSV and CSV text cells and headers.

import Foundation
import Testing

@testable import Dblore

@Suite("Result grid copy formats")
@MainActor
struct ResultGridCopyFormatTests {
  private func model(_ columns: [ColumnInfo], _ rows: [[CellValue]]) -> ResultGridModel {
    ResultGridModel(
      result: CellResult(columns: columns, rows: rows, rowCount: rows.count),
      sortColumn: nil, ascending: true)
  }

  @Test("TSV, the default format, is the selection TSV with no header")
  func defaultTSVUnchanged() {
    let grid = model(
      [ColumnInfo(name: "id", type: "int4"), ColumnInfo(name: "name", type: "text")],
      [[.int(1), .string("a\tb")], [.int(2), .null]])
    let rows = IndexSet([0, 1])
    for neutralizes in [true, false] {
      #expect(
        grid.copyText(rows: rows, columns: [1, 0], format: .tsv, neutralizesFormulas: neutralizes)
          == grid.tsv(rows: rows, columns: [1, 0], neutralizesFormulas: neutralizes))
    }
    #expect(
      grid.copyText(rows: rows, columns: [1, 0], format: .tsv, neutralizesFormulas: false)
        == "\"a\tb\"\t1\nNULL\t2")
  }

  @Test("CSV with headers quotes a comma, a quote and a line break")
  func csvWithHeadersQuoting() {
    let grid = model(
      [ColumnInfo(name: "id", type: "int4"), ColumnInfo(name: "note, text", type: "text")],
      [[.int(1), .string("a,b")], [.int(2), .string("say \"hi\"")], [.int(3), .string("x\ny")]])
    #expect(
      grid.copyText(
        rows: IndexSet([0, 1, 2]), columns: [0, 1], format: .csvWithHeaders,
        neutralizesFormulas: false)
        == "id,\"note, text\"\n1,\"a,b\"\n2,\"say \"\"hi\"\"\"\n3,\"x\ny\"")
  }

  @Test("CSV prefixes formula-like text cells and headers, never numbers")
  func csvNeutralizesFormulas() {
    let grid = model(
      [ColumnInfo(name: "=total", type: "text"), ColumnInfo(name: "n", type: "int4")],
      [[.string("=1+1"), .int(-5)]])
    #expect(
      grid.copyText(
        rows: IndexSet([0]), columns: [0, 1], format: .csvWithHeaders, neutralizesFormulas: true)
        == "'=total,n\n'=1+1,-5")
    #expect(
      grid.copyText(rows: IndexSet([0]), columns: [0, 1], format: .csv, neutralizesFormulas: false)
        == "=1+1,-5")
  }

  @Test("Markdown escapes a pipe, < and > in cells and headers and turns a line break into <br>")
  func markdownEscaping() {
    let grid = model(
      [ColumnInfo(name: "a|<x>", type: "text"), ColumnInfo(name: "b\nc", type: "text")],
      [[.string("x|y"), .string("one\n<b>two</b>\r\nthree")]])
    #expect(
      grid.copyText(
        rows: IndexSet([0]), columns: [0, 1], format: .markdown, neutralizesFormulas: true)
        == "| a\\|&lt;x&gt; | b<br>c |\n| --- | --- |\n"
        + "| x\\|y | one<br>&lt;b&gt;two&lt;/b&gt;<br>three |\n")
    // A backslash before a pipe cannot end the cell; an entity in the data stays text
    let escapes = model(
      [ColumnInfo(name: "v", type: "text")], [[.string("a\\|b")], [.string("&lt;")]])
    #expect(
      escapes.copyText(
        rows: IndexSet([0, 1]), columns: [0], format: .markdown, neutralizesFormulas: false)
        == "| v |\n| --- |\n| a\\\\\\|b |\n| &amp;lt; |\n")
  }

  @Test("JSON keeps the column order and suffixes a repeated column name")
  func jsonColumnOrder() {
    let grid = model(
      [
        ColumnInfo(name: "id", type: "int4"), ColumnInfo(name: "name", type: "text"),
        ColumnInfo(name: "id", type: "int4"),
      ],
      [[.int(1), .string("a"), .int(2)]])
    #expect(
      grid.copyText(
        rows: IndexSet([0]), columns: [1, 0, 2], format: .json, neutralizesFormulas: true)
        == "[\n  {\n    \"name\" : \"a\",\n    \"id\" : 1,\n    \"id_2\" : 2\n  }\n]")
    let compact = DataExporter.toJSON(
      result: CellResult(
        columns: [
          ColumnInfo(name: "z", type: "int4"), ColumnInfo(name: "a", type: "json"),
          ColumnInfo(name: "z", type: "int4"), ColumnInfo(name: "z_2", type: "int4"),
        ],
        rows: [[.int(1), .json("{\"k\":[1]}"), .int(2), .int(3)]], rowCount: 1),
      pretty: false)
    // The repeated "z" skips "z_2", the name of another column
    #expect(compact == "[{\"z\":1,\"a\":{\"k\":[1]},\"z_3\":2,\"z_2\":3}]")
  }

  @Test("JSON escapes keys and strings so the text parses back to the same values")
  func jsonRoundTrip() throws {
    let key = "he said \"hi\"\\"
    let text = "line\nbreak / \u{0001} \u{2028}"
    let json = DataExporter.toJSON(
      result: CellResult(
        columns: [
          ColumnInfo(name: key, type: "text"), ColumnInfo(name: "doc", type: "jsonb"),
          ColumnInfo(name: "n", type: "int4"), ColumnInfo(name: "b", type: "bool"),
          ColumnInfo(name: "x", type: "float8"), ColumnInfo(name: "none", type: "text"),
        ],
        rows: [
          [
            .string(text), .json("{\n  \"k\" : [1, {\"s\": \"a/b\"}]\n}"), .int(-7), .bool(true),
            .double(0.1), .null,
          ]
        ], rowCount: 1))
    let parsed = try #require(
      try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
    let expected: [[String: Any]] = [
      [
        key: text, "doc": ["k": [1, ["s": "a/b"]]], "n": -7, "b": true, "x": 0.1,
        "none": NSNull(),
      ]
    ]
    #expect(NSArray(array: parsed) == NSArray(array: expected))
  }

  @Test("JSON strings are written byte for byte as JSONSerialization writes them")
  func jsonStringsMatchSerialization() throws {
    var all = String.UnicodeScalarView()
    for value in 0..<0x80 { all.append(Unicode.Scalar(UInt8(value))) }
    let text = String(all) + "\r\n\u{2028}\u{2029}\u{85}\u{FEFF}\u{E9}\u{1F600}"
    let name = "he said \"hi\"\\ / \u{000B}"
    for pretty in [true, false] {
      let options: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted] : []
      let expected = try JSONSerialization.data(withJSONObject: [[name: text]], options: options)
      let json = DataExporter.toJSON(
        result: CellResult(
          columns: [ColumnInfo(name: name, type: "text")], rows: [[.string(text)]], rowCount: 1),
        pretty: pretty)
      #expect(json == String(decoding: expected, as: UTF8.self), "pretty: \(pretty)")
    }
  }

  @Test("JSON writes NaN and infinities as text instead of crashing")
  func jsonNonFiniteDoubles() {
    let grid = model(
      [
        ColumnInfo(name: "a", type: "float8"), ColumnInfo(name: "b", type: "float8"),
        ColumnInfo(name: "c", type: "float8"),
      ],
      [[.double(.nan), .double(.infinity), .double(-.infinity)]])
    let json = grid.copyText(
      rows: IndexSet([0]), columns: [0, 1, 2], format: .json, neutralizesFormulas: false)
    #expect(
      json
        == "[\n  {\n    \"a\" : \"NaN\",\n    \"b\" : \"Infinity\",\n    \"c\" : \"-Infinity\"\n  }\n]"
    )
  }
}
