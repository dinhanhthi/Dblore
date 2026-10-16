// QueryFieldEditingTests.swift
// Editing rules of the MongoDB query field: typing an opener inserts its pair with the caret
// inside, typing the closer steps over it, Backspace between an empty pair removes both, and
// a new line keeps the line's indent (one level deeper after an opener, with the closer moved
// to its own line). Pure text rules, no text view; "|" marks the caret in the strings below.

import Foundation
import Testing

@testable import Dblore

@Suite("Query field editing")
struct QueryFieldEditingTests {
  /// Splits "ab|c" into ("abc", 2), offsets in UTF-16 like NSTextView
  private static func parse(_ marked: String) -> (text: String, caret: Int) {
    let ns = marked as NSString
    let caret = ns.range(of: "|").location
    precondition(caret != NSNotFound, "missing caret marker")
    return (ns.replacingCharacters(in: NSRange(location: caret, length: 1), with: ""), caret)
  }

  /// Applies the edit for `key` at the marked caret; nil when the field keeps the default
  private static func type(_ key: QueryFieldEditing.Key, _ marked: String) -> String? {
    let (text, caret) = parse(marked)
    let selection = NSRange(location: caret, length: 0)
    guard let edit = QueryFieldEditing.edit(for: key, in: text, selection: selection) else {
      return nil
    }
    let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    return (result as NSString).replacingCharacters(
      in: NSRange(location: edit.caret, length: 0), with: "|")
  }

  @Test("an opener inserts its pair with the caret inside")
  func openerInsertsPair() {
    #expect(Self.type(.character("{"), "|") == "{|}")
    #expect(Self.type(.character("["), "{tags: |}") == "{tags: [|]}")
    #expect(Self.type(.character("\""), "{name: |}") == "{name: \"|\"}")
    #expect(Self.type(.character("'"), "{name: |}") == "{name: '|'}")
    // UTF-16 offsets: a character outside the BMP earlier in the text
    #expect(Self.type(.character("{"), "{a: \"😀\", b: |}") == "{a: \"😀\", b: {|}}")
    // Text right after the caret: the opener types alone
    #expect(Self.type(.character("{"), "|abc") == nil)
  }

  @Test("a closer steps over the same next character, otherwise types normally")
  func closerStepsOver() {
    #expect(Self.type(.character("}"), "{a: 1|}") == "{a: 1}|")
    #expect(Self.type(.character("]"), "[1, 2|]") == "[1, 2]|")
    // Steps over even after a word character, which would block a new quote pair
    #expect(Self.type(.character("\""), "{a: \"ab|\"}") == "{a: \"ab\"|}")
    #expect(Self.type(.character("'"), "{a: 'ab|'}") == "{a: 'ab'|}")
    // No matching closer next: the text view inserts the character itself
    #expect(Self.type(.character("}"), "{a: 1|") == nil)
    #expect(Self.type(.character("]"), "[1|}") == nil)
    // A quote with a different next character opens a new pair
    #expect(Self.type(.character("\""), "{a: |, b: 1}") == "{a: \"|\", b: 1}")
  }

  @Test("a quote does not pair after a word character or a backslash")
  func quoteAfterWordOrBackslash() {
    #expect(Self.type(.character("'"), "{note: \"don|") == nil)
    #expect(Self.type(.character("\""), "{a: \"x\\|") == nil)
    // An escaped quote types itself instead of stepping over the closing one
    #expect(Self.type(.character("\""), "{a: \"x\\|\"}") == nil)
    // An escaped backslash does not escape the quote: it steps over
    #expect(Self.type(.character("\""), "{a: \"x\\\\|\"}") == "{a: \"x\\\\\"|}")
  }

  @Test("a suggestion accepted inside a pair leaves the caret before the closers")
  func caretAfterSuggestionInsidePair() {
    /// Replaces the token `range` of the marked text with `replacement`, marks the caret
    func accept(_ marked: String, token range: NSRange, with replacement: String) -> String {
      let (text, caret) = Self.parse(marked)
      let after = QueryFieldEditing.caretAfterReplacing(
        range, in: text, caret: caret, with: replacement)
      let result = (text as NSString).replacingCharacters(in: range, with: replacement)
      return (result as NSString).replacingCharacters(
        in: NSRange(location: after, length: 0), with: "|")
    }
    #expect(
      accept("{sta|}", token: NSRange(location: 0, length: 5), with: "{status}") == "{status|}")
    #expect(
      accept("{a: {$g|}}", token: NSRange(location: 4, length: 5), with: "{$gte}}")
        == "{a: {$gte|}}")
    // The caret inside the word: the rest of the word is replaced too, the caret ends after it
    #expect(
      accept("{na|me}", token: NSRange(location: 0, length: 6), with: "{name}") == "{name|}")
    #expect(
      accept("{na|m}", token: NSRange(location: 0, length: 5), with: "{name}") == "{name|}")
  }

  @Test("a selection turns pairing off")
  func selectionTurnsPairingOff() {
    let text = "{a: 1}"
    let selection = NSRange(location: 4, length: 1)
    #expect(QueryFieldEditing.edit(for: .character("{"), in: text, selection: selection) == nil)
    #expect(QueryFieldEditing.edit(for: .character("}"), in: text, selection: selection) == nil)
  }

  @Test("a quote typed over a selection wraps it and keeps it selected")
  func quoteWrapsSelection() {
    let text = "{id: -NiZn0351}"
    let selection = NSRange(location: 5, length: 9)
    let edit = QueryFieldEditing.edit(for: .character("\""), in: text, selection: selection)
    #expect(edit?.range == selection)
    #expect(edit?.replacement == "\"-NiZn0351\"")
    #expect(edit?.caret == 6)
    #expect(edit?.selectionLength == 9)
    let single = QueryFieldEditing.edit(for: .character("'"), in: text, selection: selection)
    #expect(single?.replacement == "'-NiZn0351'")
  }

  @Test("backspace inside an empty pair deletes both characters")
  func backspaceDeletesEmptyPair() {
    #expect(Self.type(.backspace, "{a: {|}}") == "{a: |}")
    #expect(Self.type(.backspace, "{a: [|]}") == "{a: |}")
    #expect(Self.type(.backspace, "{a: \"|\"}") == "{a: |}")
    #expect(Self.type(.backspace, "{a: '|'}") == "{a: |}")
    // Not an empty pair: the text view deletes one character
    #expect(Self.type(.backspace, "{a|}") == nil)
    #expect(Self.type(.backspace, "{|]") == nil)
  }

  @Test("a new line keeps the indent and goes one level in after an opener")
  func newlineIndents() {
    #expect(Self.type(.newline, "a: 1|") == "a: 1\n|")
    #expect(Self.type(.newline, "{\n  a: 1,|") == "{\n  a: 1,\n  |")
    #expect(Self.type(.newline, "{|") == "{\n  |")
    #expect(Self.type(.newline, "{\n  tags: [|") == "{\n  tags: [\n    |")
  }

  @Test("a new line between a pair puts the closer on its own line")
  func newlineSplitsPair() {
    #expect(Self.type(.newline, "{|}") == "{\n  |\n}")
    #expect(Self.type(.newline, "{\n  a: {|}\n}") == "{\n  a: {\n    |\n  }\n}")
    #expect(Self.type(.newline, "{\n  tags: [|]\n}") == "{\n  tags: [\n    |\n  ]\n}")
  }
}
