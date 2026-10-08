// MarkdownTabTypeTests.swift
// The `.markdown` tab type is detected from ".md" only (any case), never from ".txt" or
// ".markdown", and maps to the markdown app mode.

import Foundation
import Testing

@testable import Dblore

@Suite("Markdown tab type")
@MainActor
struct MarkdownTabTypeTests {
  @Test("Is detected from .md in any case")
  func fromMDURL() {
    for name in ["a.md", "A.MD"] {
      #expect(TabDocumentType.from(url: URL(fileURLWithPath: "/tmp/\(name)")) == .markdown)
    }
  }

  @Test("Is not detected from .txt, .markdown or no extension")
  func notFromOtherURLs() {
    for name in ["a.txt", "a.markdown", "a"] {
      #expect(TabDocumentType.from(url: URL(fileURLWithPath: "/tmp/\(name)")) == nil)
    }
  }

  @Test("Has the md extension and a rich text icon")
  func extensionAndIcon() {
    #expect(TabDocumentType.markdown.fileExtension == "md")
    #expect(TabDocumentType.markdown.icon == "doc.richtext")
    #expect(AppMode.markdown.fileExtension == "md")
  }
}
