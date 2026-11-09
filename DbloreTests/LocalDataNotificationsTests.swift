// LocalDataNotificationsTests.swift
// A local-data change posted off the main thread never waits for the main thread.

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("Local data notifications")
struct LocalDataNotificationsTests {
  @Test("an off-main post returns while the main thread is busy", .timeLimit(.minutes(1)))
  func offMainPostDoesNotWaitForMain() async {
    // Other suites record every local-data post while they hold the gate
    await LocalDataNotificationGate.shared.acquire()
    defer { LocalDataNotificationGate.shared.release() }
    let observer = LocalDataChangeObserver()
    let seen = DeliveryBox()
    observer.start { _ in seen.onMain = Thread.isMainThread }
    #expect(postOffMainWhileBusy() == .success)
    // Once the main thread is free, the observer still runs there
    for _ in 0..<200 where seen.onMain == nil {
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(seen.onMain == true)
    withExtendedLifetime(observer) {}
  }

  /// Posts from another thread while the main thread waits, as a long main-thread task would
  private func postOffMainWhileBusy() -> DispatchTimeoutResult {
    let posted = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      LocalDataNotifications.post(.logs)
      posted.signal()
    }
    return posted.wait(timeout: .now() + 2)
  }
}

/// Written by the observer, read by the test on the main thread
private final class DeliveryBox: @unchecked Sendable {
  var onMain: Bool?
}
