// LocalAIRequestHandler.swift
// Serves the protocol v1 requests that use the engine: generate, cancel and unload. They answer
// later, from a Task, through the request's own emit closure.

import Foundation
import MLXLMCommon

/// Runs each `generate` in its own Task, kept by request id until it ends, so the engine's busy
/// and wait-behind-a-cancelled-request rules apply per request unchanged.
nonisolated final class LocalAIRequestHandler: @unchecked Sendable {
  typealias Event = LocalAIProtocol.Event
  typealias Generate = LocalAIProtocol.Request.Generate
  typealias Emit = @Sendable (Event) -> Void

  private let engine: MLXEngine
  private let lock = NSLock()
  /// Running generate requests by id, guarded by `lock`; each Task removes itself when it ends
  private var running: [String: Task<Void, Never>] = [:]

  init(engine: MLXEngine) {
    self.engine = engine
  }

  /// Emits `loading` (only when the model must be loaded), `loaded`, the `text` chunks, then
  /// exactly one terminal event: `done`, `cancelled`, or `error` (`busy`, `load` or `generate`).
  /// An id that is already running is refused with `invalid`, so the table keeps one Task per id.
  func generate(_ request: Generate, id: String, emit: @escaping Emit) {
    lock.lock()
    let isDuplicate = running[id] != nil
    if !isDuplicate {
      // Inserted under the lock the Task takes to remove itself, so a Task that ends at once
      // can't leave a stale entry
      running[id] = Task { [engine] in
        let terminal = await Self.serve(request, id: id, engine: engine, emit: emit)
        self.finished(id)
        emit(Event(id: id, kind: terminal))
      }
    }
    lock.unlock()
    if isDuplicate { emit(invalid("duplicate request id", id: id)) }
  }

  /// Cancels the running generate `target`, which then ends with its own `cancelled` event. The
  /// cancel itself gets no event then: it is the one request that may go unanswered, so the app
  /// never waits for one. Only a target that is not running (unknown or already ended) is
  /// answered, with `invalid` under the cancel's id.
  func cancel(target: String, id: String, emit: Emit) {
    lock.lock()
    let task = running[target]
    lock.unlock()
    guard let task else { return emit(invalid("unknown request", id: id)) }
    task.cancel()
  }

  /// Answers `unloaded`; `ok` is false while that model (with nil, any model) is loading or
  /// generating.
  func unload(modelID: String?, id: String, emit: @escaping Emit) {
    Task { [engine] in
      let ok =
        if let modelID { await engine.unload(modelID: modelID) } else { await engine.unload() }
      emit(Event(id: id, kind: .unloaded(ok: ok)))
    }
  }

  private func finished(_ id: String) {
    lock.lock()
    running[id] = nil
    lock.unlock()
  }

  /// Streams one request through the engine and returns its terminal event
  private static func serve(
    _ request: Generate, id: String, engine: MLXEngine, emit: Emit
  ) async -> Event.Kind {
    let loaded = LoadedFlag()
    do {
      try await engine.generate(
        modelID: request.modelID,
        directory: URL(fileURLWithPath: request.modelPath, isDirectory: true),
        messages: chatMessages(for: request), context: additionalContext(for: request),
        parameters: GenerateParameters(
          maxTokens: request.maxTokens, temperature: request.temperature),
        onPhase: { phase in
          switch phase {
          case .loading: emit(Event(id: id, kind: .loading))
          case .generating:
            loaded.raise()
            emit(Event(id: id, kind: .loaded))
          }
        },
        onChunk: { emit(Event(id: id, kind: .text(chunk: $0))) })
      // A model cancelled mid-stream stops and returns without throwing
      return Task.isCancelled ? .cancelled : .done
    } catch let error as MLXEngineError {
      return .error(code: error.code, message: error.message)
    } catch {
      if error is CancellationError || Task.isCancelled { return .cancelled }
      // Anything thrown before the model was ready is a load failure
      return .error(
        code: loaded.isRaised ? .generate : .load, message: error.localizedDescription)
    }
  }

  /// System prompt first (when not empty), then the conversation in order
  private static func chatMessages(for request: Generate) -> [Chat.Message] {
    var result: [Chat.Message] = []
    if !request.system.isEmpty { result.append(.system(request.system)) }
    for message in request.messages {
      switch message.role {
      case .user: result.append(.user(message.text))
      case .assistant: result.append(.assistant(message.text))
      }
    }
    return result
  }

  /// The chat template options the app set (`enable_thinking: false` for qwen3 models)
  private static func additionalContext(for request: Generate) -> [String: any Sendable]? {
    request.context.map { ["enable_thinking": $0.enableThinking] }
  }

  private func invalid(_ message: String, id: String) -> Event {
    Event(id: id, kind: .error(code: .invalid, message: message))
  }
}

/// Set once the engine reports the model ready, to tell a load failure from a generation one
nonisolated private final class LoadedFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var raised = false

  func raise() {
    lock.withLock { raised = true }
  }

  var isRaised: Bool {
    lock.withLock { raised }
  }
}
