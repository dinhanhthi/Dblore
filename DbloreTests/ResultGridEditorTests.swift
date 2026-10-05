// ResultGridEditorTests.swift
// Scroll hand-off for a result grid. The choice is a pure function of the scroll and the clip
// position; one tiled scroll view checks that the choice still reaches the parent.

import AppKit
import Foundation
import Testing

@testable import Dblore

/// One scroll judged by `ResultGridScrollView.scrollHandOff`.
struct ScrollHandOffCase: Sendable {
  var deltaX: CGFloat = 0
  var deltaY: CGFloat = 0
  var phase: NSEvent.Phase = []
  var momentum: NSEvent.Phase = []
  var modifiers: NSEvent.ModifierFlags = []
  var offsetY: CGFloat = 0
  var maxOffsetY: CGFloat = 0
  var forwardsToParent = true
  var startsGesture = true
  var locksForward: Bool?
}

@Suite("Result grid - editor panel")
@MainActor
struct ResultGridEditorTests {
  /// Records the scroll events handed to it by the grid's scroll view
  private final class ScrollRecorder: NSView {
    var received = 0
    override func scrollWheel(with event: NSEvent) { received += 1 }
  }

  @Test(
    "A vertical scroll is handed to the parent only when the grid cannot take it",
    arguments: [
      // Discrete wheel, content fits, hand-off on
      ScrollHandOffCase(deltaY: 5, locksForward: true),
      // The editor panel keeps that same scroll
      ScrollHandOffCase(deltaY: 5, forwardsToParent: false, locksForward: false),
      // At the top, scrolling down: the grid can take it
      ScrollHandOffCase(deltaY: -5, maxOffsetY: 100, locksForward: false),
      // At the top, scrolling up: nowhere left to go
      ScrollHandOffCase(deltaY: 5, maxOffsetY: 100, locksForward: true),
      // Horizontal movement stays in the grid
      ScrollHandOffCase(deltaX: 6, deltaY: 2, locksForward: false),
      // A tie is not a vertical scroll
      ScrollHandOffCase(deltaX: 4, deltaY: -4, locksForward: false),
      // Shift+wheel scrolls horizontally and does not lock the gesture
      ScrollHandOffCase(deltaY: 5, modifiers: .shift, locksForward: nil),
      // No movement yet: the gesture stays unlocked
      ScrollHandOffCase(locksForward: nil),
      // A continued trackpad gesture does not start a new choice
      ScrollHandOffCase(deltaY: 5, phase: .changed, startsGesture: false, locksForward: true),
      // Momentum continues the gesture that already chose
      ScrollHandOffCase(
        deltaY: 5, momentum: .changed, startsGesture: false, locksForward: true),
      // began starts a gesture
      ScrollHandOffCase(deltaY: 5, phase: .began, locksForward: true),
      // mayBegin starts a gesture, but a zero delta does not lock it
      ScrollHandOffCase(phase: .mayBegin, locksForward: nil),
    ])
  func scrollHandOff(row: ScrollHandOffCase) {
    let decision = ResultGridScrollView.scrollHandOff(
      deltaX: row.deltaX,
      deltaY: row.deltaY,
      phase: row.phase,
      momentumPhase: row.momentum,
      modifiers: row.modifiers,
      offsetY: row.offsetY,
      maxOffsetY: row.maxOffsetY,
      forwardsToParent: row.forwardsToParent)
    #expect(decision.startsGesture == row.startsGesture)
    #expect(decision.locksForward == row.locksForward)
  }

  @Test("A tiled grid hands a vertical scroll the content cannot take to its parent")
  func tiledScrollHandsOffToParent() throws {
    #expect(try deliveredScrolls(forwardsToParent: false) == 0)
    #expect(try deliveredScrolls(forwardsToParent: true) == 1)
  }

  /// Scroll view tiled in a window, document shorter than the clip, so the content fits
  private func deliveredScrolls(forwardsToParent: Bool) throws -> Int {
    let parent = ScrollRecorder(frame: NSRect(x: 0, y: 0, width: 220, height: 180))
    let scrollView = ResultGridScrollView(frame: parent.bounds)
    scrollView.forwardsToParent = forwardsToParent
    scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 40))
    parent.addSubview(scrollView)
    let window = NSWindow(
      contentRect: parent.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView?.addSubview(parent)
    scrollView.tile()

    let clip = scrollView.contentView
    let maxOffsetY =
      (scrollView.documentView?.frame.height ?? 0) + clip.contentInsets.top
      + clip.contentInsets.bottom
      - clip.bounds.height
    #expect(maxOffsetY < 1)

    let cgEvent = try #require(
      CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 5, wheel2: 0,
        wheel3: 0))
    let event = try #require(NSEvent(cgEvent: cgEvent))
    #expect(event.scrollingDeltaY != 0)
    scrollView.scrollWheel(with: event)
    return parent.received
  }
}
