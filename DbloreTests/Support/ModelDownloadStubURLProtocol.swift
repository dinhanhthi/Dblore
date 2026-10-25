// ModelDownloadStubURLProtocol.swift
// URLProtocol stub for the on-device model downloader tests. State is static, so the one suite
// that uses it is `.serialized`.

import Foundation

final class ModelDownloadStubURLProtocol: URLProtocol, @unchecked Sendable {
  enum Reply: Sendable {
    /// This status with this body, then finish.
    case respond(status: Int, body: Data)
    /// 302 to this URL. After telling the client, the stub still delivers the 302 and finishes:
    /// a refused redirect then ends the task with the 302 as a real server does (stopping after
    /// the redirect call hangs the task; finishing without a response traps in the async
    /// download API). A followed redirect starts a new load and ignores the rest.
    case redirect(URL)
  }

  typealias Handler = @Sendable (URL) -> Reply

  private nonisolated(unsafe) static var storedHandler: Handler?
  private nonisolated(unsafe) static var storedURLs: [URL] = []
  private static let lock = NSLock()

  static var handler: Handler? {
    get { lock.withLock { storedHandler } }
    set { lock.withLock { storedHandler = newValue } }
  }

  /// Every URL requested since the last reset, in order.
  static var requestedURLs: [URL] { lock.withLock { storedURLs } }

  static func reset() {
    lock.withLock {
      storedHandler = nil
      storedURLs = []
    }
  }

  static func makeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ModelDownloadStubURLProtocol.self]
    return URLSession(configuration: config)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    Self.lock.withLock { Self.storedURLs.append(url) }
    guard let handler = Self.handler else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    switch handler(url) {
    case .respond(let status, let body):
      let response = HTTPURLResponse(
        url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: body)
      client?.urlProtocolDidFinishLoading(self)
    case .redirect(let target):
      let response = HTTPURLResponse(
        url: url, statusCode: 302, httpVersion: "HTTP/1.1",
        headerFields: ["Location": target.absoluteString])!
      client?.urlProtocol(
        self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  override func stopLoading() {}
}
