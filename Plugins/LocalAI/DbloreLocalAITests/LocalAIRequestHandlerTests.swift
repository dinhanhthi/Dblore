// LocalAIRequestHandlerTests.swift
// The protocol v1 request-to-event mapping of generate, cancel and unload, driven through
// LocalAIRequestHandler with a fake loaded model (no real weights, no Metal).

import Foundation
import MLXLMCommon
import Testing

private typealias Event = LocalAIProtocol.Event

/// Every event the handler emitted, in order
nonisolated private final class EventLog: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [Event] = []

  func add(_ event: Event) {
    lock.lock()
    events.append(event)
    lock.unlock()
  }

  func kinds(_ id: String) -> [Event.Kind] {
    lock.lock()
    defer { lock.unlock() }
    return events.filter { $0.id == id }.map(\.kind)
  }

  /// True once `id` got its terminal event
  func isFinished(_ id: String) -> Bool {
    kinds(id).contains {
      switch $0 {
      case .done, .cancelled, .unloaded, .error: true
      default: false
      }
    }
  }
}

/// What the engine handed the model, flattened for comparison
nonisolated private struct ModelCall: Equatable, Sendable {
  let messages: [String]
  let maxTokens: Int?
  let temperature: Float
  let enableThinking: Bool?
}

nonisolated private struct FakeFailure: LocalizedError {
  let errorDescription: String?
}

nonisolated private enum Script: Sendable {
  case chunks([String])
  case loadFails(String)
  case failsAfter(chunk: String, error: String)
  /// Streams one chunk, then waits for cancellation and returns without throwing, as the real
  /// model does when its task is cancelled mid-stream
  case streamsUntilCancelled
}

