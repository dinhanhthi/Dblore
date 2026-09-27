// ResultGridEditorTests.swift
// The result grid filling the editor result panel: it keeps every vertical scroll instead of
// handing it to the parent view (the notebook hand-off is off).

import AppKit
import Testing

@testable import SQLNotebook

@Suite("Result grid - editor panel")
@MainActor
struct ResultGridEditorTests {
  /// Records the scroll events handed to it by the grid's scroll view
  private final class ScrollRecorder: NSView {
    var received = 0
    override func scrollWheel(with event: NSEvent) { received += 1 }
  }

  @Test(
    "A vertical scroll the grid can't take goes to the parent only when hand-off is on",
    arguments: [true, false])
  func scrollHandOffGate(forwardsToParent: Bool) throws {
    let parent = ScrollRecorder(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
    let scrollView = ResultGridScrollView(frame: parent.bounds)
    scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 10))
    scrollView.forwardsToParent = forwardsToParent
    parent.addSubview(scrollView)

    let cgEvent = try #require(
      CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 5, wheel2: 0,
        wheel3: 0))
    let event = try #require(NSEvent(cgEvent: cgEvent))
    #expect(event.scrollingDeltaY != 0)

    scrollView.scrollWheel(with: event)
    #expect(parent.received == (forwardsToParent ? 1 : 0))
  }
}
