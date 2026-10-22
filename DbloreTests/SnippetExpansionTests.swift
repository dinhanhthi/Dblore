// SnippetExpansionTests.swift
// SQL snippet bodies: tab stop order, defaults, the final cursor, escapes, the save limits, and
// reading saved snippets back

import Foundation
import Testing

@testable import Dblore

@Suite("SQL Snippet Expansion")
struct SnippetExpansionTests {
  private func texts(_ expansion: SQLSnippet.Expansion) -> [String] {
    expansion.stops.map { (expansion.text as NSString).substring(with: $0) }
  }

  @Test("stops go 1, 2, … by index whatever their place, with their defaults, then $0 last")
  func stopOrderDefaultsAndFinalCursor() {
    let expansion = SQLSnippet.expand("SELECT ${2:*} FROM ${1:table} WHERE ${3}$0;")
    #expect(expansion.text == "SELECT * FROM table WHERE ;")
    #expect(
      expansion.stops == [
        NSRange(location: 14, length: 5), NSRange(location: 7, length: 1),
        NSRange(location: 26, length: 0), NSRange(location: 26, length: 0),
      ])
    #expect(texts(expansion) == ["table", "*", "", ""])
  }

  @Test("no $0 puts the final cursor at the end; a repeated index keeps only its first stop")
  func finalCursorAtEndAndMirroredStops() {
    let expansion = SQLSnippet.expand("SELECT ${1:id}, ${1} FROM t")
    #expect(expansion.text == "SELECT id, id FROM t")
    #expect(
      expansion.stops == [NSRange(location: 7, length: 2), NSRange(location: 20, length: 0)])
  }

  @Test("\\$ is a literal dollar; malformed placeholders and bare $1 stay as written")
  func escapedDollarAndMalformedStayLiteral() {
    let expansion = SQLSnippet.expand(#"SELECT '\$5', $1, ${x}, ${2 FROM "🙂" ${1:a}"#)
    #expect(expansion.text == #"SELECT '$5', $1, ${x}, ${2 FROM "🙂" a"#)
    let location = (expansion.text as NSString).length - 1
    #expect(
      expansion.stops == [
        NSRange(location: location, length: 1), NSRange(location: location + 1, length: 0),
      ])
  }

  @Test("save rejects a 201st snippet and a body over 4,000 characters")
  func limitsEnforcedOnSave() {
    let full = (1...SQLSnippet.maxSnippets).map {
      SQLSnippet(name: "S\($0)", trigger: "s\($0)", body: "SELECT \($0)")
    }
    let extra = SQLSnippet(name: "Extra", trigger: "extra", body: "SELECT 1")
    #expect(SQLSnippet.validate(extra, among: full) == .tooManySnippets)
    #expect(SQLSnippet.validate(full[0], among: full) == nil)

    let long = SQLSnippet(
      name: "Long", trigger: "long", body: String(repeating: "x", count: 4_001))
    #expect(SQLSnippet.validate(long, among: []) == .bodyTooLong)
    #expect(SQLSnippet.sanitized(full + [extra, long]).count == SQLSnippet.maxSnippets)

    // Combining marks: few characters, many more UTF-16 units
    let marks = String(repeating: "\u{301}", count: 10)
    let markedBody = SQLSnippet(
      name: "Marks", trigger: "marks", body: String(repeating: "e" + marks, count: 2_000))
    #expect(SQLSnippet.validate(markedBody, among: []) == .bodyTooLong)
    let markedName = SQLSnippet(
      name: String(repeating: "n" + marks, count: 64), trigger: "named", body: "SELECT 1")
    #expect(SQLSnippet.validate(markedName, among: []) == .nameTooLong)
  }

  @Test("a repeated default stops being written once the text passes the expansion cap")
  func expansionCap() {
    let value = String(repeating: "x", count: 4_000)
    let body = "${1:\(value)}" + String(repeating: "${1}", count: 1_000)
    let expansion = SQLSnippet.expand(body)
    let length = (expansion.text as NSString).length
    #expect(length <= SQLSnippet.maxExpandedLength + (body as NSString).length)
    #expect(expansion.text.hasPrefix(value + value))
    #expect(expansion.text.hasSuffix("${1}${1}"))
  }

  @Test("saved data is untrusted: a bad entry drops alone, invalid triggers go, the rest is empty")
  func decodeUntrustedData() throws {
    func entry(_ name: String, trigger: Any?, body: Any) -> [String: Any] {
      var fields: [String: Any] = ["id": UUID().uuidString, "name": name, "body": body]
      fields["trigger"] = trigger
      return fields
    }
    let entries: [[String: Any]] = [
      entry("Select", trigger: "sel", body: "SELECT ${1:*} FROM ${2}"),
      entry("No trigger", trigger: nil, body: "SELECT 2"),
      entry("Wrong type", trigger: "typed", body: 42),
      entry("Bad trigger", trigger: "two words", body: "SELECT 3"),
      entry("Count", trigger: "cnt", body: "SELECT count(*) FROM $0"),
    ]
    let data = try JSONSerialization.data(withJSONObject: entries)
    #expect(SQLSnippetStore.decode(data).map(\.trigger) == ["sel", "cnt"])
    #expect(SQLSnippetStore.decode(Data(#"{"name": "Select"}"#.utf8)).isEmpty)
    #expect(SQLSnippetStore.decode(nil).isEmpty)
    // Too large to read, however valid
    let padding = Data(String(repeating: " ", count: SQLSnippetStore.maxStoredBytes).utf8)
    #expect(SQLSnippetStore.decode(padding + data).isEmpty)
  }
}
