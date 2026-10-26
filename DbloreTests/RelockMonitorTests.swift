// RelockMonitorTests.swift
// RelockMonitor: an idle stretch past the timeout relocks once, input resets it, each screen
// lock and sleep signal relocks, and "Never" turns off only the idle relock. Each test injects
// its own LockRegistry, idle reading and notification centers: no test touches
// LockRegistry.shared, the system notification centers or the real idle time.

import AppKit
import Foundation
import Testing

@testable import Dblore

/// The seconds since the last input the monitor reads
@MainActor
private final class IdleClock {
  var seconds: TimeInterval = 0
}

@MainActor
struct RelockMonitorTests {
  private let registry = LockRegistry()
  private let workspace = UUID()
  private let clock = IdleClock()
  private let distributedCenter = NotificationCenter()
  private let workspaceCenter = NotificationCenter()

  /// A monitor over this test's registry with one workspace locked and unlocked in this session
  private func makeMonitor(timeout: LockIdleTimeout = .minutes15) -> RelockMonitor {
    registry.registerWorkspace(workspace)
    registry.grant(.workspace(workspace))
    let clock = clock
    return RelockMonitor(
      registry: registry, idleSeconds: { clock.seconds }, idleTimeout: { timeout },
      distributedCenter: distributedCenter, workspaceCenter: workspaceCenter)
  }

  @Test("Idle past the timeout relocks once, and input starts a new idle stretch")
  func idlePastTimeoutRelocks() {
    let monitor = makeMonitor()
    clock.seconds = 14 * 60
    monitor.pollIdle()
    #expect(!registry.isBlocked(.workspace(workspace)))

    clock.seconds = 15 * 60
    monitor.pollIdle()
    #expect(registry.isBlocked(.workspace(workspace)))
    let generation = registry.generation

    // Still idle on the next poll: no second relock
    clock.seconds = 15 * 60 + 30
    monitor.pollIdle()
    #expect(registry.generation == generation)

    // Input resets the idle reading; the next stretch past the timeout relocks again
    registry.grant(.workspace(workspace))
    clock.seconds = 10
    monitor.pollIdle()
    #expect(!registry.isBlocked(.workspace(workspace)))
    clock.seconds = 16 * 60
    monitor.pollIdle()
    #expect(registry.isBlocked(.workspace(workspace)))
  }

  /// Each screen lock or sleep signal, and whether it comes through the distributed center
  @Test(
    "Each screen lock and sleep signal relocks",
    arguments: [
      (Notification.Name("com.apple.screenIsLocked"), true),
      (NSWorkspace.screensDidSleepNotification, false),
      (NSWorkspace.willSleepNotification, false),
      (NSWorkspace.sessionDidResignActiveNotification, false),
    ])
  func signalRelocks(name: Notification.Name, distributed: Bool) {
    let monitor = makeMonitor()
    (distributed ? distributedCenter : workspaceCenter).post(name: name, object: nil)
    #expect(registry.isBlocked(.workspace(workspace)))
    withExtendedLifetime(monitor) {}
  }

  @Test("Never turns off the idle relock only: a screen lock still relocks")
  func neverKeepsSignals() {
    let monitor = makeMonitor(timeout: .never)
    clock.seconds = 24 * 60 * 60
    monitor.pollIdle()
    #expect(!registry.isBlocked(.workspace(workspace)))

    distributedCenter.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
    #expect(registry.isBlocked(.workspace(workspace)))
    withExtendedLifetime(monitor) {}
  }
}
