//
//  UpdaterControllerTests.swift
//  SQLNotebookTests
//

import Foundation
import Testing

@testable import SQLNotebook

@MainActor
struct UpdaterControllerTests {

  @Test("Automatic-check toggle round-trips through Sparkle")
  func testAutomaticChecksRoundTrip() {
    let key = "SUEnableAutomaticChecks"
    let defaults = UserDefaults.standard
    let savedDefault = defaults.object(forKey: key)
    let controller = UpdaterController.shared
    let original = controller.automaticallyChecksForUpdates
    defer {
      controller.automaticallyChecksForUpdates = original
      // Restore the raw default so the user's preference is left exactly as it was
      if let savedDefault {
        defaults.set(savedDefault, forKey: key)
      } else {
        defaults.removeObject(forKey: key)
      }
    }

    controller.automaticallyChecksForUpdates = !original
    #expect(controller.automaticallyChecksForUpdates == !original)
    // Sparkle persisted the change (didSet wrote back through)
    #expect(defaults.object(forKey: key) as? Bool == !original)
  }
}
