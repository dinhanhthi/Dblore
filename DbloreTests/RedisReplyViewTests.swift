// RedisReplyViewTests.swift
// The reply view's pure helpers: the Grid's display rows (one per node, depth first, map children
// as key / value, values one escaped line cut for display) and the Raw text (numbered, nested
// lines indented under their parent's index, bytes as `\xNN`).

import Foundation
import Testing

@testable import Dblore

@Suite("Redis reply view")
struct RedisReplyViewTests {
  private static func row(
    _ path: String, _ depth: Int, _ role: RedisReplyDisplayRow.Role?, _ type: String,
    _ value: String
  ) -> RedisReplyDisplayRow {
    RedisReplyDisplayRow(path: path, depth: depth, role: role, type: type, value: value)
  }

  @Test("Grid rows follow the plugin's paths, map children as key / value, bytes escaped")
  func displayRows() {
    let reply = RedisReply.map([
      RedisReplyPair(key: .bulk(.text("name")), value: .bulk(.bytes(Data([0xFF, 0x00])))),
      RedisReplyPair(key: .simple(.text("list")), value: .array([.integer(7), .null, .set([])])),
    ])
    #expect(
      reply.displayRows() == [
        Self.row("0", 0, nil, "map", "2 pairs"),
        Self.row("0.0", 1, .key, "bulk", "name"),
        Self.row("0.1", 1, .value, "bulk", #"\xff\x00"#),
        Self.row("0.2", 1, .key, "simple", "list"),
        Self.row("0.3", 1, .value, "array", "3 items"),
        Self.row("0.3.0", 2, nil, "integer", "7"),
        Self.row("0.3.1", 2, nil, "null", "(nil)"),
        Self.row("0.3.2", 2, nil, "set", "0 items"),
      ])
  }

  @Test("A grid value is one escaped line, cut at the display limit")
  func displayValueLimit() {
    let rows = RedisReply.array([
      .bulk(.text("a\nb\tc")), .bulk(.text(String(repeating: "x", count: 1_500))),
    ]).displayRows(maxValueLength: 1_000)
    #expect(rows[1].value == #"a\nb\tc"#)
    #expect(rows[2].value == String(repeating: "x", count: 1_000) + "…")
  }

  @Test("A grid value is cut on Unicode scalars, so combining marks cannot pass the limit")
  func displayValueLimitScalars() {
    let marks = "e" + String(repeating: "\u{0301}", count: 5_000)
    let rows = RedisReply.array([.bulk(.text(marks)), .bignum("1" + marks)])
      .displayRows(maxValueLength: 1_000)
    for row in rows.dropFirst() {
      #expect(row.value.unicodeScalars.count == 1_001)
      #expect(row.value.hasSuffix("…"))
    }
  }

