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
}
