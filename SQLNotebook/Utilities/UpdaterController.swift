//
//  UpdaterController.swift
//  SQLNotebook
//

import Combine
import Sparkle

/// Owns the Sparkle updater (standard Sparkle UI) and publishes the state the menu and Settings bind to.
@MainActor
final class UpdaterController: ObservableObject {
  static let shared = UpdaterController()

  @Published private(set) var canCheckForUpdates = false

  /// Mirrors Sparkle's persisted automatic-check preference; `didSet` writes changes back to Sparkle.
  @Published var automaticallyChecksForUpdates: Bool {
    didSet {
      updaterController.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
    }
  }

  private let updaterController: SPUStandardUpdaterController

  private init() {
    let controller = SPUStandardUpdaterController(
      startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    updaterController = controller
    // Plain init assignment: didSet does not fire, so nothing is written back to Sparkle
    automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates

    controller.updater
      .publisher(for: \.canCheckForUpdates)
      .receive(on: DispatchQueue.main)
      .assign(to: &$canCheckForUpdates)
  }

  /// Starts the updater; skipped under XCTest/Swift Testing so the hosted test run never checks for updates.
  func start() {
    guard !SessionManager.isRunningAsTestHost else { return }
    updaterController.startUpdater()
  }

  /// Triggers a user-initiated check; Sparkle shows its own standard UI.
  func checkForUpdates() {
    updaterController.checkForUpdates(nil)
  }
}
