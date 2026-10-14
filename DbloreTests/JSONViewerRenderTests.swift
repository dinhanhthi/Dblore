// JSONViewerRenderTests.swift
// The right sidebar's JSON viewer re-renders whenever its parent does (sidebar animation, copy
// feedback, cell selection). Re-rendering the same JSON must not pretty-print, tokenize and
// rebuild the highlighted text again. Compared within one run (re-render vs first render).

import AppKit
import SwiftUI
import Testing

@testable import Dblore

@Suite("JSON viewer render", .serialized)
@MainActor
struct JSONViewerRenderTests {
  /// About 100 KB of nested JSON on one line, as a jsonb cell arrives
  private static let bigJSON: String = {
    let items = (0..<600).map { i in
      #"{"id":\#(i),"name":"user \#(i)","active":\#(i % 2 == 0),"score":\#(Double(i) * 1.5),"#
        + #""tags":["a\#(i)","b\#(i)","c\#(i)"],"profile":{"city":"City \#(i)","zip":null}}"#
    }
    return "[" + items.joined(separator: ",") + "]"
  }()

  private static func ms(_ body: () -> Void) -> Double {
    let d = ContinuousClock().measure(body)
    return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
  }

  @Test("Re-rendering the same JSON is at least 5x cheaper than the first render")
  func rerenderSameJSONIsCheap() {
    let host = NSHostingView(rootView: JSONViewerContent(json: "{}", path: "p", onSave: nil))
    host.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
    host.layoutSubtreeIfNeeded()

    // A new path re-runs the parent body with the same JSON
    var renders = 0
    func render() {
      renders += 1
      host.rootView = JSONViewerContent(json: Self.bigJSON, path: "p\(renders)", onSave: nil)
      host.layoutSubtreeIfNeeded()
    }
    let first = Self.ms(render)
    var samples = (0..<5).map { _ in Self.ms(render) }
    samples.sort()
    let rerender = samples[samples.count / 2]

    PerfReport.record("jsonViewer100KB.firstRender", ms: first)
    PerfReport.record("jsonViewer100KB.rerender", ms: rerender)
    #expect(rerender * 5 < first, "re-render \(rerender) ms vs first render \(first) ms")
  }
}
