// EnginePluginRuntime.swift
// One database engine plugin in this process: loads its bundle lazily, on the first connect, at
// most once, checks protocol v1 with the handshake, and hands sessions its `EnginePluginRouter`.

import Darwin
import Foundation

/// An engine bundle's two C entry points, `dblore_engine_protocol` and `dblore_engine_request`, or
/// a test fake of the same shape.
nonisolated struct EngineEntryPoint: Sendable {
  /// `emit(context, eventJSON)`: one event object per call, during `send` or later, from any
  /// thread. The string is valid only during the call.
  typealias Emit = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void

  let protocolVersion: @Sendable () -> Int32
  /// Sends one request JSON object; its events come through `emit` with `context`.
  let send: @Sendable (_ json: String, _ context: UnsafeMutableRawPointer?, _ emit: Emit) -> Void
}

/// Loads one engine plugin and keeps it for the life of the process: a load that loaded no code
/// can be tried again by the next connect; a protocol mismatch, or any failure once code is
/// loaded, refuses every later connect until a restart. Failures reach callers as
/// `DatabaseError.connectionFailed` and are logged.
actor EnginePluginRuntime {
  /// Loads the plugin and returns its entry points. Once its code is in the process, a failure is
  /// a `LoadFailure` with `codeLoaded`; any other error means nothing was loaded.
  typealias Loader = @Sendable () async throws -> EngineEntryPoint

  /// Why the plugin cannot be used
  nonisolated struct LoadFailure: Error, CustomStringConvertible {
    let description: String
    var codeLoaded = false
  }

  /// Longest wait for the `hello` answer
  nonisolated static let defaultHandshakeTimeout: Duration = .seconds(30)

  nonisolated private enum State {
    case idle
    case loading(Task<EngineEvent.Hello, Error>)
    case ready(EngineEvent.Hello)
    /// Refused until a restart, with the reason
    case failed(String)
  }

  nonisolated let pluginID: String
  /// Sends requests and routes events once `start()` has returned
  nonisolated let router: EnginePluginRouter
  private let loader: Loader
  private let handshakeTimeout: Duration
  private var state = State.idle

  init(
    pluginID: String, loader: @escaping Loader,
    handshakeTimeout: Duration = EnginePluginRuntime.defaultHandshakeTimeout
  ) {
    self.pluginID = pluginID
    self.loader = loader
    self.handshakeTimeout = handshakeTimeout
    router = EnginePluginRouter(label: pluginID)
  }

  /// The plugin's `hello` (engine, query language, libraries, features), loading it on the first
  /// call; concurrent callers share one load.
  func start() async throws -> EngineEvent.Hello {
    switch state {
    case .ready(let hello): return hello
    case .failed(let reason): throw DatabaseError.connectionFailed(reason)
    case .loading(let task): return try await task.value
    case .idle:
      let task = Task { try await load() }
      state = .loading(task)
      return try await task.value
    }
  }

  private func load() async throws -> EngineEvent.Hello {
    let entry: EngineEntryPoint
    do {
      entry = try await loader()
    } catch {
      let codeLoaded = (error as? LoadFailure)?.codeLoaded == true
      try await refuse(error, retry: !codeLoaded)
    }
    do {
      let hello = try await handshake(entry)
      state = .ready(hello)
      return hello
    } catch {
      router.attach(nil)
      try await refuse(error, retry: false)
    }
  }

  /// `dblore_engine_protocol()` and the `hello` answer must both report protocol 1.
  private func handshake(_ entry: EngineEntryPoint) async throws -> EngineEvent.Hello {
    let version = entry.protocolVersion()
    guard Int(version) == EnginePluginProtocol.version else {
      throw LoadFailure(description: "the plugin speaks protocol \(version)")
    }
    router.attach(entry)
    var answer: EngineEvent.Kind?
    let sent = try router.send(.hello, connection: nil, timeout: handshakeTimeout)
    for try await event in sent.events { answer = event.kind }
    switch answer {
    case .hello(let hello) where hello.protocolVersion == EnginePluginProtocol.version:
      return hello
    case .hello(let hello):
      throw LoadFailure(
        description: "the plugin answered hello with protocol \(hello.protocolVersion)")
    case .error(let failure):
      throw LoadFailure(description: "the plugin answered hello with an error: \(failure.message)")
    default:
      throw LoadFailure(description: "the plugin did not answer hello")
    }
  }

  /// Logs the cause and throws it as `connectionFailed`; `retry` leaves the runtime idle.
  private func refuse(_ error: Error, retry: Bool) async throws -> Never {
    let cause = (error as? LoadFailure)?.description ?? error.localizedDescription
    let reason = "The \(pluginID) plugin cannot be used: \(cause)"
    state = retry ? .idle : .failed(reason)
    await AppLogger.shared.error(reason, category: "Plugins")
    throw DatabaseError.connectionFailed(reason)
  }
}

