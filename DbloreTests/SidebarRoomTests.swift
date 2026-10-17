// SidebarRoomTests.swift
// Widths of the workspace sidebars at a window width, and whether the left sidebar still leaves
// the tab content its minimum width beside the right sidebars.

import CoreGraphics
import Testing

@testable import Dblore

@Suite("Sidebar room")
@MainActor
struct SidebarRoomTests {

  private typealias R = SidebarRoom

  @Test("left sidebar keeps its stored width, at most 35% of the window")
  func leftWidthIsCappedAt35Percent() {
    #expect(R.leftWidth(300, windowWidth: 1000) == 300)
    #expect(R.leftWidth(500, windowWidth: 1000) == 350)
  }

  @Test("AI panel is at least the sidebar width and at most 35% of the window, never below it")
  func aiWidthIsClamped() {
    #expect(R.aiWidth(100, windowWidth: 2000) == ComponentSize.sidebarWidth)
    #expect(R.aiWidth(900, windowWidth: 2000) == 700)
    #expect(R.aiWidth(900, windowWidth: 800) == ComponentSize.sidebarWidth)
  }

  @Test("the 1000 minimum window has no room for the left sidebar beside a 320 right sidebar")
  func minimumWindowCrowds() {
    #expect(!R.leftSidebarFits(windowWidth: 1000, leftWidth: 300, rightWidth: 320))
  }

  @Test("the 1200 default window has no room for a 300 left beside a 320 right sidebar")
  func defaultWindowCrowds() {
    #expect(!R.leftSidebarFits(windowWidth: 1200, leftWidth: 300, rightWidth: 320))
  }

  @Test("a 1300 window fits a 300 left and a 320 right sidebar")
  func widerWindowFits() {
    #expect(R.leftSidebarFits(windowWidth: 1300, leftWidth: 300, rightWidth: 320))
  }

  @Test("both right sidebars open count together")
  func bothRightSidebarsCrowd() {
    #expect(!R.leftSidebarFits(windowWidth: 1200, leftWidth: 300, rightWidth: 640))
  }
}
