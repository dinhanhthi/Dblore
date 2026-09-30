// MLXChatClient.swift
// On-device chat client running catalog MLX models in-process (no network access)

import Foundation
import MLX
import MLXHuggingFace
import MLXLMCommon
import Tokenizers

// MARK: - Engine

/// Phase reported by the engine while serving a request.
nonisolated enum MLXEnginePhase: Sendable, Equatable {
  case loading
  case generating
}

/// A loaded model able to stream text. Abstracted so tests never load real weights.
nonisolated protocol MLXLoadedModel: Sendable {
  func generate(
    messages: [Chat.Message], context: [String: any Sendable]?, parameters: GenerateParameters,
    onChunk: @Sendable (String) -> Void
  ) async throws
}

nonisolated struct MLXContainerModel: MLXLoadedModel {
  let container: ModelContainer

  func generate(
    messages: [Chat.Message], context: [String: any Sendable]?, parameters: GenerateParameters,
    onChunk: @Sendable (String) -> Void
  ) async throws {
    // UserInput is not Sendable, but it is built from Sendable values and used only here
    nonisolated(unsafe) let input = UserInput(chat: messages, additionalContext: context)
    let lmInput = try await container.prepare(input: input)
    let stream = try await container.generate(input: lmInput, parameters: parameters)
    for await generation in stream {
      if Task.isCancelled { break }
      if case .chunk(let text) = generation { onChunk(text) }
    }
  }
}

/// Owns the single resident model. Loads lazily (off the main thread), unloads after an idle
/// period or memory pressure, and allows one generation at a time.
actor MLXEngine {
  typealias Loader = @Sendable (URL) async throws -> any MLXLoadedModel

  static let shared = MLXEngine(observeMemoryPressure: true)

  /// How long a model stays in RAM after the last request
  static let idleUnloadInterval: Duration = .seconds(300)

  /// GPU buffer cache kept by MLX between runs
  static let cacheLimitBytes = 256 * 1024 * 1024

  static let containerLoader: Loader = { directory in
    MLXContainerModel(
      container: try await loadModelContainer(
        from: directory, using: #huggingFaceTokenizerLoader()))
  }

  /// Per-request cancellation flag, set synchronously when the request's task is cancelled
  private final class RequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() {
      lock.lock()
      cancelled = true
      lock.unlock()
    }
    var isCancelled: Bool {
      lock.lock()
      defer { lock.unlock() }
      return cancelled
    }
  }

  private let idleUnloadInterval: Duration
  private let loader: Loader
  private let releaseMemory: @Sendable () -> Void
  private var model: (any MLXLoadedModel)?
  private var loadedID: String?
  private var loadingID: String?
  /// The request currently holding the engine (loading or generating)
  private var active: RequestState?
  private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
  private var idleTask: Task<Void, Never>?
  private(set) var idleGeneration = 0
  nonisolated(unsafe) private var memoryPressure: DispatchSourceMemoryPressure?

  init(
    idleUnloadInterval: Duration = MLXEngine.idleUnloadInterval,
    loader: @escaping Loader = MLXEngine.containerLoader,
    releaseMemory: @escaping @Sendable () -> Void = { MLX.Memory.clearCache() },
    observeMemoryPressure: Bool = false
  ) {
    self.idleUnloadInterval = idleUnloadInterval
    self.loader = loader
    self.releaseMemory = releaseMemory
    if observeMemoryPressure { memoryPressure = makeMemoryPressureSource() }
  }

  var isLoaded: Bool { model != nil }
  var loadedModelID: String? { loadedID }
  var isGenerating: Bool { active != nil }

  /// Streams chunks of generated text through `onChunk`, reporting the loading phase through
  /// `onPhase`. A request whose predecessor was cancelled (Stop) waits for it to finish; it
  /// throws busy only while a live, non-cancelled request is running.
  func generate(
    modelID: String, directory: URL, messages: [Chat.Message],
    context: [String: any Sendable]?, parameters: GenerateParameters,
    onPhase: @Sendable (MLXEnginePhase) -> Void = { _ in },
    onChunk: @Sendable (String) -> Void
  ) async throws {
    let state = RequestState()
    try await withTaskCancellationHandler {
      try await serve(
        state: state, modelID: modelID, directory: directory, messages: messages,
        context: context, parameters: parameters, onPhase: onPhase, onChunk: onChunk)
    } onCancel: {
      state.cancel()
    }
  }

  private func serve(
    state: RequestState, modelID: String, directory: URL, messages: [Chat.Message],
    context: [String: any Sendable]?, parameters: GenerateParameters,
    onPhase: @Sendable (MLXEnginePhase) -> Void,
    onChunk: @Sendable (String) -> Void
  ) async throws {
    try Task.checkCancellation()
    while let current = active {
      guard current.isCancelled else { throw AIClientError.transport("Local model is busy") }
      await waitForRelease()
      try Task.checkCancellation()
    }
    // No suspension between the loop exit and taking ownership: one request at a time
    active = state
    cancelIdleTimer()
    defer {
      active = nil
      let pending = waiters
      waiters = [:]
      for continuation in pending.values { continuation.resume() }
      scheduleIdleUnload()
    }

    if model == nil || loadedID != modelID { onPhase(.loading) }
    let loaded = try await ensureLoaded(modelID: modelID, directory: directory)
    // A cancelled load keeps the model resident (idle timer bounds memory) for a quick resend
    try Task.checkCancellation()
    onPhase(.generating)
    try await loaded.generate(
      messages: messages, context: context, parameters: parameters, onChunk: onChunk)
  }

  private func waitForRelease() async {
    let id = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { waiters[id] = $0 }
    } onCancel: {
      Task { await self.cancelWaiter(id) }
    }
  }

  private func cancelWaiter(_ id: UUID) {
    waiters.removeValue(forKey: id)?.resume()
  }

  /// Drops the resident model. Refused (returns false) while a request is running.
  @discardableResult
  func unload() -> Bool {
    guard active == nil else { return false }
    cancelIdleTimer()
    guard model != nil else { return true }
    model = nil
    loadedID = nil
    releaseMemory()
    return true
  }

  /// Unloads only when `modelID` is the resident model; false when it is resident and busy,
  /// or while it is being loaded (its files are in use).
  @discardableResult
  func unload(modelID: String) -> Bool {
    if loadingID == modelID { return false }
    guard loadedID == modelID else { return true }
    return unload()
  }

  private func ensureLoaded(modelID: String, directory: URL) async throws -> any MLXLoadedModel {
    if let model, loadedID == modelID { return model }
    // Switching models: free the previous one first (the busy flag is ours, so force it)
    if model != nil {
      model = nil
      loadedID = nil
      releaseMemory()
    }
    MLX.Memory.cacheLimit = Self.cacheLimitBytes
    loadingID = modelID
    defer { loadingID = nil }
    let loaded = try await loader(directory)
    model = loaded
    loadedID = modelID
    return loaded
  }

  private func cancelIdleTimer() {
    idleGeneration += 1
    idleTask?.cancel()
    idleTask = nil
  }

  private func scheduleIdleUnload() {
    cancelIdleTimer()
    let generation = idleGeneration
    idleTask = Task { [idleUnloadInterval] in
      try? await Task.sleep(for: idleUnloadInterval)
      guard !Task.isCancelled else { return }
      self.unloadIdle(generation: generation)
    }
  }

  /// Idle-timer entry point: does nothing when a newer request rescheduled the timer meanwhile
  func unloadIdle(generation: Int) {
    guard generation == idleGeneration else { return }
    unload()
  }

  /// Unloads an idle model when macOS reports memory pressure
  private nonisolated func makeMemoryPressureSource() -> DispatchSourceMemoryPressure {
    let source = DispatchSource.makeMemoryPressureSource(
      eventMask: [.warning, .critical], queue: .global(qos: .utility))
    source.setEventHandler { [weak self] in
      Task { await self?.unload() }
    }
    source.resume()
    return source
  }
}

