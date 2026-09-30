// MLXEngineTests.swift
// Idle-unload timing and load/cancel behavior of MLXEngine with a fake loader (no real model)

import Foundation
import MLXLMCommon
import Testing

@testable import Dblore

nonisolated private final class FakeModel: MLXLoadedModel, @unchecked Sendable {
  /// When set, generate suspends until cancelled
  let hangs: Bool
  let probe: Probe?
  init(hangs: Bool = false, probe: Probe? = nil) {
    self.hangs = hangs
    self.probe = probe
  }

  func generate(
    messages: [Chat.Message], context: [String: any Sendable]?, parameters: GenerateParameters,
    onChunk: @Sendable (String) -> Void
  ) async throws {
    probe?.enter()
    defer { probe?.leave() }
    onChunk("x")
    if probe != nil { try await Task.sleep(for: .milliseconds(30)) }
    if hangs { try await Task.sleep(for: .seconds(60)) }
  }
}

/// Records the maximum number of overlapping generations
nonisolated private final class Probe: @unchecked Sendable {
  private let lock = NSLock()
  private var current = 0
  private var peak = 0
  private var total = 0
  func enter() {
    lock.lock()
    current += 1
    total += 1
    peak = max(peak, current)
    lock.unlock()
  }
  func leave() {
    lock.lock()
    current -= 1
    lock.unlock()
  }
  var maxConcurrent: Int {
    lock.lock()
    defer { lock.unlock() }
    return peak
  }
  var generations: Int {
    lock.lock()
    defer { lock.unlock() }
    return total
  }
}

/// A non-cancellable gate: `wait()` suspends until `open()` (works if opened first)
nonisolated private final class Gate: @unchecked Sendable {
  private let lock = NSLock()
  private var isOpen = false
  private var continuation: CheckedContinuation<Void, Never>?
  func wait() async {
    await withCheckedContinuation { c in
      lock.lock()
      if isOpen {
        lock.unlock()
        c.resume()
      } else {
        continuation = c
        lock.unlock()
      }
    }
  }
  func open() {
    lock.lock()
    isOpen = true
    let c = continuation
    continuation = nil
    lock.unlock()
    c?.resume()
  }
}

nonisolated private final class Flag: @unchecked Sendable {
  private let lock = NSLock()
  private var set = false
  func raise() {
    lock.lock()
    set = true
    lock.unlock()
  }
  var isRaised: Bool {
    lock.lock()
    defer { lock.unlock() }
    return set
  }
}

nonisolated private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var n = 0
  func bump() {
    lock.lock()
    n += 1
    lock.unlock()
  }
  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return n
  }
}

@Suite("MLXEngine")
struct MLXEngineTests {
  private let dir = URL(fileURLWithPath: "/tmp/none")
  private let params = GenerateParameters(maxTokens: 1, temperature: 0)

  private func makeEngine(
    interval: Duration = .milliseconds(80), hangs: Bool = false, loadDelay: Duration? = nil,
    released: Counter = Counter(), loads: Counter = Counter(), gate: Gate? = nil,
    probe: Probe? = nil
  ) -> MLXEngine {
    MLXEngine(
      idleUnloadInterval: interval,
      loader: { _ in
        loads.bump()
        if let loadDelay { try await Task.sleep(for: loadDelay) }
        if let gate { await gate.wait() }
        return FakeModel(hangs: hangs, probe: probe)
      },
      releaseMemory: { released.bump() })
  }

  private func run(_ engine: MLXEngine, id: String = "a") async throws {
    try await engine.generate(
      modelID: id, directory: dir, messages: [], context: nil, parameters: params,
      onChunk: { _ in })
  }

