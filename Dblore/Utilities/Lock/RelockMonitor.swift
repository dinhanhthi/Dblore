//
//  RelockMonitor.swift
//  Dblore
//

import AppKit
import CoreGraphics
import Foundation

/// Covers the locked items again (`LockRegistry.relockAll()`) when the screen locks, the
/// displays or the Mac go to sleep, the user session is switched out, or the Mac has had no
/// input for the idle timeout (Settings, "Never" turns off only the idle relock). The open
/// workspaces keep their content keys in memory: a relock only takes back the session's
/// unlocks. Quitting needs nothing here: unlocks live in memory only, so every launch starts
/// locked (`AppDelegate.applicationWillTerminate` still relocks for the record).
@MainActor
final class RelockMonitor {
  static let shared = RelockMonitor(
    registry: .shared,
    idleSeconds: {
      // Any input to any app (keyboard, mouse, trackpad): `kCGAnyInputEventType` (`~0`, not
      // imported into Swift); readable in the sandbox (decision R)
      CGEventSource.secondsSinceLastEventType(
        .combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    },
    idleTimeout: { AppSettings.shared.lockIdleTimeout },
    distributedCenter: DistributedNotificationCenter.default(),
    workspaceCenter: NSWorkspace.shared.notificationCenter)

  /// Posted by the system when the screen locks (no userInfo)
  nonisolated static let screenIsLocked = Notification.Name("com.apple.screenIsLocked")
  /// How often the idle reading is checked: well under the shortest timeout
  private static let pollInterval: TimeInterval = 30

  private let registry: LockRegistry
  private let idleSeconds: () -> TimeInterval
  private let idleTimeout: () -> LockIdleTimeout
  private var tokens: [any NSObjectProtocol] = []
  private var timer: Timer?
  /// Set by an idle relock until input brings the idle reading under the timeout again, so one
  /// idle stretch relocks once
  private var relockedWhileIdle = false

  /// Observes the screen lock on `distributedCenter` and sleep and session switches on
  /// `workspaceCenter`; the idle reading is polled only after `start()`
  init(
    registry: LockRegistry, idleSeconds: @escaping () -> TimeInterval,
    idleTimeout: @escaping () -> LockIdleTimeout, distributedCenter: NotificationCenter,
    workspaceCenter: NotificationCenter
  ) {
    self.registry = registry
    self.idleSeconds = idleSeconds
    self.idleTimeout = idleTimeout
    // Delivered on the main thread; the registry is thread-safe either way
    tokens.append(
      distributedCenter.addObserver(forName: Self.screenIsLocked, object: nil, queue: nil) {
        _ in Self.relock(registry)
      })
    for name in [
      NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification,
      NSWorkspace.sessionDidResignActiveNotification,
    ] {
      tokens.append(
        workspaceCenter.addObserver(forName: name, object: nil, queue: nil) { _ in
          Self.relock(registry)
        })
    }
  }

  /// Starts polling the idle reading (once, at app launch)
  func start() {
    guard timer == nil else { return }
    let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.pollIdle() }
    }
    timer.tolerance = 5
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  /// Relocks once when the idle reading reached the timeout; a reading under it (input came)
  /// arms the next idle relock
  func pollIdle() {
    guard let timeout = idleTimeout().seconds, idleSeconds() >= timeout else {
      relockedWhileIdle = false
      return
    }
    guard !relockedWhileIdle else { return }
    relockedWhileIdle = true
    Self.relock(registry)
  }

  /// Relocks only while something is locked, so an idle Mac without locks posts nothing
  nonisolated private static func relock(_ registry: LockRegistry) {
    guard !registry.lockedIdentities.isEmpty else { return }
    registry.relockAll()
  }
}
