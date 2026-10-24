// LocalAIClient.swift
// On-device chat through the On-device AI plugin: `LocalAIRuntime` loads the plugin bundle once
// per process and routes its protocol v1 events to the waiting requests; `LocalAIChatClient`
// builds the generate requests and maps their events. Plugin text is untrusted: it is passed on
// as plain text only.

import Darwin
import Foundation

/// The plugin's two C entry points, `dblore_localai_protocol` and `dblore_localai_request`, or a
/// test fake of the same shape.
nonisolated struct LocalAIEntryPoint: Sendable {
  /// `emit(context, eventJSON)`: one event object per call, during `send` or later, from any
  /// thread. The string is valid only during the call.
  typealias Emit = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>) -> Void

  let protocolVersion: @Sendable () -> Int32
  /// Sends one request JSON object; its events come through `emit` with `context`.
  let send: @Sendable (_ json: String, _ context: UnsafeMutableRawPointer?, _ emit: Emit) -> Void
}

/// Routes each plugin event to the request whose `id` it echoes. Events for an unknown id are
/// ignored. The runtime hands it to the plugin as the `emit` context and keeps it alive for the
/// life of the process, since the plugin may answer late.
nonisolated final class LocalAIEventRouter: @unchecked Sendable {
  typealias Event = LocalAIProtocol.Event
  typealias Events = AsyncThrowingStream<Event, Error>

  static let unreadable = AIClientError.transport(
    "The On-device AI plugin sent an answer Dblore cannot read.")
  static let timedOut = AIClientError.transport("The On-device AI plugin did not answer in time.")

  private struct Waiter {
    let continuation: Events.Continuation
    var lastEvent: ContinuousClock.Instant
    var watchdog: Task<Void, Never>?
  }

  private let timeout: Duration
  /// Never resume a continuation (`yield`, `finish`) or cancel a task while holding `lock`: the
  /// streams' `onTermination` takes it, and a resume or cancel can wait on a task lock that a
  /// cancelling thread holds while it runs that `onTermination`. Only bookkeeping runs under it.
  private let lock = NSLock()
  /// Requests waiting for events, by id; guarded by `lock`
  private var waiters: [String: Waiter] = [:]

  init(timeout: Duration) {
    self.timeout = timeout
  }

  /// The events of the request `id`; call it before sending the request, since the plugin may
  /// answer during the call. The stream ends after the request's last event, and fails with
  /// transport when an event for it does not decode or `timeout` passes without one.
  func register(_ id: String) -> Events {
    let (events, continuation) = Events.makeStream()
    lock.withLock { waiters[id] = Waiter(continuation: continuation, lastEvent: .now) }
    let watchdog = Task { await watch(id) }
    lock.withLock { waiters[id]?.watchdog = watchdog }
    continuation.onTermination = { _ in self.remove(id) }
    return events
  }

  /// The C callback: copies the event (the string is valid only during the call) and routes it.
  /// An event over `maxEventBytes` is dropped unread.
  static func receive(_ context: UnsafeMutableRawPointer?, _ json: UnsafePointer<CChar>) {
    guard let context else { return }
    let length = strnlen(json, LocalAIProtocol.maxEventBytes + 1)
    guard length <= LocalAIProtocol.maxEventBytes else { return }
    Unmanaged<LocalAIEventRouter>.fromOpaque(context).takeUnretainedValue()
      .deliver(Data(bytes: json, count: length))
  }

  /// An event that does not decode but carries a waiting request's id ends that request.
  private func deliver(_ data: Data) {
    guard let event = LocalAIProtocol.decodeEvent(data) else {
      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      if let id = object?["id"] as? String { fail(id, with: Self.unreadable) }
      return
    }
    guard let id = event.id else { return }
    let isLast = Self.isLast(event.kind)
    let routed: Waiter? = lock.withLock {
      guard var waiter = waiters[id] else { return nil }
      if isLast {
        waiters[id] = nil
      } else {
        waiter.lastEvent = .now
        waiters[id] = waiter
      }
      return waiter
    }
    // Outside the lock (see `lock`). The plugin emits one request's events in order from one
    // Task, so they still arrive in order; a yield after `fail` or `remove` is a no-op.
    guard let routed else { return }
    routed.continuation.yield(event)
    guard isLast else { return }
    routed.watchdog?.cancel()
    routed.continuation.finish()
  }

  /// Only generate sends events before its last one.
  private static func isLast(_ kind: Event.Kind) -> Bool {
    switch kind {
    case .loading, .loaded, .text: false
    case .hello, .gpu, .done, .cancelled, .unloaded, .error: true
    }
  }

  /// Fails the request `id` once `timeout` passes without an event for it.
  private func watch(_ id: String) async {
    var deadline = ContinuousClock.now + timeout
    while true {
      try? await Task.sleep(until: deadline, clock: .continuous)
      if Task.isCancelled { return }
      guard let last = lock.withLock({ waiters[id]?.lastEvent }) else { return }
      deadline = last + timeout
      if deadline <= .now { return fail(id, with: Self.timedOut) }
    }
  }

  private func fail(_ id: String, with error: AIClientError) {
    guard let waiter = lock.withLock({ waiters.removeValue(forKey: id) }) else { return }
    waiter.watchdog?.cancel()
    waiter.continuation.finish(throwing: error)
  }

  private func remove(_ id: String) {
    lock.withLock { waiters.removeValue(forKey: id) }?.watchdog?.cancel()
  }
}

