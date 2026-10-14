// TabDragOutTests.swift
// Pure helpers deciding when a dragged tab detaches into a new window and where that window lands.

import AppKit
import Testing

@testable import Dblore

@Suite("Tab Drag Out")
@MainActor
struct TabDragOutTests {
  private let frame = NSRect(x: 100, y: 200, width: 400, height: 300)

  @Test(
    "Point outside any side detaches",
    arguments: [
      NSPoint(x: 99, y: 300), NSPoint(x: 501, y: 300), NSPoint(x: 300, y: 199),
      NSPoint(x: 300, y: 501),
    ])
  func outsideDetaches(point: NSPoint) {
    #expect(TabDragOut.shouldDetach(mouseLocation: point, windowFrame: frame, canMove: true))
  }

  private let visible = NSRect(x: 0, y: 0, width: 1000, height: 800)
  private let size = NSSize(width: 400, height: 300)

}
