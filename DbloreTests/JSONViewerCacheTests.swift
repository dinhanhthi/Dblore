// JSONViewerCacheTests.swift
// The JSON viewer keeps the last JSON's pretty copy and highlighted text so a re-render with
// the same JSON is cheap, at any size: closing the viewer drops the cache. The cell info
// highlighter, which nothing clears, does not retain JSON above the cap, measured on the
// string it highlights.

import AppKit
import SwiftUI
import Testing

@testable import Dblore

@Suite("JSON viewer cache", .serialized)
@MainActor
struct JSONViewerCacheTests {
  /// One string token above the cap: tokenizing stays quick in Debug
  private static let largeJSON =
    "\"" + String(repeating: "a", count: HighlightedJSONText.maxCachedBytes) + "\""

  @Test("Inside the viewer a large JSON is cached until the viewer closes")
  func viewerCachesLargeJSONUntilClosed() {
    JSONViewerContent.clearCaches()
    let json = Self.largeJSON
    _ = JSONViewerContent.prettyPrinted(json)
    _ = HighlightedJSONText.attributedString(for: json, cachesAnySize: true)
    #expect(JSONViewerContent.lastPrettyPrint?.json == json)
    #expect(HighlightedJSONText.lastHighlight?.json == json)

    // A re-render returns what is stored instead of building it again
    HighlightedJSONText.lastHighlight = (json, AttributedString("cached"))
    JSONViewerContent.lastPrettyPrint = (json, "cached")
    #expect(
      String(HighlightedJSONText.attributedString(for: json, cachesAnySize: true).characters)
        == "cached")
    #expect(JSONViewerContent.prettyPrinted(json) == "cached")

    JSONViewerContent.clearCaches()
    #expect(HighlightedJSONText.lastHighlight == nil)
    #expect(JSONViewerContent.lastPrettyPrint == nil)
  }

  @Test("The viewer passes its large JSON through the uncapped cache")
  func viewerRenderCachesLargeJSON() {
    JSONViewerContent.clearCaches()
    let host = NSHostingView(
      rootView: JSONViewerContent(json: Self.largeJSON, path: "p", onSave: nil))
    host.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
    host.layoutSubtreeIfNeeded()
    #expect(JSONViewerContent.lastPrettyPrint?.json == Self.largeJSON)
    #expect(
      HighlightedJSONText.lastHighlight?.json == JSONViewerContent.prettyPrinted(Self.largeJSON))
    JSONViewerContent.clearCaches()
  }

  @Test("The capped highlighter measures the string it highlights, not the raw cell")
  func cappedHighlighterMeasuresItsInput() {
    JSONViewerContent.clearCaches()
    // Compact form under the cap, pretty form over it
    let compact =
      #"{"a":""# + String(repeating: "a", count: HighlightedJSONText.maxCachedBytes - 10) + #""}"#
    let pretty = JSONViewerContent.prettyPrinted(compact)
    #expect(compact.utf8.count <= HighlightedJSONText.maxCachedBytes)
    #expect(pretty.utf8.count > HighlightedJSONText.maxCachedBytes)

    // The viewer caches both the pretty copy and its highlight
    _ = HighlightedJSONText.attributedString(for: pretty, cachesAnySize: true)
    #expect(JSONViewerContent.lastPrettyPrint?.json == compact)
    #expect(HighlightedJSONText.lastHighlight?.json == pretty)

    // The capped path (cell info) does not retain JSON above the cap
    HighlightedJSONText.lastHighlight = nil
    let text = HighlightedJSONText.attributedString(for: pretty)
    #expect(text.characters.count == pretty.count)
    #expect(HighlightedJSONText.lastHighlight == nil)
    JSONViewerContent.clearCaches()
  }
}
