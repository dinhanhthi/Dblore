// AIMarkdownSanitizerTests.swift
// Model-supplied markdown links must render as plain, non-clickable text

import Foundation
import Testing

@testable import Dblore

@Suite("AIMarkdownText sanitizing")
struct AIMarkdownSanitizerTests {

  @Test func linksBecomePlainText() {
    let result = AIMarkdownText.sanitized("see [docs](https://evil.example) now")
    #expect(String(result.characters) == "see docs now")
    #expect(result.runs.allSatisfy { $0.link == nil })
  }

  @Test func boldStaysEmphasized() {
    let result = AIMarkdownText.sanitized("drop **all** rows")
    #expect(String(result.characters) == "drop all rows")
    #expect(
      result.runs.contains {
        $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
      })
  }

  @Test func headingsDropMarkers() {
    #expect(
      AIMarkdownText.blocks("## Title ##\n### Query 1:\n#### Explanation:") == [
        .heading(level: 2, text: "Title"),
        .heading(level: 3, text: "Query 1:"),
        .heading(level: 4, text: "Explanation:"),
      ])
    #expect(AIMarkdownText.blocks("###Query") == [.paragraph("###Query")])
  }

  @Test func listsGroupAndParagraphsKeepNewlines() {
    #expect(
      AIMarkdownText.blocks("- SELECT: cols\n- FROM: table\n\nHello\nworld\n1. First") == [
        .list(items: [
          AIMarkdownListItem(marker: "•", text: "SELECT: cols"),
          AIMarkdownListItem(marker: "•", text: "FROM: table"),
        ]),
        .paragraph("Hello\nworld"),
        .list(items: [AIMarkdownListItem(marker: "1.", text: "First")]),
      ])
  }

  @Test func fenceSplitLeavesHeadingsOutsideCode() {
    let segments = AIMessageParser.parse(
      """
      ### Query 1:
      ```sql
      SELECT 1
      ```
      #### Explanation:
      - SELECT: columns
      """)
    guard segments.count == 3, case .text(let intro) = segments[0],
      case .text(let outro) = segments[2]
    else {
      Issue.record("expected text around the code fence")
      return
    }
    #expect(AIMarkdownText.blocks(intro) == [.heading(level: 3, text: "Query 1:")])
    #expect(
      AIMarkdownText.blocks(outro) == [
        .heading(level: 4, text: "Explanation:"),
        .list(items: [AIMarkdownListItem(marker: "•", text: "SELECT: columns")]),
      ])
  }
}
