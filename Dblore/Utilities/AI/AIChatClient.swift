// AIChatClient.swift
// Provider-agnostic chat client protocol, factory and shared SSE line streaming

import Foundation

nonisolated struct AIChatMessage: Sendable, Equatable {
  enum Role: String, Sendable { case user, assistant }
  let role: Role
  let text: String
}

nonisolated struct AIChatRequest: Sendable {
  var model: String
  var system: String
  var messages: [AIChatMessage]
  var maxTokens: Int = 2048
}

nonisolated enum AIStreamEvent: Sendable, Equatable {
  case text(String)
}

nonisolated enum AIClientError: LocalizedError, Equatable, Sendable {
  case missingAPIKey
  case missingModel
  case invalidEndpoint(String)
  case http(status: Int, message: String)
  case transport(String)

  var errorDescription: String? {
    switch self {
    case .missingAPIKey: return "Add an API key in Settings > AI."
    case .missingModel: return "Choose a model in Settings > AI."
    case .invalidEndpoint(let message): return message
    case .http(let status, let message):
      return message.isEmpty ? "The provider returned HTTP \(status)." : message
    case .transport(let message): return message
    }
  }
}

nonisolated protocol AIChatClient: Sendable {
  func stream(_ request: AIChatRequest) -> AsyncThrowingStream<AIStreamEvent, Error>
  func listModels() async throws -> [String]
  /// Like `listModels`, also reporting whether the built-in fallback list was used
  func listModelsResult() async throws -> AIModelListResult
}

nonisolated struct AIModelListResult: Sendable, Equatable {
  var models: [String]
  /// True when the models endpoint was missing and the built-in list was returned instead
  var isFallback: Bool
}

extension AIChatClient {
  func listModelsResult() async throws -> AIModelListResult {
    AIModelListResult(models: try await listModels(), isFallback: false)
  }
}

nonisolated enum AIClientFactory {
  static func make(
    kind: AIProviderKind, config: AIProviderConfig, apiKey: String?,
    session: URLSession = .shared
  ) throws -> any AIChatClient {
    let base: URL
    do {
      base = try AIEndpoint.normalize(config.baseURL)
    } catch {
      throw AIClientError.invalidEndpoint(error.localizedDescription)
    }
    let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if kind.requiresAPIKey && key.isEmpty { throw AIClientError.missingAPIKey }
    switch kind.wire {
    case .anthropicMessages: return AnthropicClient(baseURL: base, apiKey: key, session: session)
    case .chatCompletions:
      return OpenAICompatibleClient(baseURL: base, apiKey: key, session: session)
    }
  }

  /// Max bytes of an error response body that are read and shown
  static let errorBodyLimit = 4096

  /// Streams an SSE response. Iterates raw bytes because `AsyncBytes.lines` drops the empty
  /// lines that `AISSEParser` needs to dispatch events.
  static func streamLines(
    _ request: URLRequest, session: URLSession, parser: AISSEParser
  ) -> AsyncThrowingStream<AIStreamEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let (bytes, response) = try await session.bytes(for: request, delegate: AIRedirectGuard())
          if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = try await collectBody(bytes)
            throw AIClientError.http(
              status: http.statusCode, message: errorMessage(from: body))
          }
          var parser = parser
          var buffer = Data()
          for try await byte in bytes {
            try Task.checkCancellation()
            if byte != 0x0A {
              buffer.append(byte)
              continue
            }
            if try feed(&buffer, parser: &parser, continuation: continuation) { return }
          }
          if !buffer.isEmpty, try feed(&buffer, parser: &parser, continuation: continuation) {
            return
          }
          // Flush an event left unterminated at end of stream
          for delta in try parser.consume(line: "") {
            if yield(delta, continuation) { return }
          }
          continuation.finish()
        } catch is CancellationError {
          continuation.finish()
        } catch let error as AIClientError {
          continuation.finish(throwing: error)
        } catch let error as URLError where error.code == .cancelled {
          continuation.finish()
        } catch let error as AIStreamError {
          continuation.finish(throwing: error)
        } catch {
          continuation.finish(throwing: AIClientError.transport(error.localizedDescription))
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Parses one buffered line; returns true when the stream is done and has been finished
  private static func feed(
    _ buffer: inout Data, parser: inout AISSEParser,
    continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
  ) throws -> Bool {
    if buffer.last == 0x0D { buffer.removeLast() }
    let line = String(decoding: buffer, as: UTF8.self)
    buffer.removeAll(keepingCapacity: true)
    for delta in try parser.consume(line: line) {
      if yield(delta, continuation) { return true }
    }
    return false
  }

  /// Returns true when the delta ended the stream
  private static func yield(
    _ delta: AIStreamDelta, _ continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
  ) -> Bool {
    switch delta {
    case .text(let text):
      continuation.yield(.text(text))
      return false
    case .done:
      continuation.finish()
      return true
    }
  }

  private static func collectBody(_ bytes: URLSession.AsyncBytes) async throws -> Data {
    var body = Data()
    for try await byte in bytes {
      body.append(byte)
      if body.count >= errorBodyLimit { break }
    }
    return body
  }

  /// Extracts `error.message`, `error` (string) or `message` from a JSON body, else the raw text
  static func errorMessage(from body: Data) -> String {
    if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
      if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
        return message
      }
      if let text = object["error"] as? String { return text }
      if let text = object["message"] as? String { return text }
    }
    return String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// Refuses redirects to another host or from https to http, so credentials headers are never
/// forwarded to an unexpected destination.
nonisolated final class AIRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
  static func allows(from original: URL, to target: URL) -> Bool {
    guard original.host?.lowercased() == target.host?.lowercased() else { return false }
    if original.scheme?.lowercased() == "https" && target.scheme?.lowercased() != "https" {
      return false
    }
    return true
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    guard let from = task.originalRequest?.url ?? response.url, let to = request.url,
      Self.allows(from: from, to: to)
    else { return completionHandler(nil) }
    completionHandler(request)
  }
}
