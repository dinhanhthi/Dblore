// MCPHTTPServer.swift
// The MCP Streamable HTTP listener: HTTP/1.1 on 127.0.0.1 only (NIOHTTP1 + NIOPosix), one
// endpoint, `POST /mcp`. `MCPRequestValidator` checks each request head before any body is read;
// the body is buffered up to the limit (413 while it streams), then the injected handler runs
// off the event loop and its response is written back on the connection's loop. A connection
// takes one of `maxConnections` slots only when a request head first passes validation (token
// included) and keeps it until it closes, so idle or unauthenticated sockets never hold one. Over
// either that cap or `maxInFlight` running handlers, a validated request gets 503 instead.
// Refusals close the connection; answered requests honour keep-alive. A client that closes its
// connection while its handler runs cancels the handler (a waiting write approval is denied).
// JSON-RPC lives in the handler.

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import os

nonisolated struct MCPHTTPRequest: Sendable {
  let method: String
  let path: String
  /// Repeated header names are joined with ", ".
  let headers: [String: String]
  let body: Data
}

/// A notification answer is 202 with an empty body.
nonisolated struct MCPHTTPResponse: Sendable, Equatable {
  let status: Int
  let headers: [String: String]
  let body: Data

  static func text(_ status: Int, _ message: String, headers: [String: String] = [:]) -> Self {
    var headers = headers
    headers["Content-Type"] = "text/plain; charset=utf-8"
    return MCPHTTPResponse(status: status, headers: headers, body: Data(message.utf8))
  }

  /// Over a cap: 503 with a JSON-RPC error (server error range, id unknown).
  static let busy = MCPHTTPResponse(
    status: 503, headers: ["Content-Type": "application/json", "Retry-After": "2"],
    body: Data(
      #"{"jsonrpc":"2.0","id":null,"error":{"code":-32000,"message":"Server busy, retry later."}}"#
        .utf8))
}

actor MCPHTTPServer {
  typealias Handler = @Sendable (MCPHTTPRequest) async -> MCPHTTPResponse

  nonisolated struct Configuration: Sendable, Equatable {
    /// 0 picks a free port.
    var port: Int
    var token: String
    var bodyLimit = MCPRequestValidator.defaultBodyLimit
  }

  static let host = "127.0.0.1"
  /// Connections that sent a validated request and running handlers; over either cap a
  /// validated request gets `busy` (503).
  static let maxConnections = 16
  static let maxInFlight = 8

  private enum State {
    case stopped
    case starting(Task<Running, any Error>, id: UUID)
    case running(Running)
    case stopping(Task<Void, Never>)
  }

  private let handler: Handler
  private var state = State.stopped

  init(handler: @escaping Handler) {
    self.handler = handler
  }

  /// The bound port while running.
  var port: Int? {
    if case .running(let running) = state { return running.port }
    return nil
  }

  /// Binds and returns the port. While already running (or starting) it returns the current
  /// port without rebinding; stop first to change the configuration. A stop in progress is
  /// awaited first; a `stop()` during the bind makes this throw `CancellationError`.
  @discardableResult
  func start(_ configuration: Configuration) async throws -> Int {
    switch state {
    case .running(let running):
      return running.port
    case .starting(let task, _):
      _ = try await task.value
      guard case .running(let running) = state else { throw CancellationError() }
      return running.port
    case .stopping(let stopping):
      await stopping.value
      return try await start(configuration)
    case .stopped:
      break
    }
    let handler = self.handler
    let task = Task { try await Self.bind(configuration, handler: handler) }
    let id = UUID()
    state = .starting(task, id: id)
    do {
      let running = try await task.value
      // A stop() during the bind owns closing what the task produced.
      guard case .starting(_, let current) = state, current == id else {
        throw CancellationError()
      }
      state = .running(running)
      return running.port
    } catch {
      if case .starting(_, let current) = state, current == id { state = .stopped }
      throw error
    }
  }

  /// Closes the listener, waits for in-flight handlers, then shuts the event loop group down.
  /// Cancels a start in progress; concurrent calls wait for the same stop. A no-op when stopped.
  func stop() async {
    let stopping: Task<Void, Never>
    switch state {
    case .stopped:
      return
    case .stopping(let task):
      await task.value
      return
    case .running(let running):
      stopping = Task { await running.close() }
    case .starting(let task, _):
      stopping = Task {
        task.cancel()
        if let running = try? await task.value { await running.close() }
      }
    }
    state = .stopping(stopping)
    await stopping.value
    if case .stopping(let current) = state, current == stopping { state = .stopped }
  }

  private static func bind(
    _ configuration: Configuration, handler: @escaping Handler
  )
    async throws -> Running
  {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let tasks = MCPRequestTasks()
    let channel: any Channel
    do {
      channel = try await ServerBootstrap(group: group)
        .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
        .childChannelInitializer { channel in
          channel.eventLoop.makeCompletedFuture {
            // An accepted connection's local port is the listening port, also when bound to 0.
            let validator = MCPRequestValidator(
              port: channel.localAddress?.port ?? -1, token: configuration.token,
              bodyLimit: configuration.bodyLimit)
            try channel.pipeline.syncOperations.configureHTTPServerPipeline()
            try channel.pipeline.syncOperations.addHandler(
              MCPHTTPConnectionHandler(validator: validator, handler: handler, tasks: tasks))
          }
        }
        .bind(host: host, port: configuration.port)
        .get()
    } catch {
      try? await group.shutdownGracefully()
      throw error
    }
    let running = Running(
      group: group, channel: channel, tasks: tasks,
      port: channel.localAddress?.port ?? configuration.port)
    if Task.isCancelled {
      await running.close()
      throw CancellationError()
    }
    return running
  }

  private nonisolated struct Running: Sendable {
    let group: MultiThreadedEventLoopGroup
    let channel: any Channel
    let tasks: MCPRequestTasks
    let port: Int

    /// The group outlives the handler tasks, which write back on its loop.
    func close() async {
      try? await channel.close()
      await tasks.drain()
      try? await group.shutdownGracefully()
    }
  }
}

