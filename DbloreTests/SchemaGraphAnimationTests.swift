// SchemaGraphAnimationTests.swift
// The column connection dashes animate with a 20 Hz timer. Closing the visualizer removes the
// view from its window: the timer must stop then, or it keeps firing for the app's lifetime
// (and each reopen adds another).

import AppKit
import Testing

@testable import Dblore

@Suite("Schema graph animation", .serialized)
@MainActor
struct SchemaGraphAnimationTests {
  /// Dash phase changes over `duration` (the 20 Hz timer advances it by 1 per tick)
  private static func phaseChanges(
    of view: SchemaGraphNSView, over duration: Duration
  ) async
    -> Int
  {
    var changes = 0
    var last = view.columnConnectionAnimationPhase
    let deadline = ContinuousClock.now + duration
    while ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
      if view.columnConnectionAnimationPhase != last {
        changes += 1
        last = view.columnConnectionAnimationPhase
      }
    }
    return changes
  }

  @Test(
    "Column connection dashes stop animating once the view leaves its window",
    .enabled { @MainActor in !SidebarAnimation.reduceMotion })
  func timerStopsOutsideWindow() async {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless,
      backing: .buffered, defer: true)
    let view = SchemaGraphNSView(frame: window.contentLayoutRect)
    window.contentView?.addSubview(view)
    view.showColumnConnections = true

    let inWindow = await Self.phaseChanges(of: view, over: .milliseconds(300))
    #expect(inWindow > 0, "dashes animate while the view is in a window")

    view.removeFromSuperview()
    // Let a tick already queued land first
    try? await Task.sleep(for: .milliseconds(100))
    let outside = await Self.phaseChanges(of: view, over: .milliseconds(300))
    #expect(outside == 0, "timer still ticking \(outside) times in 300 ms outside a window")
  }
}
