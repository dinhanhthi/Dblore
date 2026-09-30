// OAuthLoopbackServer.swift
// One-shot HTTP listener on 127.0.0.1 that receives the OAuth redirect for "Sign in with ChatGPT"

import Foundation
import Network

/// Usage: `let port = try await server.start()`, open the authorize URL built for `port`, then
/// `try await server.waitForCallback(expectedState:)`. All mutable state is confined to `queue`.
nonisolated final class OAuthLoopbackServer: @unchecked Sendable {
  static let defaultPorts = [1455, 1457]
  static let defaultTimeout: TimeInterval = 180

  private static let maxRequestBytes = 8 * 1024
  private static let readTimeout: TimeInterval = 5

  private let ports: [Int]
  private let queue = DispatchQueue(label: "dblore.oauth-loopback")

  // Confined to `queue`
  private var listener: NWListener?
  private var expectedState: String?
  private var continuation: CheckedContinuation<String, Error>?
  private var outcome: Result<String, Error>?
  private var deferredRequests: [() -> Void] = []

  init(ports: [Int] = OAuthLoopbackServer.defaultPorts) {
    self.ports = ports
  }

  /// Binds the first free port (127.0.0.1 only) and returns it. Throws `.portInUse` if none is free.
  func start() async throws -> Int {
    for port in ports {
      if let bound = await bind(port: port) { return bound }
    }
    throw ChatGPTOAuthError.portInUse
  }

  /// Waits for `GET /auth/callback` with a matching state and returns the authorization code.
  func waitForCallback(
    expectedState: String, timeout: TimeInterval = OAuthLoopbackServer.defaultTimeout
  ) async throws -> String {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<String, Error>) in
        queue.async {
          self.expectedState = expectedState
          if let outcome = self.outcome {
            continuation.resume(with: outcome)
            return
          }
          self.continuation = continuation
          let pending = self.deferredRequests
          self.deferredRequests = []
          pending.forEach { $0() }
          self.queue.asyncAfter(deadline: .now() + timeout) {
            self.finish(.failure(ChatGPTOAuthError.denied("timeout")))
          }
        }
      }
    } onCancel: {
      queue.async { self.finish(.failure(CancellationError())) }
    }
  }

  /// Stops listening and frees the port. Safe to call repeatedly.
  func cancel() {
    queue.async { self.finish(.failure(CancellationError())) }
  }

  // MARK: - Binding

  private func bind(port: Int) async -> Int? {
    guard let rawPort = UInt16(exactly: port), let nwPort = NWEndpoint.Port(rawValue: rawPort)
    else { return nil }
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
    parameters.requiredInterfaceType = .loopback
    guard let listener = try? NWListener(using: parameters) else { return nil }

    let boundPort: Int? = await withCheckedContinuation { continuation in
      let resumed = Flag()
      listener.stateUpdateHandler = { state in
        guard !resumed.value else { return }
        switch state {
        case .ready:
          resumed.value = true
          continuation.resume(returning: Int(listener.port?.rawValue ?? rawPort))
        case .failed, .cancelled:
          resumed.value = true
          continuation.resume(returning: nil)
        default:
          break
        }
      }
      listener.newConnectionHandler = { [self] connection in
        handle(connection)
      }
      listener.start(queue: queue)
    }

    guard let boundPort else {
      listener.cancel()
      return nil
    }
    queue.async {
      self.listener = listener
      // A listener that dies later ends the wait
      listener.stateUpdateHandler = { [self] state in
        if case .failed = state { finish(.failure(ChatGPTOAuthError.portInUse)) }
      }
      if self.outcome != nil { listener.cancel() }
    }
    return boundPort
  }

  // MARK: - Connections (run on `queue`)

  private func handle(_ connection: NWConnection) {
    guard outcome == nil else {
      connection.cancel()
      return
    }
    connection.start(queue: queue)
    queue.asyncAfter(deadline: .now() + Self.readTimeout) { connection.cancel() }
    readRequestLine(connection, buffer: Data())
  }

  private func readRequestLine(_ connection: NWConnection, buffer: Data) {
    let room = Self.maxRequestBytes - buffer.count
    guard room > 0 else {
      respond(connection, status: "431 Request Header Fields Too Large", body: Self.errorPage)
      return
    }
    connection.receive(minimumIncompleteLength: 1, maximumLength: room) {
      [self] data, _, isComplete, error in
      var buffer = buffer
      if let data { buffer.append(data) }
      if let end = buffer.firstRange(of: Data("\r\n".utf8)) {
        let line = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        handleRequest(line, on: connection)
      } else if error != nil || isComplete {
        connection.cancel()
      } else {
        readRequestLine(connection, buffer: buffer)
      }
    }
  }

  private func handleRequest(_ requestLine: String, on connection: NWConnection) {
    guard isCallbackRequest(requestLine) else {
      respond(connection, status: "404 Not Found", body: Self.errorPage)
      return
    }
    guard let expectedState else {
      // Callback arrived before waitForCallback: answer once the state is known
      deferredRequests.append { [self] in handleRequest(requestLine, on: connection) }
      return
    }
    switch ChatGPTOAuth.parseCallback(requestLine: requestLine, expectedState: expectedState) {
    case .success(let code):
      respond(connection, status: "200 OK", body: Self.successPage)
      finish(.success(code))
    case .failure(.denied(let reason)):
      respond(connection, status: "400 Bad Request", body: Self.errorPage)
      finish(.failure(ChatGPTOAuthError.denied(reason)))
    case .failure:
      // Wrong state or malformed: do not consume the one-shot, so a stray request cannot abort sign-in
      respond(connection, status: "400 Bad Request", body: Self.errorPage)
    }
  }

  private func isCallbackRequest(_ requestLine: String) -> Bool {
    let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
    guard parts.count >= 2, parts[0] == "GET" else { return false }
    let path = parts[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
    return path == ChatGPTOAuth.callbackPath
  }

  private func respond(_ connection: NWConnection, status: String, body: String) {
    let payload = Data(body.utf8)
    let head =
      "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
      + "Content-Length: \(payload.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
    connection.send(
      content: Data(head.utf8) + payload, contentContext: .finalMessage, isComplete: true,
      completion: .contentProcessed { _ in connection.cancel() })
  }

  /// Ends the session exactly once: stops the listener (frees the port) and resolves the waiter
  private func finish(_ result: Result<String, Error>) {
    guard outcome == nil else { return }
    outcome = result
    listener?.cancel()
    listener = nil
    deferredRequests = []
    continuation?.resume(with: result)
    continuation = nil
  }

  /// Mutated only from the listener's state handler, which runs on `queue`
  private final class Flag: @unchecked Sendable { var value = false }

  // MARK: - Static pages (never include request data)

  private static let successPage = page("Signed in - you can close this tab.")
  private static let errorPage = page("Sign-in failed. Return to Dblore and try again.")

  private static func page(_ message: String) -> String {
    "<!doctype html><html><head><meta charset=\"utf-8\"><title>Dblore</title></head>"
      + "<body style=\"font-family:-apple-system,sans-serif;text-align:center;margin-top:20vh\">"
      + "<p>\(message)</p></body></html>"
  }
}
