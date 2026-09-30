import Foundation
import Testing

/// URLProtocol stub for AI client tests. State is static: suites using it must be `.serialized`.
final class AIStubURLProtocol: URLProtocol, @unchecked Sendable {
  typealias Handler = @Sendable (URLRequest) -> (Int, [Data])

  private nonisolated(unsafe) static var storedHandler: Handler?
  private nonisolated(unsafe) static var storedRequest: URLRequest?
  private nonisolated(unsafe) static var storedBody: Data?
  private static let lock = NSLock()

  static var handler: Handler? {
    get { lock.withLock { storedHandler } }
    set { lock.withLock { storedHandler = newValue } }
  }

  /// The last request seen, with `httpBody` populated from `httpBodyStream` when needed
  static var lastRequest: URLRequest? { lock.withLock { storedRequest } }
  static var lastBody: Data? { lock.withLock { storedBody } }

  static func reset() {
    lock.withLock {
      storedHandler = nil
      storedRequest = nil
      storedBody = nil
    }
  }

  static func makeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [AIStubURLProtocol.self]
    return URLSession(configuration: config)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let body = request.httpBody ?? request.httpBodyStream.map(Self.readAll)
    Self.lock.withLock {
      Self.storedRequest = request
      Self.storedBody = body
    }
    guard let handler = Self.handler, let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    let (status, chunks) = handler(request)
    let response = HTTPURLResponse(
      url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  private static func readAll(_ stream: InputStream) -> Data {
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count <= 0 { break }
      data.append(buffer, count: count)
    }
    return data
  }
}

/// Serializes tests across every suite that uses the static stub handler; `.serialized` alone
/// only orders tests within one suite.
actor AIStubGate {
  static let shared = AIStubGate()
  private var busy = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func acquire() async {
    if !busy {
      busy = true
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }

  func release() {
    if waiters.isEmpty {
      busy = false
    } else {
      waiters.removeFirst().resume()
    }
  }
}

nonisolated struct AIStubScope: SuiteTrait, TestScoping {
  /// Applied once around the whole suite, so suites never overlap
  func provideScope(
    for test: Test, testCase: Test.Case?,
    performing function: @concurrent @Sendable () async throws -> Void
  ) async throws {
    await AIStubGate.shared.acquire()
    do {
      try await function()
    } catch {
      await AIStubGate.shared.release()
      throw error
    }
    await AIStubGate.shared.release()
  }
}
