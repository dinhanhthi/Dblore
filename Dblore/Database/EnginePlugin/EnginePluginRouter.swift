// EnginePluginRouter.swift
// The app side of one engine plugin's `emit` callback: allocates request and connection ids,
// sends requests through the plugin's entry point, and routes each event to the request whose
// `id` it echoes, or by `connection` for `closed`. Engine-neutral: sessions map the events.
// Request JSON is never logged (an `open` holds the password); event text is untrusted.

import Darwin
import Foundation

/// A failure of the bridge itself, or a plugin `error` event a session rethrows. Every text is
/// plain text, shown as is.
nonisolated enum EnginePluginError: LocalizedError, Equatable {
  /// No plugin code passed the handshake, so nothing was sent
  case notLoaded
  /// An event for the request did not decode
  case unreadableEvent
  /// An event for the request was over `EnginePluginProtocol.maxEventBytes`
  case eventTooLarge
  /// The request's deadline passed without its last event
  case timedOut
  /// The request's connection was lost or closed before its answer
  case connectionClosed(EngineEvent.ClosedReason)
  /// The plugin's `error` event: its message as sent (a session replaces the password in it),
  /// its code and `serverCode` kept
  case server(EngineEvent.Failure)

  var errorDescription: String? {
    switch self {
    case .notLoaded: "The database plugin is not loaded."
    case .unreadableEvent: "The database plugin sent an answer Dblore cannot read."
    case .eventTooLarge: "The database plugin sent an answer over the 1 MiB limit."
    case .timedOut: "The database plugin did not answer in time."
    case .connectionClosed(let reason):
      reason == .closed ? "The connection was closed." : "The connection to the server was lost."
    case .server(let failure): failure.message
    }
  }
}

