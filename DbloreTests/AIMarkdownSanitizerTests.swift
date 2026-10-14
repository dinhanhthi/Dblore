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