nonisolated private final class FakeModel: MLXLoadedModel, @unchecked Sendable {
  let script: Script
  private let lock = NSLock()
  private var recorded: ModelCall?

  init(_ script: Script) {
    self.script = script
  }

  var call: ModelCall? {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func generate(
    messages: [Chat.Message], context: [String: any Sendable]?, parameters: GenerateParameters,
    onChunk: @Sendable (String) -> Void
  ) async throws {
    let call = ModelCall(
      messages: messages.map { "\($0.role.rawValue):\($0.content)" },
      maxTokens: parameters.maxTokens, temperature: parameters.temperature,
      enableThinking: context?["enable_thinking"] as? Bool)
    lock.withLock { recorded = call }
    switch script {
    case .chunks(let chunks): chunks.forEach(onChunk)
    case .loadFails: break
    case .failsAfter(let chunk, let error):
      onChunk(chunk)
      throw FakeFailure(errorDescription: error)
    case .streamsUntilCancelled:
      onChunk("x")
      while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
    }
  }
}

nonisolated struct GenerateCase: Sendable, CustomTestStringConvertible {
  fileprivate let script: Script
  fileprivate let expected: [Event.Kind]
  let testDescription: String
  /// The request's system prompt; an empty one sends no system message
  fileprivate var system = "Be brief"

  static let all = [
    GenerateCase(
      script: .chunks(["Hel", "lo"]),
      expected: [.loading, .loaded, .text(chunk: "Hel"), .text(chunk: "lo"), .done],
      testDescription: "streams text, then done"),
    GenerateCase(
      script: .loadFails("no model_type"),
      expected: [.loading, .error(code: .load, message: "no model_type")],
      testDescription: "a load failure ends with load"),
    GenerateCase(
      script: .failsAfter(chunk: "Hel", error: "out of memory"),
      expected: [
        .loading, .loaded, .text(chunk: "Hel"), .error(code: .generate, message: "out of memory"),
      ],
      testDescription: "a generation failure ends with generate"),
    GenerateCase(
      script: .chunks(["ok"]), expected: [.loading, .loaded, .text(chunk: "ok"), .done],
      testDescription: "an empty system prompt sends no system message", system: ""),
  ]
}

@Suite("LocalAIRequestHandler")
struct LocalAIRequestHandlerTests {
  private func request(system: String = "Be brief") -> LocalAIProtocol.Request.Generate {
    .init(
      modelID: "qwen3-test", modelPath: "/tmp/none", system: system,
      messages: [.init(role: .user, text: "q1"), .init(role: .assistant, text: "a1")],
      maxTokens: 7, temperature: 0, context: .init(enableThinking: false))
  }

  private func makeHandler(_ model: FakeModel) -> (LocalAIRequestHandler, MLXEngine) {
    let engine = MLXEngine(
      idleUnloadInterval: .seconds(60),
      loader: { _ in
        if case .loadFails(let message) = model.script {
          throw FakeFailure(errorDescription: message)
        }
        return model
      },
      releaseMemory: {}, setCacheLimit: { _ in })
    return (LocalAIRequestHandler(engine: engine), engine)
  }

  /// Polls `condition` until it holds or a generous wall-clock timeout elapses
  private func waitUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  @Test(
    "generate maps the request and ends with exactly one terminal event",
    arguments: GenerateCase.all)
  func generate(_ row: GenerateCase) async {
    let log = EventLog()
    let model = FakeModel(row.script)
    let (handler, _) = makeHandler(model)
    handler.generate(request(system: row.system), id: "g", emit: log.add)
    await waitUntil { log.isFinished("g") }
    #expect(log.kinds("g") == row.expected)
    // The request reaches the model as the app's on-device client mapped it in-process
    let reachedModel = row.expected.contains(.loaded)
    let system = row.system.isEmpty ? [] : ["system:\(row.system)"]
    #expect(
      model.call
        == (reachedModel
          ? ModelCall(
            messages: system + ["user:q1", "assistant:a1"], maxTokens: 7, temperature: 0,
            enableThinking: false)
          : nil))
  }

  @Test("cancel ends a running generate with cancelled and answers only an unknown target")
  func cancel() async {
    let log = EventLog()
    let (handler, _) = makeHandler(FakeModel(.streamsUntilCancelled))
    handler.generate(request(), id: "g", emit: log.add)
    await waitUntil { log.kinds("g").contains(.text(chunk: "x")) }
    handler.cancel(target: "g", id: "c1", emit: log.add)
    await waitUntil { log.isFinished("g") }
    #expect(log.kinds("g") == [.loading, .loaded, .text(chunk: "x"), .cancelled])
    #expect(log.kinds("c1").isEmpty)
    // "g" has ended, so it is no longer a known target
    handler.cancel(target: "g", id: "c2", emit: log.add)
    #expect(log.kinds("c2") == [.error(code: .invalid, message: "unknown request")])
  }

  @Test("while a generate runs, a second one is busy and unload is refused; then unload frees it")
  func unloadWhileGenerating() async {
    let log = EventLog()
    let (handler, engine) = makeHandler(FakeModel(.streamsUntilCancelled))
    handler.generate(request(), id: "g1", emit: log.add)
    await waitUntil { log.kinds("g1").contains(.text(chunk: "x")) }
    handler.generate(request(), id: "g2", emit: log.add)
    handler.unload(modelID: "qwen3-test", id: "u1", emit: log.add)
    handler.unload(modelID: nil, id: "u2", emit: log.add)
    await waitUntil { ["g2", "u1", "u2"].allSatisfy(log.isFinished) }
    #expect(log.kinds("g2") == [.error(code: .busy, message: "Local model is busy")])
    #expect(log.kinds("u1") == [.unloaded(ok: false)])
    #expect(log.kinds("u2") == [.unloaded(ok: false)])
    handler.cancel(target: "g1", id: "c", emit: log.add)
    await waitUntil { log.isFinished("g1") }
    handler.unload(modelID: "qwen3-test", id: "u3", emit: log.add)
    await waitUntil { log.isFinished("u3") }
    #expect(log.kinds("u3") == [.unloaded(ok: true)])
    #expect(!(await engine.isLoaded))
  }
}
