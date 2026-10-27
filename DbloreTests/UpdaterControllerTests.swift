//
//  UpdaterControllerTests.swift
//  DbloreTests
//

import Foundation
import Testing

@testable import Dblore

@MainActor
struct UpdaterControllerTests {

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
    var backgroundChecks = 0
  }

  private func makeController(_ counter: Counter) -> UpdaterController {
    UpdaterController(
      isTestHost: false,
      startAction: { counter.starts += 1 },
      checkAction: { counter.checks += 1 },
      backgroundCheckAction: { counter.backgroundChecks += 1 })
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

  @Test("the delayed start also checks in the background once")
  func testDelayedStartChecksInBackground() async {
    let counter = Counter()
    let gate = Gate()
    let controller = makeController(counter)

    let task = controller.start(sleep: { _ in await gate.wait() })
    #expect(counter.backgroundChecks == 0)

    gate.resume()
    await task?.value
    #expect(counter.backgroundChecks == 1)
  }

  @Test("a user check before the delayed start skips the background check")
  func testUserCheckSkipsBackgroundCheck() async {
    let counter = Counter()
    let gate = Gate()
    let controller = makeController(counter)

    let task = controller.start(sleep: { _ in await gate.wait() })
    controller.checkForUpdates()
    gate.resume()
    await task?.value
    #expect(counter.backgroundChecks == 0)
  }

  @Test("a found update stays available until its session finishes")
  func testAvailableUpdateLifecycle() {
    let controller = makeController(Counter())
    #expect(controller.availableUpdateVersion == nil)

    controller.updateFound(version: "0.9.0")
    #expect(controller.availableUpdateVersion == "0.9.0")

    controller.updateSessionFinished()
    #expect(controller.availableUpdateVersion == nil)
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
