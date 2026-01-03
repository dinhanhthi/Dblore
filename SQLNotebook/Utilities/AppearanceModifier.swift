//
//  AppearanceModifier.swift
//  SQLNotebook
//

import AppKit
import SwiftUI

/// Global manager to handle appearance at the application level
@MainActor
class AppearanceManager {
  static let shared = AppearanceManager()

  var currentScheme: ColorScheme?

  private init() {}

  func setAppearance(_ colorScheme: ColorScheme?) {
    currentScheme = colorScheme
    applyAppearance()
  }

  private func applyAppearance() {
    // Set appearance at NSApplication level for app-wide persistence
    // This will be called from ContentView.onAppear when NSApp is ready
    if let scheme = currentScheme {
      switch scheme {
      case .light:
        NSApp.appearance = NSAppearance(named: .aqua)
      case .dark:
        NSApp.appearance = NSAppearance(named: .darkAqua)
      @unknown default:
        NSApp.appearance = nil
      }
    } else {
      // System default
      NSApp.appearance = nil
    }
  }
}

/// A ViewModifier that applies NSAppearance at application level
struct AppearanceModifier: ViewModifier {
  let colorScheme: ColorScheme?

  func body(content: Content) -> some View {
    content
      .onAppear {
        AppearanceManager.shared.setAppearance(colorScheme)
      }
      .onChange(of: colorScheme) { _, newScheme in
        AppearanceManager.shared.setAppearance(newScheme)
      }
  }
}

extension View {
  /// Apply a specific appearance (light/dark) to the window
  func windowAppearance(_ colorScheme: ColorScheme?) -> some View {
    modifier(AppearanceModifier(colorScheme: colorScheme))
  }
}
