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
  private let startAction: () -> Void
  private let checkAction: () -> Void
  private let isTestHost: Bool
  private var startTask: Task<Void, Never>?
  private var didStart = false

  /// The seams (`startAction`, `checkAction`, `isTestHost`) exist so tests never start a real updater or check.
  init(
    isTestHost: Bool = SessionManager.isRunningAsTestHost,
    startAction: (() -> Void)? = nil,
    checkAction: (() -> Void)? = nil
  ) {
    let controller = SPUStandardUpdaterController(
      startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    updaterController = controller
    self.isTestHost = isTestHost
    self.startAction = startAction ?? { controller.startUpdater() }
    self.checkAction = checkAction ?? { controller.checkForUpdates(nil) }
    // Plain init assignment: didSet does not fire, so nothing is written back to Sparkle
    automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates

    controller.updater
      .publisher(for: \.canCheckForUpdates)
      .receive(on: DispatchQueue.main)
      .assign(to: &$canCheckForUpdates)
  }

  /// Schedules the updater start after `delay` so Sparkle's startup work (XPC helper, scheduling) stays off
  /// the launch path. Skipped under XCTest/Swift Testing so the hosted test run never checks for updates.
  /// Idempotent. Returns the scheduled task (nil when skipped or already scheduled/started).
  @discardableResult
  func start(
    after delay: Duration = .seconds(3),
    sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) -> Task<Void, Never>? {
    guard !isTestHost, !didStart, startTask == nil else { return nil }
    let task = Task { [weak self] in
      do { try await sleep(delay) } catch { return }
      guard !Task.isCancelled else { return }
      self?.ensureStarted()
    }
    startTask = task
    return task
  }

  /// Starts the updater now if it has not started yet, cancelling any pending delayed start.
  private func ensureStarted() {
    guard !didStart else { return }
    didStart = true
    startTask?.cancel()
    startTask = nil
    startAction()
  }

  /// Triggers a user-initiated check; Sparkle shows its own standard UI. Starts the updater first if the
  /// delayed start has not fired yet. `canCheckForUpdates` is false until then, so the menu item is disabled
  /// during the first seconds after launch; that is acceptable.
  func checkForUpdates() {
    guard !isTestHost else { return }
    ensureStarted()
    checkAction()
  }
}
