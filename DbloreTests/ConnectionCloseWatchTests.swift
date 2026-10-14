// ConnectionCloseWatchTests.swift
// C0 pure pieces: the close watch that fails in-flight work when a connection closes, and the
// session-lost event message.

import Foundation
import NIOCore
import NIOEmbedded
import Testing

@testable import Dblore

/// A continuation that is resumed only at the end of a test, so an operation can hang
/// (ignoring cancellation) without leaking it.
private final class HeldContinuation: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Never>?
  private var released = false

  func wait() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if released {
        lock.unlock()
        continuation.resume()
        return
      }
      self.continuation = continuation
      lock.unlock()
    }
  }

  func release() {
    lock.lock()
    released = true
    let held = continuation
    continuation = nil
    lock.unlock()
    held?.resume()
  }
}

private final class Flag: @unchecked Sendable {
  private let lock = NSLock()
  private var isSet = false

  func set() {
    lock.lock()
    isSet = true
    lock.unlock()
  }

  var value: Bool {
    lock.lock()
    defer { lock.unlock() }
    return isSet
  }
}

@Suite("Connection Close Watch")
struct ConnectionCloseWatchTests {
  @Test("Already closed: throws without running the operation")
  func closedBeforeRun() async {
    let watch = ConnectionCloseWatch()
    watch.close()
    let ran = Flag()
    await #expect(throws: ConnectionClosedError.self) {
      _ = try await watch.run { ran.set() }
    }
    #expect(!ran.value)
  }

  @Test("Closing fails a hung operation promptly, even if it ignores cancellation")
  func closeFailsHungOperation() async {
    let watch = ConnectionCloseWatch()
    let started = HeldContinuation()
    let held = HeldContinuation()
    // Close only once the operation is in flight
    Task {
      await started.wait()
      watch.close()
    }
    // The held operation never returns on its own: only the close can resume the caller
    await #expect(throws: ConnectionClosedError.self) {
      try await watch.run {
        started.release()
        await held.wait()
      }
    }
    held.release()
  }

  @Test("Closing cancels the running operation")
  func closeCancelsOperation() async {
    let watch = ConnectionCloseWatch()
    let cancelled = Flag()
    Task {
      try? await Task.sleep(for: .milliseconds(100))
      watch.close()
    }
    _ = try? await watch.run {
      do {
        try await Task.sleep(for: .seconds(30))
      } catch {
        cancelled.set()
      }
    }
    var waited = 0
    while !cancelled.value && waited < 40 {
      try? await Task.sleep(for: .milliseconds(25))
      waited += 1
    }
    #expect(cancelled.value)
  }

  @Test("Cancelling the caller cancels the operation")
  func callerCancellation() async {
    let watch = ConnectionCloseWatch()
    let cancelled = Flag()
    let caller = Task {
      try await watch.run {
        do {
          try await Task.sleep(for: .seconds(30))
        } catch {
          cancelled.set()
          throw error
        }
      }
    }
    try? await Task.sleep(for: .milliseconds(100))
    caller.cancel()
    _ = try? await caller.value
    #expect(cancelled.value)
  }

  @Test("A completed close future closes the watch")
  func closeFutureClosesWatch() async {
    let loop = EmbeddedEventLoop()
    let promise = loop.makePromise(of: Void.self)
    let watch = ConnectionCloseWatch(closeFuture: promise.futureResult)
    #expect(!watch.isClosed)
    promise.succeed(())
    #expect(watch.isClosed)
    await #expect(throws: ConnectionClosedError.self) {
      _ = try await watch.run { 1 }
    }
  }
}

@Suite("Session Lost Event")
struct SessionLostEventTests {
  private func pending(_ count: Int) -> [StatementSummary] {
    Array(repeating: StatementSummary.earlierChanges(), count: count)
  }

  @Test("Pending app transaction: its changes were rolled back by the server")
  func pendingRolledBack() {
    let one = SessionLostEvent(state: .appTx(pending: pending(1)), userTxOpen: false, epoch: 1)
    #expect(one.pendingCount == 1)
    #expect(one.message.contains("1 pending change was rolled back by the server."))
    let three = SessionLostEvent(
      state: .aborted(reason: "x", pending: pending(3)), userTxOpen: false, epoch: 1)
    #expect(three.pendingCount == 3)
    #expect(three.message.contains("3 pending changes were rolled back by the server."))
    let rollingBack = SessionLostEvent(
      state: .ending(kind: .rollback, pending: pending(2)), userTxOpen: false, epoch: 1)
    #expect(rollingBack.message.contains("2 pending changes were rolled back by the server."))
    #expect(!rollingBack.commitOutcomeUnknown)
  }

  @Test("Lost during Commit: the outcome is unknown")
  func commitUnknown() {
    let event = SessionLostEvent(
      state: .ending(kind: .commit, pending: pending(2)), userTxOpen: false, epoch: 1)
    #expect(event.commitOutcomeUnknown)
    #expect(event.message.contains("unknown whether the 2 pending changes were committed"))
    #expect(!event.message.contains("rolled back"))
  }

  @Test("Open user transaction: rolled back by the server")
  func userTransaction() {
    let event = SessionLostEvent(state: .idle, userTxOpen: true, epoch: 1)
    #expect(event.userTransactionLost)
    #expect(event.message.contains("Your open transaction was rolled back by the server."))
  }
}
