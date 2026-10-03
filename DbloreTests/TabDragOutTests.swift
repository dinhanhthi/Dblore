// TabDragOutTests.swift
// Pure helpers deciding when a dragged tab detaches into a new window and where that window lands.

import AppKit
import Testing

@testable import Dblore

@Suite("Tab Drag Out")
@MainActor
struct TabDragOutTests {
  private let frame = NSRect(x: 100, y: 200, width: 400, height: 300)

  @Test("Point inside the window frame does not detach")
  func insideDoesNotDetach() {
    #expect(
      !TabDragOut.shouldDetach(
        mouseLocation: NSPoint(x: 300, y: 350), windowFrame: frame, canMove: true))
  }

  @Test(
    "Point on any edge counts as inside",
    arguments: [
      NSPoint(x: 100, y: 300), NSPoint(x: 500, y: 300), NSPoint(x: 300, y: 200),
      NSPoint(x: 300, y: 500),
    ])
  func edgeCountsAsInside(point: NSPoint) {
    #expect(!TabDragOut.shouldDetach(mouseLocation: point, windowFrame: frame, canMove: true))
  }

  @Test(
    "Point outside any side detaches",
    arguments: [
      NSPoint(x: 99, y: 300), NSPoint(x: 501, y: 300), NSPoint(x: 300, y: 199),
      NSPoint(x: 300, y: 501),
    ])
  func outsideDetaches(point: NSPoint) {
    #expect(TabDragOut.shouldDetach(mouseLocation: point, windowFrame: frame, canMove: true))
  }

  @Test("Outside point does not detach when the tab cannot move")
  func cannotMoveDoesNotDetach() {
    #expect(
      !TabDragOut.shouldDetach(
        mouseLocation: NSPoint(x: 0, y: 0), windowFrame: frame, canMove: false))
  }

  @Test("Detached window origin puts the drop point over its tab bar")
  func detachedOrigin() {
    let origin = TabDragOut.detachedWindowOrigin(
      dropPoint: NSPoint(x: 1000, y: 800), windowSize: NSSize(width: 900, height: 600))
    #expect(origin.x == 1000 - ComponentSize.trafficLightAndToggleWidth)
    #expect(origin.y == 800 + ComponentSize.tabBarHeight / 2 - 600)
  }

  private let visible = NSRect(x: 0, y: 0, width: 1000, height: 800)
  private let size = NSSize(width: 400, height: 300)

  @Test("Origin inside the visible frame is unchanged")
  func clampInside() {
    let origin = TabDragOut.clampedOrigin(
      NSPoint(x: 100, y: 100), windowSize: size, visibleFrame: visible)
    #expect(origin == NSPoint(x: 100, y: 100))
  }

  @Test(
    "Origin off any edge is pulled back inside",
    arguments: [
      (NSPoint(x: -50, y: 100), NSPoint(x: 0, y: 100)),
      (NSPoint(x: 900, y: 100), NSPoint(x: 600, y: 100)),
      (NSPoint(x: 100, y: -50), NSPoint(x: 100, y: 0)),
      (NSPoint(x: 100, y: 700), NSPoint(x: 100, y: 500)),
    ])
  func clampOffEdge(origin: NSPoint, expected: NSPoint) {
    #expect(
      TabDragOut.clampedOrigin(origin, windowSize: size, visibleFrame: visible) == expected)
  }

  @Test("Window larger than the visible frame pins to its top-left")
  func clampOversized() {
    let origin = TabDragOut.clampedOrigin(
      NSPoint(x: 300, y: 300), windowSize: NSSize(width: 1200, height: 900), visibleFrame: visible)
    #expect(origin == NSPoint(x: 0, y: -100))
  }

  @Test("Pending detach is keyed to its workspace and consumed once")
  func pendingDetachContract() {
    let store = NewWindowStore.shared
    let a = UUID()
    let b = UUID()
    store.setPendingDetach(workspaceId: a, point: NSPoint(x: 1, y: 2))
    #expect(store.takePendingDetach(workspaceId: b) == nil)
    #expect(store.takePendingDetach(workspaceId: a) == NSPoint(x: 1, y: 2))
    #expect(store.takePendingDetach(workspaceId: a) == nil)
    store.setPendingDetach(workspaceId: a, point: NSPoint(x: 3, y: 4))
    store.clearPendingDetach(workspaceId: a)
    #expect(store.takePendingDetach(workspaceId: a) == nil)
  }
}