/// Loads the On-device AI plugin lazily, on the first chat, at most once per process, and sends it
/// requests. After `stop()` (Remove) its code stays loaded until the app quits, and chats get
/// `AIClientError.pluginMissing`.
actor LocalAIRuntime {
  typealias Event = LocalAIProtocol.Event
  typealias Request = LocalAIProtocol.Request
  /// Loads the plugin and returns its entry points. Once its code is in the process, a failure is
  /// a `LoadFailure` with `codeLoaded`; any other error means nothing was loaded, so the next chat
  /// tries again.
  typealias Loader = @Sendable () async throws -> LocalAIEntryPoint

  /// Why the plugin cannot be used (logged; chats get pluginMissing).
  nonisolated struct LoadFailure: Error, CustomStringConvertible {
    let description: String
    var codeLoaded = false
  }

  /// The runtime of the registry's `local-ai` plugin. Its first load makes Remove stop it first
  /// (the manager's `beforeRemove`): before that there is no code to stop.
  static let shared: LocalAIRuntime = LocalAIRuntime(loader: {
    let manager = try await MainActor.run {
      guard let manager = PluginRegistry.shared.manager(id: "local-ai") else {
        throw LoadFailure(description: "the plugin catalog has no local-ai entry")
      }
      manager.beforeRemove = { await LocalAIRuntime.shared.stop() }
      return manager
    }
    return try await LocalAIRuntime.pluginLoader(manager: manager)()
  })

  /// Longest wait for a request's next event; loading a large model sends none until it is ready.
  static let defaultTimeout: Duration = .seconds(120)

  nonisolated private enum State {
    case idle
    case loading(Task<Void, Never>)
    case ready(LocalAIEntryPoint)
    /// The code is loaded but takes no more chats until a restart: the handshake failed (no
    /// entry points), or `stop()` ran.
    case closed(LocalAIEntryPoint?)

    /// The entry points that passed the handshake, also after `stop()`, for `unload`: it only
    /// frees work, so it still reaches the loaded code. Cancels read `readyEntry` instead.
    var entryPoint: LocalAIEntryPoint? {
      switch self {
      case .ready(let entry): entry
      case .closed(let entry): entry
      case .idle, .loading: nil
      }
    }
  }

  /// The entry points that passed the handshake, readable without the actor so `cancelNow` sends
  /// before it returns. Set once, just before `state` turns ready, and kept after `stop()`, as
  /// `State.entryPoint` is.
  nonisolated private final class ReadyEntryPoint: @unchecked Sendable {
    private let lock = NSLock()
    private var entry: LocalAIEntryPoint?

    var value: LocalAIEntryPoint? {
      get { lock.withLock { entry } }
      set { lock.withLock { entry = newValue } }
    }
  }

  private let loader: Loader
  private let router: LocalAIEventRouter
  /// `router` as the plugin's `emit` context, retained for the life of the process
  nonisolated(unsafe) private let context: UnsafeMutableRawPointer
  private let readyEntry = ReadyEntryPoint()
  private var state = State.idle
  private var stopping: Task<Void, Never>?

  init(loader: @escaping Loader, timeout: Duration = LocalAIRuntime.defaultTimeout) {
    let router = LocalAIEventRouter(timeout: timeout)
    self.loader = loader
    self.router = router
    // Never released: the plugin may call back after this runtime is gone.
    context = Unmanaged.passRetained(router).toOpaque()
  }

  /// Hands a chat's cancellation over between its cancellation handler and `generate`: whichever
  /// of the two comes second sends the `cancel`, so a generate that was sent is cancelled exactly
  /// once. Neither sends while holding `lock`.
  nonisolated final class GenerateCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var id: String?
    private var cancelled = false

    /// From the cancellation handler: the generate's id when it was already sent, for the handler
    /// to cancel; nil when `generate` will cancel it, or sends none.
    func cancel() -> String? {
      lock.withLock {
        cancelled = true
        return id
      }
    }

    /// From `generate` right after it sent the request `id`: true when the handler already ran,
    /// so `generate` cancels it.
    fileprivate func sent(_ id: String) -> Bool {
      lock.withLock {
        self.id = id
        return cancelled
      }
    }
  }

  /// Sends `generate` and returns its id and events, through its last one (`done`, `cancelled` or
  /// `error`). When `cancellation` was cancelled while it was being sent, it sends the `cancel`
  /// right after, before this actor runs anything else. Throws pluginMissing when the plugin
  /// cannot be used.
  func generate(
    _ request: Request.Generate, cancellation: GenerateCancellation
  ) async throws -> (id: String, events: LocalAIEventRouter.Events) {
    let entry = try await readyEntryPoint()
    // A chat stopped while the plugin loaded sends nothing: a cancelled model load runs to the end.
    try Task.checkCancellation()
    let sent = try send(.generate(request), to: entry)
    if cancellation.sent(sent.id) { sendCancel(sent.id, to: entry) }
    return sent
  }

  /// Asks the plugin to stop the request `target` from any thread, without the actor, so the
  /// cancel reaches it before this returns: a generate sent afterwards finds its target already
  /// cancelled and waits behind it instead of answering busy. A running target ends with its own
  /// `cancelled`, and the answer for a finished one (`invalid` under the cancel's id) is ignored.
  /// Request ids exist only once the plugin is ready, so `readyEntry` is set for every target.
  nonisolated func cancelNow(_ target: String) {
    guard let entry = readyEntry.value else { return }
    sendCancel(target, to: entry)
  }

  nonisolated private func sendCancel(_ target: String, to entry: LocalAIEntryPoint) {
    guard let json = try? Self.json(Request(id: UUID().uuidString, kind: .cancel(target: target)))
    else { return }
    entry.send(json, context) { LocalAIEventRouter.receive($0, $1) }
  }

  /// Frees the model `modelID` before its files are deleted: true when no plugin code is loaded
  /// yet, including while a load is in progress, or when its load or handshake failed (no model
  /// can be resident), else the plugin's answer, which is false while that model is loading or
  /// generating, or when it does not answer.
  func unload(modelID: String) async -> Bool {
    await unload(modelID as String?)
  }

  /// The `local-ai` manager's `beforeRemove` hook: closes the runtime, so chats get pluginMissing
  /// until a restart, and unloads every model. A runtime that never loaded the plugin stays
  /// usable, since there is no loaded code to keep out. A second call while one runs waits for the
  /// same work.
  func stop() async {
    if let stopping { return await stopping.value }
    let work = Task { await closeForRemove() }
    stopping = work
    await work.value
    stopping = nil
  }

  private func closeForRemove() async {
    if case .loading(let task) = state { await task.value }
    guard case .ready(let entry) = state else { return }
    state = .closed(entry)
    _ = await unload(nil)
  }

  private func unload(_ modelID: String?) async -> Bool {
    guard let entry = state.entryPoint else { return true }
    guard let sent = try? send(.unload(modelID: modelID), to: entry) else { return false }
    do {
      for try await event in sent.events {
        if case .unloaded(let ok) = event.kind { return ok }
      }
    } catch {}
    return false
  }

  /// The loaded plugin's entry points, loading it on the first call; concurrent callers share one
  /// load.
  private func readyEntryPoint() async throws -> LocalAIEntryPoint {
    if stopping == nil, case .idle = state {
      state = .loading(Task { await load() })
    }
    if case .loading(let task) = state { await task.value }
    guard stopping == nil, case .ready(let entry) = state else {
      throw AIClientError.pluginMissing
    }
    return entry
  }

  /// Runs the loader and the handshake. On failure the cause is logged, and only a load that
  /// loaded no code may be tried again.
  private func load() async {
    let entry: LocalAIEntryPoint
    do {
      entry = try await loader()
    } catch {
      state = (error as? LoadFailure)?.codeLoaded == true ? .closed(nil) : .idle
      return await Self.log(error)
    }
    do {
      try await handshake(entry)
      // Before `state`: every id `generate` returns then finds it set
      readyEntry.value = entry
      state = .ready(entry)
    } catch {
      state = .closed(nil)
      await Self.log(error)
    }
  }

  /// `dblore_localai_protocol()` and the `hello` answer must both report protocol 1.
  private func handshake(_ entry: LocalAIEntryPoint) async throws {
    let version = entry.protocolVersion()
    guard Int(version) == LocalAIProtocol.version else {
      throw LoadFailure(description: "the plugin speaks protocol \(version)")
    }
    var answer: Event.Kind?
    for try await event in try send(.hello, to: entry).events { answer = event.kind }
    guard case .hello(let reported, _)? = answer, reported == LocalAIProtocol.version else {
      throw LoadFailure(description: "the plugin answered hello with \(String(describing: answer))")
    }
  }

  /// Registers the request's events before sending it: the plugin may answer during the call.
  private func send(
    _ kind: Request.Kind, to entry: LocalAIEntryPoint
  ) throws -> (id: String, events: LocalAIEventRouter.Events) {
    let id = UUID().uuidString
    let json = try Self.json(Request(id: id, kind: kind))
    let events = router.register(id)
    entry.send(json, context) { LocalAIEventRouter.receive($0, $1) }
    return (id, events)
  }

  private static func json(_ request: Request) throws -> String {
    String(decoding: try LocalAIProtocol.encode(request), as: UTF8.self)
  }

  private static func log(_ error: Error) async {
    await AppLogger.shared.error("On-device AI plugin unavailable: \(error)", category: "Plugins")
  }
}

