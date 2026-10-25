// PluginStubURLProtocol.swift
// URLProtocol stub for plugin downloads, shared by PluginManagerTests and the gated
// LocalAIBundleGatedTests. State is static, so each suite that uses it is `.serialized`, and two
// such suites must not run in one process at the same time: PluginManagerTests runs ungated, and
// the gated suite runs alone (`-only-testing`) under its own gate.

import Foundation

final class PluginStubURLProtocol: URLProtocol, @unchecked Sendable {
  enum Mode {
    /// Status 200 with these chunks, then finish.
    case respond([Data])
    /// Status 200, one chunk, then never finish until the task is cancelled.
    case hang(Data)
  }

  private nonisolated(unsafe) static var storedMode: Mode = .respond([])
  private nonisolated(unsafe) static var storedRequestCount = 0
  private static let lock = NSLock()

  static var mode: Mode {
    get { lock.withLock { storedMode } }
    set { lock.withLock { storedMode = newValue } }
  }

  /// Requests started since the last reset.
  static var requestCount: Int {
    get { lock.withLock { storedRequestCount } }
    set { lock.withLock { storedRequestCount = newValue } }
  }

  static func makeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [PluginStubURLProtocol.self]
    return URLSession(configuration: config)
  }

  /// `.respond` with `data` in 1 MiB chunks.
  static func respond(with data: Data) {
    let chunk = 1 << 20
    mode = .respond(
      stride(from: 0, to: data.count, by: chunk).map {
        data.subdata(in: $0..<min($0 + chunk, data.count))
      })
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url else { return }
    Self.requestCount += 1
    let response = HTTPURLResponse(
      url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    switch Self.mode {
    case .respond(let chunks):
      for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
      client?.urlProtocolDidFinishLoading(self)
    case .hang(let chunk):
      client?.urlProtocol(self, didLoad: chunk)
    }
  }

  override func stopLoading() {}
}
