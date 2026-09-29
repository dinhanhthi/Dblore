// AnthropicClient.swift
// Anthropic Messages API client (streaming + model list)

import Foundation

nonisolated struct AnthropicClient: AIChatClient {
  let baseURL: URL
  let apiKey: String
  var session: URLSession = .shared

  /// Required by the Messages API (docs.anthropic.com, verified 2026-09)
  static let apiVersion = "2023-06-01"

  static func makeRequest(_ request: AIChatRequest, baseURL: URL, apiKey: String) -> URLRequest {
    var urlRequest = URLRequest(url: AIEndpoint.chatURL(base: baseURL, wire: .anthropicMessages))
    urlRequest.httpMethod = "POST"
    applyHeaders(&urlRequest, apiKey: apiKey)
    urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
    let body: [String: Any] = [
      "model": request.model,
      "system": request.system,
      "messages": request.messages.map { ["role": $0.role.rawValue, "content": $0.text] },
      "max_tokens": request.maxTokens,
      "stream": true,
    ]
    urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)
    return urlRequest
  }

  func stream(_ request: AIChatRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
    AIClientFactory.streamLines(
      Self.makeRequest(request, baseURL: baseURL, apiKey: apiKey), session: session,
      parser: AISSEParser(wire: .anthropicMessages))
  }

  /// `GET /models` -> `{"data":[{"id":...}], "has_more":...}`; 404 falls back to the built-in list
  func listModels() async throws -> [String] {
    try await listModelsResult().models
  }

  func listModelsResult() async throws -> AIModelListResult {
    var urlRequest = URLRequest(url: AIEndpoint.modelsURL(base: baseURL))
    Self.applyHeaders(&urlRequest, apiKey: apiKey)
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: urlRequest, delegate: AIRedirectGuard())
    } catch {
      throw AIClientError.transport(error.localizedDescription)
    }
    if let http = response as? HTTPURLResponse {
      if http.statusCode == 404 {
        return AIModelListResult(models: AIProviderKind.anthropic.fallbackModels, isFallback: true)
      }
      if !(200..<300).contains(http.statusCode) {
        throw AIClientError.http(
          status: http.statusCode,
          message: AIClientFactory.errorMessage(from: data.prefix(AIClientFactory.errorBodyLimit)))
      }
    }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let items = object["data"] as? [[String: Any]]
    else { throw AIClientError.transport("Unexpected models response.") }
    return AIModelListResult(models: items.compactMap { $0["id"] as? String }, isFallback: false)
  }

  private static func applyHeaders(_ request: inout URLRequest, apiKey: String) {
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
  }
}