// MARK: - Production loader

extension LocalAIRuntime {
  private typealias ProtocolFunction = @convention(c) () -> Int32
  private typealias RequestFunction =
    @convention(c) (UnsafePointer<CChar>, UnsafeMutableRawPointer?, LocalAIEntryPoint.Emit) -> Void

  /// Loads the bundle `manager` installed, once its launch check is done. Refused while it is not
  /// installed, and after a Remove or reinstall of loaded code (`Bundle` keeps the first image it
  /// loaded for a path, so new files need a restart). `PluginLoader.loadBundle` checks the Team
  /// ID, the entry's cdhash and the sealed resources before loading; the entry points are then
  /// looked up in that image only. A failed check can be retried; a failed load cannot, since
  /// part of the code may already be mapped.
  static func pluginLoader(manager: PluginManager) -> Loader {
    { try await openBundle(try await installedBundle(of: manager), manager: manager) }
  }

  @MainActor private static func installedBundle(
    of manager: PluginManager
  ) async throws -> (url: URL, cdhash: String) {
    guard await manager.isInstalledAfterLaunchCheck() else {
      throw LoadFailure(description: "the plugin is not installed")
    }
    guard !manager.requiresRestartToUnload else {
      throw LoadFailure(description: "the plugin changed after it was loaded; restart Dblore")
    }
    guard case .bundle(_, _, let cdhash) = manager.entry.kind, let url = manager.installedURL
    else { throw LoadFailure(description: "the catalog entry is not a valid bundle") }
    return (url, cdhash)
  }

