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

  /// Manually resumable sleep: `start` suspends until `resume()` is called.
  private final class Gate: @unchecked Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    init() { (stream, continuation) = AsyncStream<Void>.makeStream() }
    func wait() async {
      for await _ in stream { return }
    }
    func resume() { continuation.yield() }
  }

  private final class Counter: @unchecked Sendable {
    var starts = 0
    var checks = 0
  }

  private func makeController(_ counter: Counter) -> UpdaterController {
    UpdaterController(
      isTestHost: false,
      startAction: { counter.starts += 1 },
      checkAction: { counter.checks += 1 })
  }

  @Test("start schedules startUpdater after the delay, not synchronously")
  func testStartIsDelayed() async {
    let counter = Counter()
    let gate = Gate()
    let controller = makeController(counter)

    let task = controller.start(after: .seconds(3), sleep: { _ in await gate.wait() })
    #expect(counter.starts == 0)

    gate.resume()
    await task?.value
    #expect(counter.starts == 1)
  }

  @Test("start twice starts once")
  func testStartTwiceStartsOnce() async {
    let counter = Counter()
    let gate = Gate()
    let controller = makeController(counter)

    let first = controller.start(sleep: { _ in await gate.wait() })
    let second = controller.start(sleep: { _ in await gate.wait() })
    #expect(second == nil)

    gate.resume()
    await first?.value
    #expect(counter.starts == 1)
  }

  @Test("checkForUpdates before the delayed start starts immediately")
  func testCheckBeforeDelayedStart() async {
    let counter = Counter()
    let gate = Gate()
    let controller = makeController(counter)

    let task = controller.start(sleep: { _ in await gate.wait() })
    controller.checkForUpdates()
    #expect(counter.starts == 1)
    #expect(counter.checks == 1)

    gate.resume()
    await task?.value
    #expect(counter.starts == 1)
  }

  @Test("start is skipped under the test host guard")
  func testStartSkippedInTestHost() {
    let counter = Counter()
    let controller = UpdaterController(isTestHost: true, startAction: { counter.starts += 1 })
    #expect(controller.start(sleep: { _ in }) == nil)
    #expect(counter.starts == 0)
  }

  @Test("checkForUpdates is a no-op under the test host guard")
  func testCheckSkippedInTestHost() {
    let counter = Counter()
    let controller = UpdaterController(
      isTestHost: true,
      startAction: { counter.starts += 1 },
      checkAction: { counter.checks += 1 })
    controller.checkForUpdates()
    #expect(counter.starts == 0)
    #expect(counter.checks == 0)
  }

  @Test("a controller released before the delay elapses never starts the updater")
  func testReleasedBeforeDelayNeverStarts() async {
    let counter = Counter()
    let gate = Gate()
    var task: Task<Void, Never>?
    do {
      let controller = makeController(counter)
      task = controller.start(sleep: { _ in await gate.wait() })
    }
    gate.resume()
    await task?.value
    #expect(counter.starts == 0)
  }
}