  @Test("Invisible, bidi and line-breaking characters are escaped in the Grid and Raw text")
  func displayEscapesInvisibles() {
    let hostile = "a\u{202E}b\u{200B}c\u{0085}d\u{2028}e"
    let shown = #"a\u{202E}b\u{200B}c\u{0085}d\u{2028}e"#
    let plain = "café 🎉"
    let reply = RedisReply.array([
      .bulk(.text(hostile)), .error(.text(hostile)), .bulk(.text(plain)),
      // Verbatim text keeps its line breaks (CRLF as LF), but no other separator
      .verbatim(.text(hostile + "\r\nline 2\nline 3\rx")),
    ])
    let rows = reply.displayRows()
    #expect(rows[1].value == shown)
    #expect(rows[2].value == shown)
    #expect(rows[3].value == plain)
    #expect(
      reply.rawText
        == "1) \"\(shown)\"\n2) (error) \(shown)\n3) \"\(plain)\"\n4) \(shown)\nline 2\nline 3"
        + #"\r"# + "x\n")
    // Bytes that are not UTF-8 as a whole stay `\xNN` even when the shown prefix is valid
    let bytes = RedisReply.bulk(.bytes(Data("ok\u{202E}AAAAAA".utf8) + Data([0xFF])))
    #expect(bytes.displayRows(maxValueLength: 10)[0].value == #"ok\xe2\x80"# + "…")
    // Default-ignorable scalars (unassigned, Hangul filler, CGJ, variation selectors) are
    // escaped too; the presentation selectors U+FE0E / U+FE0F stay only after a non-ASCII
    // emoji (digits, `#` and `*` are emoji too, so a selector after them is escaped)
    let ignorables = [
      "\u{2065}", "\u{3164}", "\u{034F}", "\u{E0100}", "\u{180B}", "\u{FE0F}", "\u{FE0E}",
    ]
    let hidden = RedisReply.array(
      ignorables.map { .bulk(.text("admin" + $0)) } + [
        .bulk(.text("\u{2764}\u{FE0F}")), .bulk(.text("admin1\u{FE0F}")),
        .bulk(.text("user:1001\u{FE0F}")), .bulk(.text("order#\u{FE0E}")),
      ])
    let hiddenShown = [
      #"admin\u{2065}"#, #"admin\u{3164}"#, #"admin\u{034F}"#, #"admin\u{E0100}"#,
      #"admin\u{180B}"#, #"admin\u{FE0F}"#, #"admin\u{FE0E}"#, "\u{2764}\u{FE0F}",
      #"admin1\u{FE0F}"#, #"user:1001\u{FE0F}"#, #"order#\u{FE0E}"#,
    ]
    #expect(hidden.displayRows().dropFirst().map(\.value) == hiddenShown)
    // Raw text pads the indexes to the widest one ("10)")
    let numbered = hiddenShown.enumerated().map { item in
      let index = String(item.offset + 1)
      return String(repeating: " ", count: 2 - index.count) + "\(index)) \"\(item.element)\"\n"
    }
    #expect(hidden.rawText == numbered.joined())
    // Verbatim text escapes them the same way
    let verbatim = RedisReply.verbatim(.text("admin1\u{FE0F}\n\u{2764}\u{FE0F}"))
    #expect(verbatim.rawText == #"admin1\u{FE0F}"# + "\n\u{2764}\u{FE0F}\n")
  }

  @Test("Raw text stops at its size cap with a line that says so")
  func rawTextCap() {
    let big = String(repeating: "x", count: 2 * 1_048_576)
    let raw = RedisReply.array([.bulk(.text(big)), .bulk(.text(big)), .bulk(.text(big))]).rawText
    #expect(raw.utf8.count <= 4 * 1_048_576 + 64)
    #expect(raw.hasSuffix("\n… (output cut at 4 MB)\n"))
    #expect(!raw.contains("3) "))
  }

  @Test("Raw text is cut before a scalar the cap splits, and not cut when it fits exactly")
  func rawTextCapBoundaries() {
    let cutLine = "\n… (output cut at 4 MB)\n"
    // The cap lands one byte into "é" and two bytes into "🎉"
    for (filler, scalar) in [(4 * 1_048_576 - 1, "é"), (4 * 1_048_576 - 2, "🎉")] {
      let raw = RedisReply.simple(.text(String(repeating: "x", count: filler) + scalar + "y"))
        .rawText
      #expect(raw.hasSuffix(cutLine))
      let head = raw.utf8.dropLast(cutLine.utf8.count)
      #expect(head.count == filler)
      #expect(head.allSatisfy { $0 == UInt8(ascii: "x") })
    }
    let exact = RedisReply.simple(.text(String(repeating: "x", count: 4 * 1_048_576 - 1)))
      .rawText
    #expect(exact.utf8.count == 4 * 1_048_576)
    #expect(!exact.contains("output cut"))
  }

  @Test("Raw text numbers the items and indents nested replies under their parent's index")
  func rawText() {
    let reply = RedisReply.array([
      .bulk(.text(#"say "hi""#)),
      .array([.integer(5), .null]),
      .error(.text("ERR no")),
      .map([RedisReplyPair(key: .bulk(.text("k")), value: .bulk(.bytes(Data([0xFF]))))]),
      .double("1.5"),
      .boolean(true),
    ])
    #expect(
      reply.rawText == """
        1) "say \\"hi\\""
        2) 1) (integer) 5
           2) (nil)
        3) (error) ERR no
        4) 1# "k" => "\\xff"
        5) (double) 1.5
        6) (true)

        """)
  }
}
