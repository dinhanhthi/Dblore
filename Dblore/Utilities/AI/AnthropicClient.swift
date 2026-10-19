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
    var body: [String: Any] = [
      "model": request.model,
      "system": request.system,
      "messages": request.messages.map(messageObject),
      "max_tokens": request.maxTokens,
      "stream": true,
    ]
    if !request.tools.isEmpty {
      body["tools"] = request.tools.map {
        ["name": $0.name, "description": $0.description, "input_schema": $0.parametersObject]
      }
    }
    urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)
    return urlRequest
  }

  /// A text-only message keeps a string `content`; one with tool blocks sends a block array,
  /// `tool_result` blocks first as the Messages API requires
  private static func messageObject(_ message: AIChatMessage) -> [String: Any] {
    guard message.hasToolBlocks else {
      return ["role": message.role.rawValue, "content": message.text]
    }
    let results = message.blocks.filter { block in
      if case .toolResult = block { return true }
      return false
    }
    let others = message.blocks.filter { block in
      if case .toolResult = block { return false }
      return true
    }
    let content = (results + others).compactMap { block -> [String: Any]? in
      switch block {
      case .text(let text):
        return text.isEmpty ? nil : ["type": "text", "text": text]
      case .toolUse(let call):
        // `inputJSON` is the canonical object the parser validated. A stored call that does not
        // parse back is dropped rather than sent as a different call; the provider then refuses
        // its unmatched `tool_result`.
        guard
          let input = try? JSONSerialization.jsonObject(with: Data(call.inputJSON.utf8))
            as? [String: Any],
          JSONSerialization.isValidJSONObject(input)
        else { return nil }
        return ["type": "tool_use", "id": call.id, "name": call.name, "input": input]
      case .toolResult(let result):
        var object: [String: Any] = [
          "type": "tool_result", "tool_use_id": result.id, "content": result.content,
        ]
        if result.isError { object["is_error"] = true }
        return object
      }
    }
    return ["role": message.role.rawValue, "content": content]
  }

  func stream(_ request: AIChatRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
    AIClientFactory.streamLines(
      Self.makeRequest(request, baseURL: baseURL, apiKey: apiKey), session: session,
      parser: AISSEParser(wire: .anthropicMessages, toolNames: Set(request.tools.map(\.name))))
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
