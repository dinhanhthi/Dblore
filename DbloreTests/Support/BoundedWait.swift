import Foundation
import Testing

/// Awaits `operation` for at most `timeout`. On a timeout records an Issue naming `step` and
/// returns nil; the operation's task is cancelled but may keep waiting, so the caller cleans up
/// what it awaits (e.g. cancels that task). Await `Task.result` to keep a thrown error.
/// The operation and the timer race as unstructured tasks: a task group would wait for an
/// operation that ignores cancellation (a continuation, `Task.value`) and hang with it.
func boundedWait<T: Sendable>(
  _ step: String, timeout: Duration = .seconds(30),
  sourceLocation: SourceLocation = #_sourceLocation,
  _ operation: @escaping @Sendable () async -> T
) async -> T? {
  let race = BoundedWaitRace<T>()
  let value = await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
    race.start(continuation)
    let work = Task { race.finish(await operation()) }
    let timer = Task {
      try? await Task.sleep(for: timeout)
      if race.finish(nil) { work.cancel() }
    }
    race.onFinish { timer.cancel() }
  }
  if value == nil {
    Issue.record("\(step) did not complete within \(timeout)", sourceLocation: sourceLocation)
  }
  return value
}

/// Resumes the continuation once, with whichever of the operation and the timer ends first.
nonisolated private final class BoundedWaitRace<T: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<T?, Never>?
  private var finished = false
  private var cleanup: (@Sendable () -> Void)?

  func start(_ continuation: CheckedContinuation<T?, Never>) {
    lock.withLock { self.continuation = continuation }
  }

  /// Runs `cleanup` once the race is over (at once if it already is).
  func onFinish(_ cleanup: @escaping @Sendable () -> Void) {
    let over = lock.withLock {
      if !finished { self.cleanup = cleanup }
      return finished
    }
    if over { cleanup() }
  }

  /// Returns true for the first caller, whose value resumes the waiter.
  @discardableResult
  func finish(_ value: T?) -> Bool {
    let won = lock.withLock { () -> (CheckedContinuation<T?, Never>, (@Sendable () -> Void)?)? in
      guard !finished, let continuation else { return nil }
      finished = true
      defer {
        self.continuation = nil
        cleanup = nil
      }
      return (continuation, cleanup)
    }
    guard let (continuation, cleanup) = won else { return false }
    cleanup?()
    continuation.resume(returning: value)
    return true
  }
}

/// A one-shot signal: `set()` from any context (an event loop, an `onCancel`, a fake's
/// callback) releases every `wait()`, earlier or later. Await it through `boundedWait`.
nonisolated final class FiredFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var fired = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  var isSet: Bool { lock.withLock { fired } }

  func set() {
    let waiting = lock.withLock {
      fired = true
      defer { waiters.removeAll() }
      return waiters
    }
    for waiter in waiting { waiter.resume() }
  }

  /// Returns once `set()` was called.
  func wait() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let done = lock.withLock {
        if !fired { waiters.append(continuation) }
        return fired
      }
      if done { continuation.resume() }
    }
  }
}
