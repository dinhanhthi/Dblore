// OpenAICompatibleClient.swift
// OpenAI chat-completions client (OpenAI, OpenRouter, Ollama, LM Studio, mlx_lm.server, custom)

import Foundation

nonisolated struct OpenAICompatibleClient: AIChatClient {
  let baseURL: URL
  let apiKey: String
  var session: URLSession = .shared

  /// Ollama's default OpenAI-compatible endpoint
  static let ollamaBaseURL = URL(string: "http://127.0.0.1:11434/v1")!

  static func makeRequest(_ request: AIChatRequest, baseURL: URL, apiKey: String) -> URLRequest {
    var urlRequest = URLRequest(url: AIEndpoint.chatURL(base: baseURL, wire: .chatCompletions))
    urlRequest.httpMethod = "POST"
    applyHeaders(&urlRequest, apiKey: apiKey)
    urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
    var messages: [[String: String]] = []
    if !request.system.isEmpty { messages.append(["role": "system", "content": request.system]) }
    messages += request.messages.map { ["role": $0.role.rawValue, "content": $0.text] }
    var body: [String: Any] = [
      "model": request.model,
      "messages": messages,
      "stream": true,
    ]
    // api.openai.com rejects `max_tokens` on o-series / GPT-5+ models; its replacement
    // `max_completion_tokens` also counts hidden reasoning tokens, so a small cap like the
    // 2048 default could be spent entirely on reasoning and return empty output. No cap is
    // sent there (the API default). Other OpenAI-compatible servers still get `max_tokens`.
    if !isOpenAI(baseURL) { body["max_tokens"] = request.maxTokens }
    urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)
    return urlRequest
  }

  /// True when the request goes to the hosted OpenAI API
  static func isOpenAI(_ baseURL: URL) -> Bool {
    baseURL.host?.lowercased() == "api.openai.com"
  }

  func stream(_ request: AIChatRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
    AIClientFactory.streamLines(
      Self.makeRequest(request, baseURL: baseURL, apiKey: apiKey), session: session,
      parser: AISSEParser(wire: .chatCompletions))
  }

  /// `GET /models` -> `{"object":"list","data":[{"id":...}]}` (OpenAI, verified shape)
  func listModels() async throws -> [String] {
    var urlRequest = URLRequest(url: AIEndpoint.modelsURL(base: baseURL))
    Self.applyHeaders(&urlRequest, apiKey: apiKey)
    return try await Self.fetchModels(urlRequest, session: session)
  }

  /// Probes a local Ollama; nil on any failure or when no models are installed
  static func detectOllama(session: URLSession = .shared) async -> [String]? {
    var urlRequest = URLRequest(url: AIEndpoint.modelsURL(base: ollamaBaseURL))
    urlRequest.timeoutInterval = 2
    guard let models = try? await fetchModels(urlRequest, session: session), !models.isEmpty
    else { return nil }
    return models
  }

  private static func fetchModels(
    _ request: URLRequest, session: URLSession
  ) async throws
    -> [String]
  {
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request, delegate: AIRedirectGuard())
    } catch {
      throw AIClientError.transport(error.localizedDescription)
    }
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw AIClientError.http(
        status: http.statusCode,
        message: AIClientFactory.errorMessage(from: data.prefix(AIClientFactory.errorBodyLimit)))
    }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let items = object["data"] as? [[String: Any]]
    else { throw AIClientError.transport("Unexpected models response.") }
    return items.compactMap { $0["id"] as? String }.sorted()
  }

  private static func applyHeaders(_ request: inout URLRequest, apiKey: String) {
    guard !apiKey.isEmpty else { return }
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
  }
}
