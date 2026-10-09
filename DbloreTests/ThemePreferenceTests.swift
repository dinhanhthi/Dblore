// ThemePreferenceTests.swift
// Header theme toggle: flips only between light and dark, based on the currently displayed
// scheme (so a "System" preference resolves to the opposite of what is on screen).

import SwiftUI
import Testing

@testable import Dblore

@Suite("Theme preference toggle")
@MainActor
struct ThemePreferenceTests {

  @Test("toggles to the opposite of the displayed scheme")
  func togglesOpposite() {
    #expect(ThemePreference.toggled(from: .dark) == .light)
    #expect(ThemePreference.toggled(from: .light) == .dark)
  }
}
