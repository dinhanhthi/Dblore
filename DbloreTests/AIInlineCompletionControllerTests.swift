// AIInlineCompletionControllerTests.swift
// Tests for the ghost text controller: debounce, cancellation, stale replies and the access gate

import Foundation
import Testing

@testable import Dblore

/// Records requests; replies at once with `immediate`, else holds each stream open until `reply`
nonisolated private final class FakeInlineClient: AIChatClient, @unchecked Sendable {
  private let lock = NSLock()
  private let immediate: String?
  private var captured: [AIChatRequest] = []
  private var continuations: [AsyncThrowingStream<AIStreamEvent, Error>.Continuation] = []
  private var cancelledCount = 0

  init(immediate: String? = nil) { self.immediate = immediate }

  var requests: [AIChatRequest] {
    lock.lock()
    defer { lock.unlock() }
    return captured
  }

  /// Streams ended by the consumer's cancellation
  var cancelled: Int {
    lock.lock()
    defer { lock.unlock() }
    return cancelledCount
  }

  func stream(_ request: AIChatRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
    let (stream, continuation) = AsyncThrowingStream.makeStream(of: AIStreamEvent.self)
    continuation.onTermination = { [weak self] termination in
      guard case .cancelled = termination, let self else { return }
      self.lock.lock()
      self.cancelledCount += 1
      self.lock.unlock()
    }
    lock.lock()
    captured.append(request)
    continuations.append(continuation)
    lock.unlock()
    if let immediate {
      continuation.yield(.text(immediate))
      continuation.finish()
    }
    return stream
  }

  /// Ends the stream of request `index` with `text`
  func reply(_ text: String, at index: Int) {
    lock.lock()
    let continuation = continuations[index]
    lock.unlock()
    continuation.yield(.text(text))
    continuation.finish()
  }

  func listModels() async throws -> [String] { [] }
}

/// A clock that only moves when the test says so
@MainActor private final class FakeSleeper {
  private(set) var requested: [Duration] = []
  private var waiters: [CheckedContinuation<Void, Never>] = []

  var pending: Int { waiters.count }

  func sleep(_ duration: Duration) async {
    requested.append(duration)
    await withCheckedContinuation { waiters.append($0) }
  }

  /// Waits for `count` pending sleeps (the controller's task starts on a later turn), then
  /// ends them all
  func advance(after count: Int = 1) async throws {
    try #require(await waitUntil { self.pending == count })
    let pending = waiters
    waiters = []
    pending.forEach { $0.resume() }
  }
}

/// Holds an async step open until the test resumes it
@MainActor private final class Gate {
  private var continuation: CheckedContinuation<Void, Never>?

  var isWaiting: Bool { continuation != nil }

  func wait() async { await withCheckedContinuation { continuation = $0 } }

  func open() {
    continuation?.resume()
    continuation = nil
  }
}

/// Waits up to about 2 seconds for `condition`: tasks and the request hop executors on their way
@MainActor private func waitUntil(_ condition: () -> Bool) async -> Bool {
  for _ in 0..<2_000 where !condition() { try? await Task.sleep(for: .milliseconds(1)) }
  return condition()
}

@Suite("AI Inline Completion Controller")
@MainActor
struct AIInlineCompletionControllerTests {
  private static let text = "SELECT * FROM "
  private static let caret = text.utf16.count

  /// The controller with its fakes and what it read
  @MainActor private final class Harness {
    var config = AIConfiguration(
      activeProvider: .ollama,
      configs: [.ollama: AIProviderConfig(baseURL: "http://127.0.0.1:11434/v1", model: "m1")],
      inlineEnabled: true)
    var allowed = true
    var isReadOnlySource = false
    var hasClient = true
    var keyRevision = 0
    var clientBuilds = 0
    var schemaCalls: [String] = []
    let sleeper = FakeSleeper()
    let client: FakeInlineClient
    private(set) var controller: AIInlineCompletionController!

    init(
      client: FakeInlineClient = FakeInlineClient(immediate: "orders"),
      registry: AIInlineCompletionRegistry = .shared
    ) {
      self.client = client
      let controller = AIInlineCompletionController(
        configuration: { self.config },
        makeClient: { _ in
          self.clientBuilds += 1
          return self.hasClient ? self.client : nil
        },
        keyRevision: { self.keyRevision },
        sleep: { await self.sleeper.sleep($0) }, registry: registry)
      controller.isAllowed = { self.allowed }
      controller.source = { (.postgresql, self.isReadOnlySource) }
      controller.schema = { prefix in
        self.schemaCalls.append(prefix)
        return "public.orders(id int4 PK)"
      }
      self.controller = controller
    }

