// MarkdownPreviewBridgeTests.swift
// Pure logic behind the Milkdown preview: bridge message parsing, the baseline compare that keeps
// an untouched note byte-identical, the external link policy and the Oxide theme variables.

import Foundation
import SwiftUI
import Testing

@testable import Dblore

@Suite("Markdown preview bridge")
@MainActor
struct MarkdownPreviewBridgeTests {
  // MARK: - Message parsing

  // MARK: - Sync

  private let source = "* one\r\n* [ ] task\r\nplain"
  private let baseline = "* one\n\n* [ ] task\n\nplain\n"

  @Test("Changed before ready returns nil")
  func changedBeforeReady() {
    var sync = MarkdownPreviewSync(source: source)
    #expect(sync.text(for: .changed("x")) == nil)
    #expect(sync.baseline == nil)
  }

  @Test("Changed equal to the baseline returns the source byte-identical")
  func changedBaselineReturnsSource() throws {
    var sync = MarkdownPreviewSync(source: source)
    _ = sync.text(for: .ready(baseline))
    let result = sync.text(for: .changed(baseline))
    let text = try #require(result)
    #expect(Array(text.utf8) == Array(source.utf8))
  }

  @Test("Changed to other text returns that text; undo back to baseline returns the source")
  func editThenUndo() {
    var sync = MarkdownPreviewSync(source: source)
    _ = sync.text(for: .ready(baseline))
    #expect(sync.text(for: .changed("edited\n")) == "edited\n")
    #expect(sync.text(for: .changed(baseline)) == source)
  }

  // MARK: - Link policy

  @Test("Rejects unsafe, relative, fragment-only and malformed links")
  func rejectsOtherLinks() {
    let rejected = [
      "javascript:alert(1)", "file:///etc/passwd", "data:text/html,x", "notes.md", "#top",
      "", "https://", "http:///path", "mailto:", "https//example.com", "ftp://example.com",
      " https://example.com", "https:/\\evil.com",
    ]
    for href in rejected {
      #expect(MarkdownLinkPolicy.externalURL(href) == nil, "\(href)")
    }
  }

  // MARK: - Theme

  private static let keys: Set<String> = [
    "--dblore-bg", "--dblore-fg", "--dblore-fg-muted", "--dblore-fg-subtle", "--dblore-border",
    "--dblore-code-bg", "--dblore-accent", "--dblore-accent-muted",
  ]

}
