// MCPHTTPServer.swift
// The MCP Streamable HTTP listener: HTTP/1.1 on 127.0.0.1 only (NIOHTTP1 + NIOPosix): `POST /mcp`,
// plus the command-line tool's `POST /cli/pair` and `POST /cli/hello`. `MCPRequestValidator`
// checks each request head before any body is read; the body is buffered up to the route's limit
// (413 while it streams), then the injected handler runs off the event loop with the route's
// path, the caller and the bound port, and its response is written back on the connection's
// loop. A `/mcp` connection takes one of `maxConnections` slots only when a request head first
// passes validation (token included) and keeps it until it closes, so idle or unauthenticated
// sockets never hold one. Over either that cap or `maxInFlight` running handlers, a validated
// `/mcp` request gets 503 instead. `/cli/*` requests take neither kind of slot (they are short
// and do not wait on anyone) and are answered with `Connection: close`, so they never crowd out
// an agent. Refusals close the connection; answered `/mcp` requests honour keep-alive. A client
// that closes its connection while its handler runs cancels the handler (a waiting write approval
// is denied).
// With no request in flight a per-connection timer closes the socket: no first request head
// within 10 s, a request body not complete 15 s after its head, or 30 s of keep-alive silence. No
// timer runs while a handler does, so a write awaiting approval keeps its own bound. While a
// handler runs the connection keeps reading (the HTTP pipeline handler would pause reads), so a
// close is seen; once over `inFlightReadLimit` bytes are buffered that way, it is closed.
// JSON-RPC and the pairing answers live in the handler.

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import os