    /// Types `text`, ends the typing pause and waits for the request to end
    func typeAndPause(
      _ text: String = AIInlineCompletionControllerTests.text, caret: Int? = nil
    ) async throws {
      controller.textDidChange(text: text, caret: caret ?? text.utf16.count)
      guard let task = controller.task else { return }
      try await sleeper.advance()
      await task.value
    }
  }

  // MARK: - Debounce

  @Test("a request goes out only after the typing pause")
  func debounces() async throws {
    let harness = Harness()
    harness.controller.textDidChange(text: Self.text, caret: Self.caret)
    try #require(await waitUntil { harness.sleeper.pending == 1 })
    #expect(harness.sleeper.requested == [.milliseconds(400)])
    #expect(harness.client.requests.isEmpty)

    try await harness.sleeper.advance()
    await harness.controller.task?.value
    let request = try #require(harness.client.requests.first)
    #expect(harness.client.requests.count == 1)
    #expect(request.model == "m1")
    #expect(request.maxTokens == AIInlineCompletion.maxTokens)
    #expect(request.system.contains("public.orders(id int4 PK)"))
    #expect(harness.schemaCalls == [Self.text])
    #expect(
      harness.controller.suggestion
        == AIInlineCompletionController.Suggestion(text: "orders", caret: Self.caret, version: 1))
  }

  @Test("a keystroke during the pause starts it again; one request for the last text")
  func keystrokeResetsDebounce() async throws {
    let harness = Harness()
    harness.controller.textDidChange(text: "SELECT * FR", caret: 11)
    harness.controller.textDidChange(text: Self.text, caret: Self.caret)
    let first = harness.controller.task
    try await harness.sleeper.advance(after: 2)
    await first?.value
    await harness.controller.task?.value
    let request = try #require(harness.client.requests.first)
    #expect(harness.client.requests.count == 1)
    #expect(
      request.messages.first?.text.contains("<before_caret>\(Self.text)</before_caret>") == true)
  }

  @Test("the pause has a floor")
  func debounceFloor() async throws {
    let harness = Harness()
    harness.config.inlineDebounceMs = 10
    harness.controller.textDidChange(text: Self.text, caret: Self.caret)
    try #require(await waitUntil { harness.sleeper.pending == 1 })
    #expect(
      harness.sleeper.requested == [.milliseconds(AIInlineCompletionController.minDebounceMs)])
  }

  // MARK: - Cancellation and stale replies

  @Test("a keystroke cancels the request in flight and drops its reply")
  func keystrokeCancelsInFlight() async throws {
    let harness = Harness(client: FakeInlineClient())
    harness.controller.textDidChange(text: Self.text, caret: Self.caret)
    try await harness.sleeper.advance()
    try #require(await waitUntil { harness.client.requests.count == 1 })
    let inFlight = harness.controller.task

    harness.controller.textDidChange(text: Self.text + "o", caret: Self.caret + 1)
    await inFlight?.value
    #expect(harness.client.cancelled == 1)
    harness.client.reply("orders", at: 0)
    #expect(harness.controller.suggestion == nil)
    #expect(await waitUntil { harness.sleeper.requested.count == 2 })
  }

  @Test("a reply that arrives after the text changed is dropped; the next one shows")
  func staleReplyDropped() async throws {
    let harness = Harness(client: FakeInlineClient())
    harness.controller.textDidChange(text: Self.text, caret: Self.caret)
    try await harness.sleeper.advance()
    try #require(await waitUntil { harness.client.requests.count == 1 })
    let first = harness.controller.task

    harness.client.reply("orders", at: 0)
    harness.controller.textDidChange(text: Self.text + "o", caret: Self.caret + 1)
    await first?.value
    #expect(harness.controller.suggestion == nil)

    try await harness.sleeper.advance()
    try #require(await waitUntil { harness.client.requests.count == 2 })
    harness.client.reply("rders", at: 1)
    await harness.controller.task?.value
    #expect(
      harness.controller.suggestion
        == AIInlineCompletionController.Suggestion(
          text: "rders", caret: Self.caret + 1, version: 2))
  }

  @Test("moving the caret clears the suggestion and cancels the pending request")
  func selectionChangeCancels() async throws {
    let harness = Harness()
    try await harness.typeAndPause()
    #expect(harness.controller.suggestion != nil)
    harness.controller.selectionDidChange(caret: 3)
    #expect(harness.controller.suggestion == nil)

    harness.controller.textDidChange(text: Self.text, caret: Self.caret)
    let pending = harness.controller.task
    try #require(await waitUntil { harness.sleeper.pending == 1 })
    harness.controller.selectionDidChange(caret: 2)
    try await harness.sleeper.advance()
    await pending?.value
    #expect(harness.client.requests.count == 1)
  }

  @Test("a selection change at the same caret (posted with each keystroke) changes nothing")
  func sameCaretSelectionIgnored() async throws {
    let harness = Harness()
    harness.controller.textDidChange(text: Self.text, caret: Self.caret)
    harness.controller.selectionDidChange(caret: Self.caret)
    try await harness.sleeper.advance()
    await harness.controller.task?.value
    #expect(harness.controller.suggestion?.text == "orders")
    harness.controller.selectionDidChange(caret: Self.caret)
    #expect(harness.controller.suggestion?.text == "orders")
  }

  @Test("focus loss clears the suggestion and cancels the request in flight")
  func focusLossCancels() async throws {
    let harness = Harness(client: FakeInlineClient())
    harness.controller.textDidChange(text: Self.text, caret: Self.caret)
    try await harness.sleeper.advance()
    try #require(await waitUntil { harness.client.requests.count == 1 })
    let inFlight = harness.controller.task

    harness.controller.focusLost()
    await inFlight?.value
    #expect(harness.client.cancelled == 1)
    #expect(harness.controller.suggestion == nil)
  }

  @Test("an on-device request the user asks for cancels the on-device ghost request in flight")
  func foregroundOnDeviceRequestCancels() async throws {
    let onDevice = AIConfiguration(
      activeProvider: .localMLX,
      configs: [.localMLX: AIProviderConfig(baseURL: "", model: "qwen3.5-4b")],
      runsQueries: false, inlineEnabled: true)
    // A registry of its own: on-device requests of tests running alongside never cancel this one
    let registry = AIInlineCompletionRegistry()
    let harness = Harness(client: FakeInlineClient(), registry: registry)
    harness.config = onDevice
    harness.controller.textDidChange(text: Self.text, caret: Self.caret)
    try await harness.sleeper.advance()
    try #require(await waitUntil { harness.client.requests.count == 1 })
    let inFlight = harness.controller.task

    let settings = AISettings(
      defaults: try #require(UserDefaults(suiteName: "AIInlineForeground-\(UUID().uuidString)")),
      keyStore: InMemoryAIKeyStore())
    settings.configuration = onDevice
    let assistant = AIAssistantViewModel(
      settings: settings, makeClient: { _, _, _ in FakeInlineClient(immediate: "ok") },
      inlineCompletions: registry)
    assistant.draft = "Review this query"
    assistant.send()
    // Without the cancel the held stream would never end
    try #require(await waitUntil { harness.client.cancelled == 1 })
    await inFlight?.value
    #expect(harness.controller.suggestion == nil)
    assistant.stop()
  }

  // MARK: - Settings and gate

  @Test("disabled or without a target: no pause, no request, no schema")
  func disabledOrNoTarget() async throws {
    let disabled = Harness()
    disabled.config.inlineEnabled = false
    try await disabled.typeAndPause()

    let noTarget = Harness()
    noTarget.config.activeProvider = nil
    try await noTarget.typeAndPause()

    for harness in [disabled, noTarget] {
      #expect(harness.sleeper.requested.isEmpty)
      #expect(harness.controller.task == nil)
      #expect(harness.client.requests.isEmpty)
      #expect(harness.schemaCalls.isEmpty)
      #expect(harness.controller.suggestion == nil)
    }
  }

  @Test("access not allowed (denied or needs approval): no request and no schema")
  func gateNotAllowed() async throws {
    let harness = Harness()
    harness.allowed = false
    try await harness.typeAndPause()
    #expect(harness.client.requests.isEmpty)
    #expect(harness.schemaCalls.isEmpty)
    #expect(harness.controller.suggestion == nil)
  }

  @Test("the gate is read for every request")
  func gateReadPerRequest() async throws {
    let harness = Harness()
    try await harness.typeAndPause()
    harness.allowed = false
    try await harness.typeAndPause(Self.text + "o")
    #expect(harness.client.requests.count == 1)
    #expect(harness.controller.suggestion == nil)
  }

  @Test("a read-only source or an unconfigured provider sends nothing")
  func readOnlySourceOrNoClient() async throws {
    let readOnly = Harness()
    readOnly.isReadOnlySource = true
    try await readOnly.typeAndPause()

    let noClient = Harness()
    noClient.hasClient = false
    try await noClient.typeAndPause()

    for harness in [readOnly, noClient] {
      #expect(harness.client.requests.isEmpty)
      #expect(harness.schemaCalls.isEmpty)
    }
  }

  @Test("access revoked while the reply streams: nothing shows")
  func gateReadAfterReply() async throws {
    let harness = Harness(client: FakeInlineClient())
    harness.controller.textDidChange(text: Self.text, caret: Self.caret)
    try await harness.sleeper.advance()
    try #require(await waitUntil { harness.client.requests.count == 1 })
    harness.allowed = false
    harness.client.reply("orders", at: 0)
    await harness.controller.task?.value
    #expect(harness.controller.suggestion == nil)
  }

  @Test("text after the caret on its line: no request and no schema")
  func midLineSendsNothing() async throws {
    let harness = Harness()
    try await harness.typeAndPause("SELECT  * FROM orders", caret: 7)
    #expect(harness.client.requests.isEmpty)
    #expect(harness.schemaCalls.isEmpty)
    #expect(harness.controller.suggestion == nil)
  }

  @Test("a multi-line reply keeps only the lines that go over blank lines below the caret")
  func multiLineCutToBlankLines() async throws {
    let reply = "orders\nWHERE id = 1"
    let atEnd = Harness(client: FakeInlineClient(immediate: reply))
    try await atEnd.typeAndPause()
    #expect(atEnd.controller.suggestion?.text == "orders")
    #expect(atEnd.client.requests.first?.system.contains("One short line only.") == true)

    let blankBelow = Harness(client: FakeInlineClient(immediate: reply))
    try await blankBelow.typeAndPause(Self.text + "\n", caret: Self.caret)
    #expect(blankBelow.controller.suggestion?.text == reply)
  }

  // MARK: - Schema and client

  @Test("the schema is awaited; a keystroke while it is built sends nothing")
  func schemaAwaitedAndCancelled() async throws {
    let harness = Harness()
    let gate = Gate()
    harness.controller.schema = { _ in
      await gate.wait()
      return "public.orders(id int4 PK)"
    }
    harness.controller.textDidChange(text: Self.text, caret: Self.caret)
    let first = harness.controller.task
    try await harness.sleeper.advance()
    try #require(await waitUntil { gate.isWaiting })
    harness.controller.textDidChange(text: Self.text + "o", caret: Self.caret + 1)
    gate.open()
    await first?.value
    #expect(harness.client.requests.isEmpty)

    try await harness.sleeper.advance()
    try #require(await waitUntil { gate.isWaiting })
    gate.open()
    await harness.controller.task?.value
    #expect(harness.client.requests.first?.system.contains("public.orders(id int4 PK)") == true)
  }

  @Test("the client is rebuilt only when the provider settings or an API key change")
  func clientCached() async throws {
    let harness = Harness()
    try await harness.typeAndPause()
    try await harness.typeAndPause(Self.text + "o")
    #expect(harness.clientBuilds == 1)

    harness.keyRevision += 1
    try await harness.typeAndPause()
    #expect(harness.clientBuilds == 2)

    harness.config.configs[.ollama]?.model = "m2"
    try await harness.typeAndPause(Self.text + "o")
    #expect(harness.clientBuilds == 3)
    #expect(harness.client.requests.count == 4)
  }

  @Test("a missing client is never kept")
  func missingClientNotCached() async throws {
    let harness = Harness()
    harness.hasClient = false
    try await harness.typeAndPause()
    harness.hasClient = true
    try await harness.typeAndPause(Self.text + "o")
    #expect(harness.clientBuilds == 2)
    #expect(harness.client.requests.count == 1)
  }

  @Test("one huge delta is cut to the reply budget before it is kept")
  func replyCappedPerDelta() async throws {
    let (stream, continuation) = AsyncThrowingStream.makeStream(of: AIStreamEvent.self)
    continuation.yield(.text("ab"))
    continuation.yield(.text(String(repeating: "x", count: 10_000_000)))
    continuation.yield(.text("never"))
    continuation.finish()
    let reply = try await AIInlineCompletionController.collect(stream)
    #expect(reply.utf8.count == AIInlineCompletionController.maxReplyBytes)
    #expect(reply.hasPrefix("abx") && !reply.contains("never"))
  }

  @Test("enabled only with the setting on and a provider and model")
  func isEnabled() {
    let harness = Harness()
    #expect(harness.controller.isEnabled)
    harness.config.activeProvider = nil
    #expect(!harness.controller.isEnabled)
    harness.config.activeProvider = .ollama
    harness.config.inlineEnabled = false
    #expect(!harness.controller.isEnabled)
  }

  // MARK: - Accept and dismiss

  @Test("accept returns the suggestion and clears it")
  func acceptClears() async throws {
    let harness = Harness()
    try await harness.typeAndPause()
    #expect(harness.controller.accept() == "orders")
    #expect(harness.controller.suggestion == nil)
    #expect(harness.controller.accept() == nil)
  }

  @Test("dismiss clears the suggestion")
  func dismissClears() async throws {
    let harness = Harness()
    try await harness.typeAndPause()
    harness.controller.dismiss()
    #expect(harness.controller.suggestion == nil)
  }
}