  /// Off the main actor: the signature check reads every file of the bundle.
  @concurrent private static func openBundle(
    _ bundle: (url: URL, cdhash: String), manager: PluginManager
  ) async throws -> LocalAIEntryPoint {
    let loaded: Bundle
    do {
      loaded = try PluginLoader.loadBundle(
        at: bundle.url, expectedTeamID: PluginLoader.teamIdentifier,
        expectedCDHash: bundle.cdhash)
    } catch PluginLoaderError.bundleLoadFailed(let reason) {
      manager.markBundleLoaded()
      throw LoadFailure(description: reason, codeLoaded: true)
    } catch {
      throw LoadFailure(description: "\(bundle.url.path): \(error)")
    }
    manager.markBundleLoaded()
    // RTLD_NOLOAD: a handle only for the image just loaded, never a second copy.
    guard let path = loaded.executableURL?.path,
      let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL | RTLD_NOLOAD),
      let protocolSymbol = dlsym(handle, "dblore_localai_protocol"),
      let requestSymbol = dlsym(handle, "dblore_localai_request")
    else {
      let reason = dlerror().map { String(cString: $0) } ?? "no executable"
      throw LoadFailure(description: "\(bundle.url.path): \(reason)", codeLoaded: true)
    }
    let protocolVersion = unsafeBitCast(protocolSymbol, to: ProtocolFunction.self)
    let request = unsafeBitCast(requestSymbol, to: RequestFunction.self)
    return LocalAIEntryPoint(
      protocolVersion: { protocolVersion() },
      send: { json, context, emit in json.withCString { request($0, context, emit) } })
  }
}

