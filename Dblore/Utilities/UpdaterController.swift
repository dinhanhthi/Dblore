//
//  UpdaterController.swift
//  Dblore
//

import Combine
import Sparkle

/// Owns the Sparkle updater (standard Sparkle UI) and publishes the state the menu and Settings bind to.
@MainActor
final class UpdaterController: ObservableObject {
  static let shared = UpdaterController()

  @Published private(set) var canCheckForUpdates = false

  /// Version of the update Sparkle found; the green update buttons show while it is set.
  @Published private(set) var availableUpdateVersion: String?

  /// Mirrors Sparkle's persisted automatic-check preference; `didSet` writes changes back to Sparkle.
  @Published var automaticallyChecksForUpdates: Bool {
    didSet {
      updaterController.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
    }
  }

  private let updaterController: SPUStandardUpdaterController
  /// Sparkle holds its delegates weakly
  private let reminderDelegate: UpdateReminderDelegate
  private let startAction: () -> Void
  private let checkAction: () -> Void
  private let backgroundCheckAction: () -> Void
  private let isTestHost: Bool
  private var startTask: Task<Void, Never>?
  private var didStart = false

  /// The seams (`startAction`, `checkAction`, `backgroundCheckAction`, `isTestHost`) exist so tests
  /// never start a real updater or check.
  init(
    isTestHost: Bool = SessionManager.isRunningAsTestHost,
    startAction: (() -> Void)? = nil,
    checkAction: (() -> Void)? = nil,
    backgroundCheckAction: (() -> Void)? = nil
  ) {
    let reminderDelegate = UpdateReminderDelegate()
    let controller = SPUStandardUpdaterController(
      startingUpdater: false, updaterDelegate: reminderDelegate,
      userDriverDelegate: reminderDelegate)
    updaterController = controller
    self.reminderDelegate = reminderDelegate
    self.isTestHost = isTestHost
    self.startAction = startAction ?? { controller.startUpdater() }
    self.checkAction = checkAction ?? { controller.checkForUpdates(nil) }
    // Sparkle's scheduler checks once a day; a check right after the start also brings the update
    // buttons back after a relaunch. Sparkle's docs call for it only while automatic checks are on.
    self.backgroundCheckAction =
      backgroundCheckAction ?? {
        guard controller.updater.automaticallyChecksForUpdates else { return }
        controller.updater.checkForUpdatesInBackground()
      }
    // Plain init assignment: didSet does not fire, so nothing is written back to Sparkle
    automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates

    controller.updater
      .publisher(for: \.canCheckForUpdates)
      .receive(on: DispatchQueue.main)
      .assign(to: &$canCheckForUpdates)
    reminderDelegate.owner = self
  }

  /// Schedules the updater start after `delay` so Sparkle's startup work (XPC helper, scheduling) stays off
  /// the launch path, then checks in the background. Skipped under XCTest/Swift Testing so the hosted test
  /// run never checks for updates. Idempotent. Returns the scheduled task (nil when skipped or already
  /// scheduled/started).
  @discardableResult
  func start(
    after delay: Duration = .seconds(3),
    sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) -> Task<Void, Never>? {
    guard !isTestHost, !didStart, startTask == nil else { return nil }
    let task = Task { [weak self] in
      do { try await sleep(delay) } catch { return }
      guard !Task.isCancelled, let self else { return }
      ensureStarted()
      backgroundCheckAction()
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

  /// A check found `version`: a user check shows Sparkle's alert, a background check only the update
  /// buttons, and an automatic download installs it on quit.
  func updateFound(version: String) {
    availableUpdateVersion = version
  }

  /// The update was installed, skipped, put off with "Remind Me Later", or failed.
  func updateSessionFinished() {
    availableUpdateVersion = nil
  }
}

/// Sparkle's gentle reminders: a background check that finds an update shows the green update buttons
/// instead of an alert. A click on one calls `checkForUpdates`, which brings Sparkle's alert up (or its
/// "ready to install" alert for an automatically downloaded update).
private final class UpdateReminderDelegate: NSObject, SPUUpdaterDelegate,
  SPUStandardUserDriverDelegate
{
  weak var owner: UpdaterController?

  var supportsGentleScheduledUpdateReminders: Bool { true }

  /// Every check path calls this, also automatic downloads, which never reach the user driver
  func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
    owner?.updateFound(version: item.displayVersionString)
  }

  func standardUserDriverShouldHandleShowingScheduledUpdate(
    _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
  ) -> Bool {
    false
  }

  /// Sparkle logs an error without it once the delegate shows scheduled updates; the buttons already
  /// show from `didFindValidUpdate`.
  func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
  ) {}

  func standardUserDriverWillFinishUpdateSession() {
    owner?.updateSessionFinished()
  }
}