// MARK: - One runtime per plugin id

extension EnginePluginRuntime {
  nonisolated private final class Registry: @unchecked Sendable {
    private let lock = NSLock()
    private var runtimes: [String: EnginePluginRuntime] = [:]

    func runtime(for pluginID: String) -> EnginePluginRuntime {
      lock.withLock {
        if let runtime = runtimes[pluginID] { return runtime }
        let runtime = EnginePluginRuntime(
          pluginID: pluginID, loader: EnginePluginRuntime.pluginLoader(pluginID: pluginID))
        runtimes[pluginID] = runtime
        return runtime
      }
    }

    #if DEBUG
      func install(_ runtime: EnginePluginRuntime) {
        lock.withLock { runtimes[runtime.pluginID] = runtime }
      }
    #endif
  }

  nonisolated private static let registry = Registry()

  /// The runtime of the catalog's plugin `pluginID`, created with the production loader on the
  /// first call
  nonisolated static func runtime(for pluginID: String) -> EnginePluginRuntime {
    registry.runtime(for: pluginID)
  }

  #if DEBUG
    /// Makes `runtime` the one `runtime(for: runtime.pluginID)` returns: tests use it to put a
    /// fake entry point behind a plugin id. DEBUG only, since it bypasses the signature check.
    nonisolated static func install(_ runtime: EnginePluginRuntime) {
      registry.install(runtime)
    }
  #endif
}

// MARK: - Production loader

extension EnginePluginRuntime {
  private typealias ProtocolFunction = @convention(c) () -> Int32
  private typealias RequestFunction =
    @convention(c) (UnsafePointer<CChar>, UnsafeMutableRawPointer?, EngineEntryPoint.Emit) -> Void

  /// Loads the bundle the registry's `pluginID` manager installed, once its launch check is done.
  /// Refused while it is not installed, and after a Remove or reinstall of loaded code (`Bundle`
  /// keeps the first image it loaded for a path, so new files need a restart).
  /// `PluginLoader.loadBundle` checks the Team ID, the entry's cdhash and the sealed resources
  /// before loading; the entry points are then looked up in that image only.
  nonisolated static func pluginLoader(pluginID: String) -> Loader {
    {
      let manager = try await MainActor.run {
        guard let manager = PluginRegistry.shared.manager(id: pluginID) else {
          throw LoadFailure(description: "the plugin catalog has no \(pluginID) entry")
        }
        return manager
      }
      return try await openBundle(try await installedBundle(of: manager), manager: manager)
    }
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

  /// Off the main actor: the signature check reads every file of the bundle. A failed check can
  /// be retried; a failed load cannot, since part of the code may already be mapped.
  @concurrent private static func openBundle(
    _ bundle: (url: URL, cdhash: String), manager: PluginManager
  ) async throws -> EngineEntryPoint {
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
      let protocolSymbol = dlsym(handle, "dblore_engine_protocol"),
      let requestSymbol = dlsym(handle, "dblore_engine_request")
    else {
      let reason = dlerror().map { String(cString: $0) } ?? "no executable"
      throw LoadFailure(description: "\(bundle.url.path): \(reason)", codeLoaded: true)
    }
    let protocolVersion = unsafeBitCast(protocolSymbol, to: ProtocolFunction.self)
    let request = unsafeBitCast(requestSymbol, to: RequestFunction.self)
    return EngineEntryPoint(
      protocolVersion: { protocolVersion() },
      send: { json, context, emit in json.withCString { request($0, context, emit) } })
  }
}