/// Routes one plugin's events. It retains itself for the life of the process, since the plugin
/// may call `emit` after every session is gone; `context` is that retained pointer.
///
/// Rules:
/// - `columns`, `rows` and `chunk` keep a request open; every other kind is its last event,
///   `error` included (yielded whole, never thrown). An `unknown` kind is skipped.
/// - Credit is enforced by the plugin (at most 2 `rows` events ahead after `columns`); the session
///   calls `more(target:)` once per `rows` event it has consumed, never on receipt.
/// - `closed` (the answer to `close`, or unsolicited when the server goes away) ends the `close`
///   request, fails every other request of its `connection` with `connectionClosed`, then yields
///   to and finishes that connection's `closeEvents`. A `closed` without a connection only ends
///   the request it answers. A reason other than `closed` (a newer plugin's) counts as `lost`.
/// - An event that does not decode fails the request its `id` names. An event over
///   `maxEventBytes` is not copied: the `id` is read from its first `idPrefixBytes` (sorted keys
///   put it before `rows`, `result` and `message`) and that request fails. With no readable id
///   the event is dropped and only its size is logged: a query or command then ends only through
///   `cancel` or `closed` (they have no deadline). A failed request is not cancelled here, since
///   the callback may run inside the plugin's own send; the session cancels it.
nonisolated final class EnginePluginRouter: @unchecked Sendable {
  typealias Events = AsyncThrowingStream<EngineEvent, Error>
  typealias CloseEvents = AsyncStream<EngineEvent.ClosedReason>

  /// How much of an over-cap event is read to find its `id`
  static let idPrefixBytes = 1024

  private struct Waiter {
    let continuation: Events.Continuation
    let connection: Int?
    var deadline: Task<Void, Never>?
  }

  /// Names the plugin in logs
  let label: String
  /// Never resume a continuation (`yield`, `finish`), cancel a task or call the plugin while
  /// holding `lock`: the streams' `onTermination` takes it. Only bookkeeping runs under it.
  private let lock = NSLock()
  private var entry: EngineEntryPoint?
  private var waiters: [String: Waiter] = [:]
  private var closeStreams: [Int: CloseEvents.Continuation] = [:]
  private var lastRequestID = 0
  private var lastConnectionID = 0

  init(label: String) {
    self.label = label
    // Never released: the plugin may call back after this router's runtime is gone.
    _ = Unmanaged.passRetained(self)
  }

  /// This router as the plugin's `emit` context
  var context: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

  /// The entry point requests go to; nil refuses every send with `notLoaded`
  func attach(_ entry: EngineEntryPoint?) {
    lock.withLock { self.entry = entry }
  }

  /// A new id for `open` and every request of that session
  func makeConnectionID() -> Int {
    lock.withLock {
      lastConnectionID += 1
      return lastConnectionID
    }
  }

  /// Sends the request and returns its id and events, through its last one. Registered before
  /// the call, since the plugin may answer during it. `timeout` is a plain deadline for the whole
  /// request (`hello`, `open`); queries and commands get none.
  func send(
    _ kind: EngineRequest.Kind, connection: Int?, timeout: Duration? = nil
  ) throws -> (id: String, events: Events) {
    guard let entry = lock.withLock({ self.entry }) else { throw EnginePluginError.notLoaded }
    let id = makeRequestID()
    let json = try Self.json(EngineRequest(id: id, connection: connection, kind: kind))
    let events = register(id, connection: connection, timeout: timeout)
    entry.send(json, context) { EnginePluginRouter.receive($0, $1) }
    return (id, events)
  }

  /// Grants the query `target` credit for one more `rows` event; nothing once it has ended
  func more(target: String) {
    guard let waiter = lock.withLock({ waiters[target] }) else { return }
    sendUnanswered(.more(target: target), connection: waiter.connection)
  }

  /// Asks the plugin to stop the request `target`, which then ends with `cancelled`. Sent from
  /// any thread without waiting; the answer to a finished target is ignored.
  func cancel(target: String) {
    let connection = lock.withLock { waiters[target]?.connection }
    sendUnanswered(.cancel(target: target), connection: connection)
  }

  /// The `closed` reasons of `connection`: at most one, then the stream ends. Call it before
  /// `open`; a second call replaces (and ends) the first stream.
  func closeEvents(connection: Int) -> CloseEvents {
    let (events, continuation) = CloseEvents.makeStream()
    let previous = lock.withLock { closeStreams.updateValue(continuation, forKey: connection) }
    previous?.finish()
    return events
  }

  /// Ends `connection`'s close stream, once the session has let it go
  func forget(connection: Int) {
    lock.withLock { closeStreams.removeValue(forKey: connection) }?.finish()
  }

  /// Ends the request `id` with `error`; nothing once it has ended
  func fail(_ id: String, with error: EnginePluginError) {
    guard let waiter = lock.withLock({ waiters.removeValue(forKey: id) }) else { return }
    waiter.deadline?.cancel()
    waiter.continuation.finish(throwing: error)
  }

  /// The C callback: copies the event (the string is valid only during the call) and routes it.
  /// May run on any thread.
  static func receive(_ context: UnsafeMutableRawPointer?, _ json: UnsafePointer<CChar>?) {
    guard let context, let json else { return }
    let router = Unmanaged<EnginePluginRouter>.fromOpaque(context).takeUnretainedValue()
    let length = strnlen(json, EnginePluginProtocol.maxEventBytes + 1)
    guard length <= EnginePluginProtocol.maxEventBytes else {
      return router.dropOverCap(Data(bytes: json, count: idPrefixBytes))
    }
    router.deliver(Data(bytes: json, count: length))
  }

  // MARK: - Routing

  private func deliver(_ data: Data) {
    let event: EngineEvent
    do {
      event = try EnginePluginProtocol.decodeEvent(data)
    } catch EngineProtocolError.invalid(let id?) {
      return fail(id, with: .unreadableEvent)
    } catch {
      return log("dropped an unreadable event of \(data.count) bytes")
    }
    if case .closed(let reason) = event.kind { return closed(event, reason: reason) }
    if case .unknown = event.kind { return }
    guard let id = event.id else { return }
    let isLast = Self.isLast(event.kind)
    let routed: Waiter? = lock.withLock {
      isLast ? waiters.removeValue(forKey: id) : waiters[id]
    }
    // Outside the lock (see `lock`). The plugin emits one request's events in order from its
    // connection's queue; a yield after `fail` or `onTermination` is a no-op.
    guard let routed else { return }
    routed.continuation.yield(event)
    guard isLast else { return }
    routed.deadline?.cancel()
    routed.continuation.finish()
  }

  private static func isLast(_ kind: EngineEvent.Kind) -> Bool {
    switch kind {
    case .columns, .rows, .chunk, .unknown: false
    case .hello, .opened, .done, .cancelled, .settingsApplied, .transactionState, .catalog,
      .closed, .error:
      true
    }
  }

  private func closed(_ event: EngineEvent, reason: EngineEvent.ClosedReason) {
    let reason: EngineEvent.ClosedReason = reason == .closed ? .closed : .lost
    let connection = event.connection
    let (answer, others, close): (Waiter?, [Waiter], CloseEvents.Continuation?) = lock.withLock {
      let answer = event.id.flatMap { waiters.removeValue(forKey: $0) }
      guard let connection else { return (answer, [], nil) }
      let ids = waiters.filter { $0.value.connection == connection }.map(\.key)
      let others = ids.compactMap { waiters.removeValue(forKey: $0) }
      return (answer, others, closeStreams.removeValue(forKey: connection))
    }
    if let answer {
      answer.deadline?.cancel()
      answer.continuation.yield(event)
      answer.continuation.finish()
    }
    for waiter in others {
      waiter.deadline?.cancel()
      waiter.continuation.finish(throwing: EnginePluginError.connectionClosed(reason))
    }
    close?.yield(reason)
    close?.finish()
  }

  /// Fails the request named by the `id` in the event's first bytes (see the rules above)
  private func dropOverCap(_ prefix: Data) {
    guard let id = Self.envelopeID(in: prefix), lock.withLock({ waiters[id] != nil }) else {
      return log("dropped an event over \(EnginePluginProtocol.maxEventBytes) bytes")
    }
    fail(id, with: .eventTooLarge)
  }

  /// The value of the first `"id":"…"` key. Inside a JSON string every quote is escaped, so the
  /// match is a key; no payload key that sorts before `id` holds an `id` key.
  private static func envelopeID(in prefix: Data) -> String? {
    let key = Data(#""id":""#.utf8)
    guard let range = prefix.range(of: key) else { return nil }
    let rest = prefix[range.upperBound...]
    guard let end = rest.firstIndex(of: UInt8(ascii: "\"")) else { return nil }
    return String(decoding: rest[..<end], as: UTF8.self)
  }

  // MARK: - Sending

  private func makeRequestID() -> String {
    lock.withLock {
      lastRequestID += 1
      return String(lastRequestID)
    }
  }

  private func register(_ id: String, connection: Int?, timeout: Duration?) -> Events {
    let (events, continuation) = Events.makeStream()
    lock.withLock { waiters[id] = Waiter(continuation: continuation, connection: connection) }
    if let timeout {
      let deadline = Task {
        try? await Task.sleep(for: timeout)
        if !Task.isCancelled { self.fail(id, with: .timedOut) }
      }
      lock.withLock { waiters[id]?.deadline = deadline }
    }
    continuation.onTermination = { _ in self.remove(id) }
    return events
  }

  private func remove(_ id: String) {
    lock.withLock { waiters.removeValue(forKey: id) }?.deadline?.cancel()
  }

  /// `more` and `cancel`: no waiter, so their answers are ignored
  private func sendUnanswered(_ kind: EngineRequest.Kind, connection: Int?) {
    guard let entry = lock.withLock({ self.entry }),
      let json = try? Self.json(
        EngineRequest(id: makeRequestID(), connection: connection, kind: kind))
    else { return }
    entry.send(json, context) { EnginePluginRouter.receive($0, $1) }
  }

  private static func json(_ request: EngineRequest) throws -> String {
    String(decoding: try EnginePluginProtocol.encodeRequest(request), as: UTF8.self)
  }

  /// Sizes and counts only, never event or request text
  private func log(_ message: String) {
    let text = "Engine plugin \(label): \(message)"
    Task { await AppLogger.shared.error(text, category: "Plugins") }
  }
}
