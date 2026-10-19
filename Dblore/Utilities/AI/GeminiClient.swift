// GeminiClient.swift
// Google Gemini API client (streamGenerateContent + model list)

import Foundation

nonisolated struct GeminiClient: AIChatClient {
  let baseURL: URL
  let apiKey: String
  var session: URLSession = .shared
  var supportsNativeTools: Bool { true }

  /// The key goes in this header only, never in the URL, so it stays out of URL logs
  static let apiKeyHeader = "x-goog-api-key"

  static func makeRequest(
    _ request: AIChatRequest, baseURL: URL, apiKey: String
  ) throws(AIClientError) -> URLRequest {
    guard !request.model.isEmpty else { throw .missingModel }
    let url: URL
    do {
      url = try AIEndpoint.geminiStreamURL(base: baseURL, model: request.model)
    } catch {
      throw .invalidEndpoint(error.localizedDescription)
    }
    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = "POST"
    applyHeaders(&urlRequest, apiKey: apiKey)
    urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
    // No `generationConfig.maxOutputTokens`: on thinking models the cap also counts thinking
    // tokens, so a small cap like the 2048 default could be spent before any answer (the
    // model's own limit applies instead, as for api.openai.com).
    var body: [String: Any] = ["contents": contents(request.messages)]
    if !request.system.isEmpty {
      body["systemInstruction"] = ["parts": [["text": request.system]]]
    }
    if !request.tools.isEmpty {
      // `parametersJsonSchema` takes the JSON Schema as is (`parameters` is Gemini's own
      // schema subset)
      let declarations = request.tools.map { tool -> [String: Any] in
        [
          "name": tool.name, "description": tool.description,
          "parametersJsonSchema": tool.parametersObject,
        ]
      }
      body["tools"] = [["functionDeclarations": declarations]]
    }
    urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)
    return urlRequest
  }

  /// Roles map to `user` / `model`. A model turn keeps its block order: each tool call is one
  /// `functionCall` part with its `thoughtSignature` beside it, unchanged. Tool results become
  /// `functionResponse` parts placed first in their user turn (all calls, then all responses),
  /// named after the call with the same id earlier in the conversation; a result without such
  /// a call is dropped, as is a stored call whose arguments do not parse back (and its result).
  private static func contents(_ messages: [AIChatMessage]) -> [[String: Any]] {
    var names: [String: String] = [:]
    return messages.compactMap { message -> [String: Any]? in
      var responses: [[String: Any]] = []
      var parts: [[String: Any]] = []
      for block in message.blocks {
        switch block {
        case .text(let text):
          if !text.isEmpty { parts.append(["text": text]) }
        case .toolUse(let call):
          guard let part = functionCallPart(call) else { continue }
          names[call.id] = call.name
          parts.append(part)
        case .toolResult(let result):
          guard let name = names[result.id] else { continue }
          var response: [String: Any] = [
            "name": name, "response": [result.isError ? "error" : "result": result.content],
          ]
          if let id = providerID(result.id) { response["id"] = id }
          responses.append(["functionResponse": response])
        }
      }
      let all = responses + parts
      guard !all.isEmpty else { return nil }
      return ["role": message.role == .assistant ? "model" : "user", "parts": all]
    }
  }

  /// `inputJSON` is the canonical object the parser validated; nil when it does not parse back
  private static func functionCallPart(_ call: AIToolCall) -> [String: Any]? {
    guard
      let args = try? JSONSerialization.jsonObject(with: Data(call.inputJSON.utf8))
        as? [String: Any],
      JSONSerialization.isValidJSONObject(args)
    else { return nil }
    var functionCall: [String: Any] = ["name": call.name, "args": args]
    if let id = providerID(call.id) { functionCall["id"] = id }
    var part: [String: Any] = ["functionCall": functionCall]
    if let signature = call.signature { part["thoughtSignature"] = signature }
    return part
  }

  /// The id to send back; nil for an id made locally (the provider never issued it)
  private static func providerID(_ id: String) -> String? {
    id.hasPrefix(AISSEParser.localToolIDPrefix) ? nil : id
  }

  func stream(_ request: AIChatRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
    let urlRequest: URLRequest
    do {
      urlRequest = try Self.makeRequest(request, baseURL: baseURL, apiKey: apiKey)
    } catch {
      return AsyncThrowingStream { $0.finish(throwing: error) }
    }
    return AIClientFactory.streamLines(
      urlRequest, session: session,
      parser: AISSEParser(
        wire: .geminiGenerateContent, toolNames: Set(request.tools.map(\.name))))
  }

  /// `GET /models?pageSize=1000` (the documented max, so one page) ->
  /// `{"models":[{"name":"models/<id>","supportedGenerationMethods":[...]}]}`. Keeps the models
  /// that support `generateContent` (all when the field is absent) with a usable id, shown
  /// without the `models/` prefix.
  func listModels() async throws -> [String] {
    var components = URLComponents(
      url: AIEndpoint.modelsURL(base: baseURL), resolvingAgainstBaseURL: false)
    components?.queryItems = [URLQueryItem(name: "pageSize", value: "1000")]
    guard let url = components?.url else {
      throw AIClientError.invalidEndpoint(AIEndpointError.invalidURL.localizedDescription)
    }
    var urlRequest = URLRequest(url: url)
    Self.applyHeaders(&urlRequest, apiKey: apiKey)
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: urlRequest, delegate: AIRedirectGuard())
    } catch {
      throw AIClientError.transport(error.localizedDescription)
    }
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw AIClientError.http(
        status: http.statusCode,
        message: AIClientFactory.errorMessage(from: data.prefix(AIClientFactory.errorBodyLimit)))
    }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw AIClientError.transport("Unexpected models response.")
    }
    let items = object["models"] as? [[String: Any]] ?? []
    return items.compactMap { item in
      if let methods = item["supportedGenerationMethods"] as? [String],
        !methods.contains("generateContent")
      {
        return nil
      }
      return (item["name"] as? String).flatMap(AIEndpoint.geminiModelID)
    }
  }

  private static func applyHeaders(_ request: inout URLRequest, apiKey: String) {
    request.setValue(apiKey, forHTTPHeaderField: apiKeyHeader)
  }
}
