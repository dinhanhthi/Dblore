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

  @Test("Parses ready, changed and openLink messages")
  func parsesValidMessages() {
    #expect(MarkdownBridgeMessage(body: ["type": "ready", "markdown": "# A\n"]) == .ready("# A\n"))
    #expect(MarkdownBridgeMessage(body: ["type": "changed", "markdown": "b"]) == .changed("b"))
    #expect(
      MarkdownBridgeMessage(body: ["type": "openLink", "href": "https://x.io"])
        == .openLink("https://x.io"))
    let nsBody: NSDictionary = ["type": "changed", "markdown": "ns"]
    #expect(MarkdownBridgeMessage(body: nsBody) == .changed("ns"))
  }

  @Test("Rejects invalid message shapes")
  func rejectsInvalidMessages() {
    let invalid: [Any] = [
      "ready",
      42,
      ["markdown": "x"],
      ["type": "unknown", "markdown": "x"],
      ["type": 1, "markdown": "x"],
      ["type": "ready"],
      ["type": "ready", "markdown": 3],
      ["type": "changed", "markdown": NSNull()],
      ["type": "openLink"],
      ["type": "openLink", "href": 7],
    ]
    for body in invalid {
      #expect(MarkdownBridgeMessage(body: body) == nil)
    }
  }

  // MARK: - Sync

  private let source = "* one\r\n* [ ] task\r\nplain"
  private let baseline = "* one\n\n* [ ] task\n\nplain\n"

  @Test("Changed before ready returns nil")
  func changedBeforeReady() {
    var sync = MarkdownPreviewSync(source: source)
    #expect(sync.text(for: .changed("x")) == nil)
    #expect(sync.baseline == nil)
  }

  @Test("Ready stores the baseline and returns nil")
  func readyStoresBaseline() {
    var sync = MarkdownPreviewSync(source: source)
    #expect(sync.text(for: .ready(baseline)) == nil)
    #expect(sync.baseline == baseline)
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

  @Test("openLink never produces text")
  func openLinkReturnsNil() {
    var sync = MarkdownPreviewSync(source: source)
    _ = sync.text(for: .ready(baseline))
    #expect(sync.text(for: .openLink("https://x.io")) == nil)
  }

  @Test("Snapshot follows the same baseline rule")
  func snapshotRules() {
    var sync = MarkdownPreviewSync(source: source)
    #expect(sync.text(forSnapshot: baseline) == nil)
    _ = sync.text(for: .ready(baseline))
    #expect(sync.text(forSnapshot: baseline) == source)
    #expect(sync.text(forSnapshot: "other") == "other")
  }

  // MARK: - Link policy

  @Test("Accepts http, https and mailto links")
  func acceptsExternalLinks() {
    for href in [
      "https://example.com/a?b=1", "http://example.com", "mailto:me@example.com",
      "HTTPS://example.com",
    ] {
      #expect(MarkdownLinkPolicy.externalURL(href)?.absoluteString == href)
    }
  }

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

  @Test("Light and dark background/foreground match the design tokens")
  func themeMatchesTokens() {
    let light = MarkdownEditorTheme.variables(colorScheme: .light)
    let dark = MarkdownEditorTheme.variables(colorScheme: .dark)
    // Literals from DesignSystem+Colors.swift: appBackground and foreground.
    #expect(light["--dblore-bg"] == "#ffffff")
    #expect(dark["--dblore-bg"] == "#1e1e1e")
    #expect(light["--dblore-fg"] == "#09090b")
    #expect(dark["--dblore-fg"] == "#fafafa")
    #expect(light["--dblore-code-bg"] == "#f5f5f5")
    #expect(dark["--dblore-code-bg"] == "#3c3c3c")
  }

  @Test("All 8 keys are present with #rrggbb values", arguments: [ColorScheme.light, .dark])
  func themeKeysAndFormat(colorScheme: ColorScheme) {
    let vars = MarkdownEditorTheme.variables(colorScheme: colorScheme)
    #expect(Set(vars.keys) == Self.keys)
    for (key, value) in vars {
      #expect(value.wholeMatch(of: /#[0-9a-f]{6}/) != nil, "\(key)=\(value)")
    }
  }
}