// MARK: - Client

/// On-device chat through the plugin (no network access): maxTokens clamped to 1...4096, greedy
/// decoding, Qwen3 thinking off, and text blocks only (on-device models get no tools).
nonisolated struct LocalAIChatClient: AIChatClient {
  let root: URL
  let runtime: LocalAIRuntime

  init(root: URL = LocalModelManager.defaultRoot, runtime: LocalAIRuntime = .shared) {
    self.root = root
    self.runtime = runtime
  }

  static let maxTokensLimit = 4096

  /// System prompt and conversation in order, text blocks only, so `request.tools` and tool blocks
  /// are never sent. Temperature 0 is greedy decoding, for repeatable SQL. Qwen3 and Qwen3.5 chat
  /// templates think by default (Gemma 4 does not): it is turned off for predictable SQL output.
  static func generateRequest(
    for request: AIChatRequest, modelID: String, directory: URL
  ) -> LocalAIProtocol.Request.Generate {
    .init(
      modelID: modelID, modelPath: directory.path, system: request.system,
      messages: request.messages.map { message in
        switch message.role {
        case .user: .init(role: .user, text: message.text)
        case .assistant: .init(role: .assistant, text: message.text)
        }
      },
      maxTokens: max(1, min(request.maxTokens, maxTokensLimit)), temperature: 0,
      context: modelID.lowercased().hasPrefix("qwen3") ? .init(enableThinking: false) : nil)
  }

  // MARK: AIChatClient

  /// Cancelling the stream once its generate was sent sends `cancel` for it before the
  /// cancellation returns; while the generate is being sent, the runtime sends it right after,
  /// before any other request. Either way a chat started after the cancellation returns reaches
  /// the plugin second and waits instead of getting busy. A stream cancelled before the generate
  /// is sent sends neither request. A request the app ends itself (timeout, unreadable event)
  /// sends `cancel` too, so the plugin's engine is not left busy.
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
          let cancellation = LocalAIRuntime.GenerateCancellation()
          try await withTaskCancellationHandler {
            let (id, events) = try await runtime.generate(
              Self.generateRequest(for: request, modelID: model.id, directory: directory),
              cancellation: cancellation)
            do {
              try await Self.relay(events, to: continuation)
            } catch {
              // `onCancel` or `generate` already sent it for the consumer's own cancellation. For
              // a request that already ended, the plugin's answer goes to the cancel's id and is
              // ignored.
              if !(error is CancellationError) { runtime.cancelNow(id) }
              throw error
            }
          } onCancel: {
            if let id = cancellation.cancel() { runtime.cancelNow(id) }
          }
          continuation.finish()
        } catch is CancellationError {
          continuation.finish()
        } catch let error as AIClientError {
          continuation.finish(throwing: error)
        } catch {
          continuation.finish(throwing: AIClientError.transport(error.localizedDescription))
        }
      }
      continuation.onTermination = { termination in
        if case .cancelled = termination { task.cancel() }
      }
    }
  }

  /// Passes `loading` and text chunks on until the request's last event; a plugin error becomes
  /// an `AIClientError` (busy keeps the app's own message).
  private static func relay(
    _ events: LocalAIEventRouter.Events,
    to continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
  ) async throws {
    for try await event in events {
      switch event.kind {
      case .loading: continuation.yield(.loadingModel)
      case .loaded: continue
      case .text(let chunk): continuation.yield(.text(chunk))
      case .done, .cancelled: return
      case .error(.busy, _): throw AIClientError.transport("Local model is busy")
      case .error(_, let message): throw AIClientError.transport(message)
      case .hello, .gpu, .unloaded: throw LocalAIEventRouter.unreadable
      }
    }
    // The events end early only when this task is cancelled.
    try Task.checkCancellation()
    throw LocalAIEventRouter.unreadable
  }

  func listModels() async throws -> [String] {
    LocalModelCatalog.all.filter {
      LocalModelManager.isInstalled(at: root.appendingPathComponent($0.id, isDirectory: true))
    }.map(\.id)
  }
}