nonisolated struct MCPHTTPRequest: Sendable {
  let method: String
  /// The route's path, without a query string
  let path: String
  /// Repeated header names are joined with ", ".
  let headers: [String: String]
  let body: Data
  /// Whose bearer `/mcp` accepted; nil on the `/cli/*` routes, which carry none. The listener
  /// always sets it.
  var caller: MCPCallerKind? = .mcp
  /// The port the connection reached, read from its socket (`channel.localAddress`), not from
  /// the configuration
  var port = 0
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

  nonisolated struct Configuration: Sendable {
    /// 0 picks a free port.
    var port: Int
    var token: String
    var bodyLimit = MCPRequestValidator.defaultBodyLimit
    var firstRequestTimeout = MCPHTTPServer.firstRequestTimeout
    var readTimeout = MCPHTTPServer.readTimeout
    var keepAliveTimeout = MCPHTTPServer.keepAliveTimeout
    var inFlightReadLimit = MCPHTTPServer.inFlightReadLimit
    /// The paired command-line tools' tokens, also accepted on `/mcp` (caller cli)
    var cliTokens = MCPCLITokenRegistry()
  }

  static let host = "127.0.0.1"
  /// Connections that sent a validated request and running handlers; over either cap a
  /// validated request gets `busy` (503).
  static let maxConnections = 16
  static let maxInFlight = 8
  /// From accept until the first request head is complete.
  static let firstRequestTimeout = TimeAmount.seconds(10)
  /// From a validated head until its body is complete.
  static let readTimeout = TimeAmount.seconds(15)
  /// From an answer on a kept-alive connection until the next request head is complete.
  static let keepAliveTimeout = TimeAmount.seconds(30)
  /// Bytes a client may send while its requests are in flight, until the pipelined requests
  /// buffered meanwhile are all handed over.
  static let inFlightReadLimit = MCPRequestValidator.defaultBodyLimit

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
              bodyLimit: configuration.bodyLimit, cliTokens: configuration.cliTokens)
            let reader = MCPInFlightReader(limit: configuration.inFlightReadLimit)
            try channel.pipeline.syncOperations.addHandler(reader)
            try channel.pipeline.syncOperations.configureHTTPServerPipeline()
            try channel.pipeline.syncOperations.addHandler(
              MCPHTTPConnectionHandler(
                validator: validator, handler: handler, tasks: tasks, reader: reader,
                configuration: configuration))
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

  /// Starts `body`, unless the listener is stopping. With `takesSlot`, in an in-flight slot that
  /// `body` frees with `finishRequest()`, unless every slot is taken.
  func run(takesSlot: Bool, _ body: @escaping @Sendable () async -> Void) -> Start {
    let id = UUID()
    return state.withLock { state in
      guard state.accepting else { return .stopping }
      if takesSlot {
        guard state.inFlight < MCPHTTPServer.maxInFlight else { return .busy }
        state.inFlight += 1
      }
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

/// First in a connection's pipeline, confined to its event loop. While a request is in flight the
/// HTTP pipeline handler holds reads back, and on Darwin a peer's close is only seen by reading,
/// so this one keeps reading then: the close reaches `channelInactive`, which cancels the handler.
/// Bytes read meanwhile pass on and the pipeline handler buffers them, handing over one request
/// per answer (inside that answer's write, so the next one is in flight again at once). It asks
/// to read again only once its buffer is empty, so the count resets on a read outside a request,
/// and over `limit` the connection is closed. Quiet clients are never closed here; outside a
/// request reads pass through untouched.
private nonisolated final class MCPInFlightReader: ChannelInboundHandler {
  typealias InboundIn = ByteBuffer

  private let limit: Int
  private var context: ChannelHandlerContext?
  private var inFlight = false
  /// Bytes read while requests were in flight since the pipeline handler's buffer was empty.
  private var received = 0

  init(limit: Int) {
    self.limit = limit
  }

  func handlerAdded(context: ChannelHandlerContext) {
    self.context = context
  }

  func handlerRemoved(context: ChannelHandlerContext) {
    self.context = nil
  }

  func requestStarted() {
    inFlight = true
    context?.read()
  }

  func requestFinished() {
    inFlight = false
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    if inFlight {
      received += Self.unwrapInboundIn(data).readableBytes
      guard received <= limit else {
        context.close(promise: nil)
        return
      }
    } else {
      received = 0
    }
    context.fireChannelRead(data)
  }

  func channelReadComplete(context: ChannelHandlerContext) {
    if inFlight { context.read() }
    context.fireChannelReadComplete()
  }
}

/// One per connection, confined to its event loop. The HTTP pipeline handler serializes
/// pipelined requests, so at most one is in flight here. The decoder hands over a head only once
/// complete, so a head still streaming is bounded by the first-request or keep-alive timer.
private nonisolated final class MCPHTTPConnectionHandler: ChannelInboundHandler {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart

  private let validator: MCPRequestValidator
  private let handler: MCPHTTPServer.Handler
  private let tasks: MCPRequestTasks
  private let reader: MCPInFlightReader
  /// Set once the head passed validation; nil while refusing the rest of a request.
  private var head: HTTPRequestHead?
  /// What `head` asks for
  private var route = MCPRoute.mcp(caller: .mcp)
  private var body = ByteBuffer()
  /// The handler task of the request in flight, cancelled when the client goes away
  private var inFlight: Task<Void, Never>?
  /// Holds a connection slot, taken at the first valid request head; over the cap that request
  /// is answered `busy`.
  private var counted = false
  /// Supplies the timer durations.
  private let configuration: MCPHTTPServer.Configuration
  /// Closes the connection when it fires; never armed while `inFlight` is set.
  private var timer: Scheduled<Void>?

  init(
    validator: MCPRequestValidator, handler: @escaping MCPHTTPServer.Handler,
    tasks: MCPRequestTasks, reader: MCPInFlightReader,
    configuration: MCPHTTPServer.Configuration
  ) {
    self.validator = validator
    self.handler = handler
    self.tasks = tasks
    self.reader = reader
    self.configuration = configuration
  }

  func handlerAdded(context: ChannelHandlerContext) {
    if context.channel.isActive { arm(configuration.firstRequestTimeout, context: context) }
  }

  func channelActive(context: ChannelHandlerContext) {
    if timer == nil { arm(configuration.firstRequestTimeout, context: context) }
    context.fireChannelActive()
  }

  func handlerRemoved(context: ChannelHandlerContext) {
    disarm()
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch Self.unwrapInboundIn(data) {
    case .head(let head):
      body.clear()
      switch validator.validate(head) {
      case .proceed(let route):
        // The command-line tool's routes take no connection slot
        if !counted && !route.isCLI { counted = tasks.openConnection() }
        if counted || route.isCLI {
          self.head = head
          self.route = route
          arm(configuration.readTimeout, context: context)
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
      guard body.readableBytes + chunk.readableBytes <= validator.bodyLimit(of: route) else {
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
      dispatch(head, route: route, body: Data(body.readableBytesView), context: context)
      body = ByteBuffer()
    }
  }

  /// Fires on every close (peer close, reset, error or our own), so the slot never leaks.
  func channelInactive(context: ChannelHandlerContext) {
    if counted { tasks.closeConnection() }
    counted = false
    disarm()
    inFlight?.cancel()
    inFlight = nil
    context.fireChannelInactive()
  }

  private func dispatch(
    _ head: HTTPRequestHead, route: MCPRoute, body: Data, context: ChannelHandlerContext
  ) {
    var headers: [String: String] = [:]
    for (name, value) in head.headers {
      headers[name] = headers[name].map { "\($0), \(value)" } ?? value
    }
    var caller: MCPCallerKind?
    if case .mcp(let kind) = route { caller = kind }
    let request = MCPHTTPRequest(
      method: head.method.rawValue, path: route.path, headers: headers, body: body,
      caller: caller, port: validator.port)
    let handler = self.handler
    let eventLoop = context.eventLoop
    let bound = NIOLoopBound(context, eventLoop: eventLoop)
    let version = head.version
    let takesSlot = !route.isCLI
    // The command-line tool's routes close their connection after the answer
    let keepAlive = head.isKeepAlive && takesSlot
    let connection = NIOLoopBound(self, eventLoop: eventLoop)
    let tasks = self.tasks
    let keepAliveTimeout = configuration.keepAliveTimeout
    let start = tasks.run(takesSlot: takesSlot) {
      let response = await handler(request)
      // Freed before the write, so a client that got its answer finds the slot free.
      if takesSlot { tasks.finishRequest() }
      eventLoop.execute {
        connection.value.inFlight = nil
        connection.value.reader.requestFinished()
        // Armed before the write, which may hand over the next pipelined head.
        if keepAlive, bound.value.channel.isActive {
          connection.value.arm(keepAliveTimeout, context: bound.value)
        }
        Self.write(response, version: version, keepAlive: keepAlive, context: bound.value)
      }
    }
    switch start {
    case .started(let task):
      disarm()
      inFlight = task
      reader.requestStarted()
    case .busy:
      Self.write(.busy, version: version, keepAlive: false, context: context)
    case .stopping:
      context.close(promise: nil)
    }
  }

  /// Replaces the pending timer with one that closes the connection after `timeout`.
  private func arm(_ timeout: TimeAmount, context: ChannelHandlerContext) {
    timer?.cancel()
    let channel = context.channel
    timer = context.eventLoop.assumeIsolated().scheduleTask(in: timeout) {
      channel.close(promise: nil)
    }
  }

  private func disarm() {
    timer?.cancel()
    timer = nil
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