/// The handler tasks of one running listener, so stop can cancel and await them, and its
/// connection and in-flight slots.
private nonisolated final class MCPRequestTasks: Sendable {
  private struct State {
    var accepting = true
    var tasks: [UUID: Task<Void, Never>] = [:]
    var connections = 0
    var inFlight = 0
  }

  enum Start {
    case started(Task<Void, Never>)
    case busy
    case stopping
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  /// Takes a connection slot; false over `maxConnections`.
  func openConnection() -> Bool {
    state.withLock { state in
      guard state.connections < MCPHTTPServer.maxConnections else { return false }
      state.connections += 1
      return true
    }
  }

  func closeConnection() {
    state.withLock { $0.connections -= 1 }
  }

  /// Starts `body` in an in-flight slot that `body` frees with `finishRequest()`, unless the
  /// listener is stopping or every slot is taken.
  func run(_ body: @escaping @Sendable () async -> Void) -> Start {
    let id = UUID()
    return state.withLock { state in
      guard state.accepting else { return .stopping }
      guard state.inFlight < MCPHTTPServer.maxInFlight else { return .busy }
      state.inFlight += 1
      let task = Task {
        await body()
        self.state.withLock { _ = $0.tasks.removeValue(forKey: id) }
      }
      state.tasks[id] = task
      return .started(task)
    }
  }

  func finishRequest() {
    state.withLock { $0.inFlight -= 1 }
  }

  func drain() async {
    let tasks = state.withLock { state in
      state.accepting = false
      return Array(state.tasks.values)
    }
    for task in tasks {
      task.cancel()
      await task.value
    }
  }
}

/// One per connection, confined to its event loop. The HTTP pipeline handler serializes
/// pipelined requests, so at most one is in flight here.
private nonisolated final class MCPHTTPConnectionHandler: ChannelInboundHandler {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart

  private let validator: MCPRequestValidator
  private let handler: MCPHTTPServer.Handler
  private let tasks: MCPRequestTasks
  /// Set once the head passed validation; nil while refusing the rest of a request.
  private var head: HTTPRequestHead?
  private var body = ByteBuffer()
  /// The handler task of the request in flight, cancelled when the client goes away
  private var inFlight: Task<Void, Never>?
  /// Holds a connection slot, taken at the first valid request head; over the cap that request
  /// is answered `busy`.
  private var counted = false

  init(
    validator: MCPRequestValidator, handler: @escaping MCPHTTPServer.Handler,
    tasks: MCPRequestTasks
  ) {
    self.validator = validator
    self.handler = handler
    self.tasks = tasks
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch Self.unwrapInboundIn(data) {
    case .head(let head):
      body.clear()
      switch validator.validate(head) {
      case .proceed:
        if !counted { counted = tasks.openConnection() }
        if counted {
          self.head = head
        } else {
          self.head = nil
          Self.write(.busy, version: head.version, keepAlive: false, context: context)
        }
      case .reject(let response):
        self.head = nil
        Self.write(response, version: head.version, keepAlive: false, context: context)
      }
    case .body(var chunk):
      guard let head else { return }
      guard body.readableBytes + chunk.readableBytes <= validator.bodyLimit else {
        self.head = nil
        body = ByteBuffer()
        Self.write(
          .text(413, "Payload Too Large"), version: head.version, keepAlive: false,
          context: context)
        return
      }
      body.writeBuffer(&chunk)
    case .end:
      guard let head else { return }
      self.head = nil
      dispatch(head, body: Data(body.readableBytesView), context: context)
      body = ByteBuffer()
    }
  }

  /// Fires on every close (peer close, reset, error or our own), so the slot never leaks.
  func channelInactive(context: ChannelHandlerContext) {
    if counted { tasks.closeConnection() }
    counted = false
    inFlight?.cancel()
    inFlight = nil
    context.fireChannelInactive()
  }

  private func dispatch(_ head: HTTPRequestHead, body: Data, context: ChannelHandlerContext) {
    var headers: [String: String] = [:]
    for (name, value) in head.headers {
      headers[name] = headers[name].map { "\($0), \(value)" } ?? value
    }
    let request = MCPHTTPRequest(
      method: head.method.rawValue, path: MCPRequestValidator.path, headers: headers, body: body)
    let handler = self.handler
    let eventLoop = context.eventLoop
    let bound = NIOLoopBound(context, eventLoop: eventLoop)
    let version = head.version
    let keepAlive = head.isKeepAlive
    let connection = NIOLoopBound(self, eventLoop: eventLoop)
    let tasks = self.tasks
    let start = tasks.run {
      let response = await handler(request)
      // Freed before the write, so a client that got its answer finds the slot free.
      tasks.finishRequest()
      eventLoop.execute {
        connection.value.inFlight = nil
        Self.write(response, version: version, keepAlive: keepAlive, context: bound.value)
      }
    }
    switch start {
    case .started(let task):
      inFlight = task
    case .busy:
      Self.write(.busy, version: version, keepAlive: false, context: context)
    case .stopping:
      context.close(promise: nil)
    }
  }

  private static func write(
    _ response: MCPHTTPResponse, version: HTTPVersion, keepAlive: Bool,
    context: ChannelHandlerContext
  ) {
    guard context.channel.isActive else { return }
    var headers = HTTPHeaders(response.headers.map { ($0.key, $0.value) })
    headers.replaceOrAdd(name: "Content-Length", value: "\(response.body.count)")
    if !keepAlive { headers.replaceOrAdd(name: "Connection", value: "close") }
    let status = HTTPResponseStatus(statusCode: response.status)
    context.write(
      wrapOutboundOut(.head(HTTPResponseHead(version: version, status: status, headers: headers))),
      promise: nil)
    if !response.body.isEmpty {
      context.write(
        wrapOutboundOut(.body(.byteBuffer(ByteBuffer(bytes: response.body)))), promise: nil)
    }
    let written = context.writeAndFlush(wrapOutboundOut(.end(nil)))
    guard !keepAlive else { return }
    let channel = context.channel
    written.whenComplete { _ in channel.close(promise: nil) }
  }
}