// MARK: - Client

nonisolated struct MLXChatClient: AIChatClient {
  let root: URL
  let engine: MLXEngine

  init(root: URL = LocalModelManager.defaultRoot, engine: MLXEngine = .shared) {
    self.root = root
    self.engine = engine
  }

  // MARK: Pure helpers

  static let defaultTemperature: Float = 0.2
  static let maxTokensLimit = 4096

  /// NaN, infinite and negative values fall back to 0.2; values above 1.0 are capped.
  nonisolated static func sanitizeTemperature(_ value: Double) -> Float {
    guard value.isFinite, value >= 0 else { return defaultTemperature }
    return Float(min(value, 1.0))
  }

  static func clampMaxTokens(_ value: Int) -> Int {
    max(1, min(value, maxTokensLimit))
  }

  /// System prompt first (when not empty), then the conversation in order.
  static func chatMessages(for request: AIChatRequest) -> [Chat.Message] {
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

  /// Qwen3 chat templates think by default; turn it off for predictable SQL output.
  static func additionalContext(forModel id: String) -> [String: any Sendable]? {
    id.lowercased().hasPrefix("qwen3") ? ["enable_thinking": false] : nil
  }

  // MARK: AIChatClient

  func stream(_ request: AIChatRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          guard let model = LocalModelCatalog.model(for: request.model) else {
            throw AIClientError.missingModel
          }
          let directory = root.appendingPathComponent(model.id, isDirectory: true)
          guard LocalModelManager.isInstalled(at: directory) else {
            throw AIClientError.transport("Download the on-device model in Settings > AI first.")
          }
          let parameters = GenerateParameters(
            maxTokens: Self.clampMaxTokens(request.maxTokens),
            temperature: Self.sanitizeTemperature(0.2))
          try await engine.generate(
            modelID: model.id, directory: directory, messages: Self.chatMessages(for: request),
            context: Self.additionalContext(forModel: model.id), parameters: parameters,
            onPhase: { if $0 == .loading { continuation.yield(.loadingModel) } },
            onChunk: { continuation.yield(.text($0)) })
          continuation.finish()
        } catch is CancellationError {
          continuation.finish()
        } catch let error as AIClientError {
          continuation.finish(throwing: error)
        } catch {
          continuation.finish(throwing: AIClientError.transport(error.localizedDescription))
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  func listModels() async throws -> [String] {
    LocalModelCatalog.all.filter {
      LocalModelManager.isInstalled(at: root.appendingPathComponent($0.id, isDirectory: true))
    }.map(\.id)
  }
}
