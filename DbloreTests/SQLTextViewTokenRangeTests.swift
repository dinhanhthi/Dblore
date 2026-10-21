// SQLTextViewTokenRangeTests.swift
// The token an accepted completion replaces is measured in UTF-16, as the editor's ranges are

import AppKit
import Foundation
import Testing

@testable import Dblore

@Suite("SQLTextViewTokenRangeTests")
@MainActor
struct SQLTextViewTokenRangeTests {
  @Test func tokenRangeCountsUTF16AfterNonASCIIText() throws {
    let textView = SQLTextView(frame: .zero)

    // An emoji (two UTF-16 units) earlier on the line
    let emoji = "SELECT 😀x, us FROM t" as NSString
    let cursor = emoji.range(of: "us").upperBound
    let range = try #require(textView.findTokenRange(in: emoji as String, at: cursor))
    #expect(emoji.replacingCharacters(in: range, with: "users") == "SELECT 😀x, users FROM t")

    // A combining accent inside the token itself, cursor at the end of the text
    let accent = "SELECT cafe\u{301}_i" as NSString
    let end = try #require(textView.findTokenRange(in: accent as String, at: accent.length))
    #expect(accent.substring(with: end) == "cafe\u{301}_i")
  }
}