  /// Polls `condition` until it holds or a generous wall-clock timeout elapses
  private func waitUntil(timeout: Duration = .seconds(10), _ condition: () async -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !(await condition()), ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  @Test("default idle interval is 300 seconds")
  func defaultInterval() {
    #expect(MLXEngine.idleUnloadInterval == .seconds(300))
  }

  @Test("idle unload fires after the interval and releases memory")
  func idleUnloadFires() async throws {
    let released = Counter()
    // Long enough that the loaded check below cannot race the timer under parallel load
    let engine = makeEngine(interval: .seconds(1), released: released)
    try await run(engine)
    #expect(await engine.isLoaded)
    await waitUntil { !(await engine.isLoaded) }
    #expect(!(await engine.isLoaded))
    #expect(released.value == 1)
  }

  @Test("a new request cancels the pending timer and reuses the loaded model")
  func newRequestCancelsTimer() async throws {
    let loads = Counter()
    let interval = Duration.seconds(1)
    let engine = makeEngine(interval: interval, loads: loads)
    try await run(engine)
    try await Task.sleep(for: .milliseconds(600))
    try await run(engine)  // reschedules; the first timer must not unload at ~1s
    let secondDone = ContinuousClock.now
    try await Task.sleep(for: .milliseconds(600))
    // Sleeps never wake early, so the first timer is past due here; the check is only
    // meaningful while the second timer has not yet come due (a late wake skips it)
    if ContinuousClock.now - secondDone < interval {
      #expect(await engine.isLoaded)
    }
    #expect(loads.value == 1)
    await waitUntil { !(await engine.isLoaded) }
    #expect(!(await engine.isLoaded))
  }

  @Test("no unload while a request is generating")
  func noUnloadWhileBusy() async throws {
    let engine = makeEngine(interval: .milliseconds(30), hangs: true)
    let task = Task { try await run(engine) }
    await waitUntil { await engine.isGenerating }
    try await Task.sleep(for: .milliseconds(150))
    #expect(await engine.isLoaded)
    #expect(await engine.unload() == false)
    #expect(await engine.unload(modelID: "a") == false)
    task.cancel()
    _ = try? await task.value
    // timer is rescheduled after the cancelled generation and unloads afterwards
    await waitUntil { !(await engine.isLoaded) }
    #expect(!(await engine.isLoaded))
  }

  @Test("unload(modelID:) drops only the matching resident model")
  func unloadByID() async throws {
    let released = Counter()
    let engine = makeEngine(interval: .seconds(60), released: released)
    try await run(engine)
    #expect(await engine.unload(modelID: "other"))
    #expect(await engine.isLoaded)
    #expect(await engine.unload(modelID: "a"))
    #expect(!(await engine.isLoaded))
    #expect(released.value == 1)
  }

  @Test("cancelling during load releases the busy flag")
  func cancelDuringLoad() async throws {
    let engine = makeEngine(interval: .seconds(60), loadDelay: .seconds(30))
    let task = Task { try await run(engine) }
    await waitUntil { await engine.isGenerating }
    task.cancel()
    _ = try? await task.value
    #expect(!(await engine.isGenerating))
    #expect(!(await engine.isLoaded))
  }

  @Test("stop during load then an immediate new request waits instead of failing busy")
  func stopDuringLoadThenResend() async throws {
    let gate = Gate()
    let loads = Counter()
    let probe = Probe()
    let engine = makeEngine(interval: .seconds(60), loads: loads, gate: gate, probe: probe)
    let first = Task { try await run(engine) }
    await waitUntil { loads.value == 1 }
    first.cancel()
    let secondDone = Flag()
    let second = Task {
      try await run(engine)
      secondDone.raise()
    }
    try await Task.sleep(for: .milliseconds(100))
    #expect(!secondDone.isRaised)  // still waiting for the cancelled load to finish
    gate.open()
    try await second.value
    do {
      try await first.value
      Issue.record("first request should have been cancelled")
    } catch is CancellationError {}
    #expect(probe.generations == 1)
    #expect(probe.maxConcurrent == 1)
    #expect(loads.value == 1)  // the loaded model is kept for the resend
    #expect(!(await engine.isGenerating))
  }

  @Test("a live request still refuses a concurrent one and the flag is not stuck")
  func liveRequestRefusesSecond() async throws {
    let engine = makeEngine(interval: .seconds(60), hangs: true)
    let first = Task { try await run(engine) }
    await waitUntil { await engine.isGenerating }
    do {
      try await run(engine)
      Issue.record("expected busy")
    } catch let error as AIClientError {
      if case .transport(let message) = error {
        #expect(message == "Local model is busy")
      } else {
        Issue.record("wrong error")
      }
    }
    #expect(await engine.isGenerating)
    first.cancel()
    _ = try? await first.value
    #expect(!(await engine.isGenerating))
  }

  @Test("a waiting request that is cancelled leaves the engine usable")
  func cancelledWaiter() async throws {
    let gate = Gate()
    let loads = Counter()
    let engine = makeEngine(interval: .seconds(60), loads: loads, gate: gate)
    let first = Task { try await run(engine) }
    await waitUntil { loads.value == 1 }
    first.cancel()
    let second = Task { try await run(engine) }
    try await Task.sleep(for: .milliseconds(50))
    second.cancel()
    do {
      try await second.value
      Issue.record("waiter should have been cancelled")
    } catch is CancellationError {}
    gate.open()
    _ = try? await first.value
    #expect(!(await engine.isGenerating))
    try await run(engine)
  }

  @Test("unload(modelID:) is refused while that model is loading")
  func unloadRefusedWhileLoading() async throws {
    let gate = Gate()
    let loads = Counter()
    let engine = makeEngine(interval: .seconds(60), loads: loads, gate: gate)
    let task = Task { try await run(engine) }
    await waitUntil { loads.value == 1 }
    #expect(await engine.unload(modelID: "a") == false)
    #expect(await engine.unload(modelID: "other") == true)
    gate.open()
    try await task.value
    #expect(await engine.unload(modelID: "a") == true)
  }

  @Test("a stale idle timer cannot unload after a newer request rescheduled")
  func staleIdleTimer() async throws {
    let engine = makeEngine(interval: .seconds(60))
    try await run(engine)
    let stale = await engine.idleGeneration
    try await run(engine)
    await engine.unloadIdle(generation: stale)
    #expect(await engine.isLoaded)
    await engine.unloadIdle(generation: await engine.idleGeneration)
    #expect(!(await engine.isLoaded))
  }

  @Test("loading phase is reported only when a load is needed")
  func phases() async throws {
    let engine = makeEngine(interval: .seconds(60))
    let first = PhaseLog()
    try await engine.generate(
      modelID: "a", directory: dir, messages: [], context: nil, parameters: params,
      onPhase: { first.add($0) }, onChunk: { _ in })
    #expect(first.values == [.loading, .generating])
    let second = PhaseLog()
    try await engine.generate(
      modelID: "a", directory: dir, messages: [], context: nil, parameters: params,
      onPhase: { second.add($0) }, onChunk: { _ in })
    #expect(second.values == [.generating])
  }
}

nonisolated private final class PhaseLog: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [MLXEnginePhase] = []
  func add(_ p: MLXEnginePhase) {
    lock.lock()
    items.append(p)
    lock.unlock()
  }
  var values: [MLXEnginePhase] {
    lock.lock()
    defer { lock.unlock() }
    return items
  }
}
