import Foundation
import Testing

@testable import Dblore

@Suite("OpenAICompatibleClient", .serialized, AIStubScope())
struct OpenAICompatibleClientTests {

  private let base = URL(string: "http://127.0.0.1:11434/v1")!

  private func client(apiKey: String = "") -> OpenAICompatibleClient {
    OpenAICompatibleClient(
      baseURL: base, apiKey: apiKey, session: AIStubURLProtocol.makeSession())
  }

  private func request() -> AIChatRequest {
    AIChatRequest(
      model: "llama3", system: "Be brief.",
      messages: [AIChatMessage(role: .user, text: "hi")], maxTokens: 100)
  }

  private func collect(_ stream: AsyncThrowingStream<AIStreamEvent, Error>) async throws -> String {
    var text = ""
    for try await case .text(let piece) in stream { text += piece }
    return text
  }

  @Test("no Authorization header without a key")
  func noAuthWithoutKey() {
    let urlRequest = OpenAICompatibleClient.makeRequest(request(), baseURL: base, apiKey: "")
    #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == nil)
  }

  @Test("Authorization header carries the key")
  func authWithKey() {
    let urlRequest = OpenAICompatibleClient.makeRequest(request(), baseURL: base, apiKey: "sk-x")
    #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer sk-x")
  }

  @Test("makeRequest puts the system message first")
  func makeRequestShape() throws {
    let urlRequest = OpenAICompatibleClient.makeRequest(request(), baseURL: base, apiKey: "")
    #expect(urlRequest.httpMethod == "POST")
    #expect(urlRequest.url?.absoluteString == "http://127.0.0.1:11434/v1/chat/completions")
    #expect(urlRequest.value(forHTTPHeaderField: "content-type") == "application/json")
    let body = try #require(urlRequest.httpBody)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["model"] as? String == "llama3")
    #expect(json["max_tokens"] as? Int == 100)
    #expect(json["stream"] as? Bool == true)
    let messages = try #require(json["messages"] as? [[String: String]])
    #expect(
      messages == [
        ["role": "system", "content": "Be brief."], ["role": "user", "content": "hi"],
      ])
  }

  @Test("api.openai.com requests omit the token cap")
  func openAINoTokenCap() throws {
    let openAIBase = URL(string: "https://api.openai.com/v1")!
    let urlRequest = OpenAICompatibleClient.makeRequest(
      request(), baseURL: openAIBase, apiKey: "sk-x")
    let body = try #require(urlRequest.httpBody)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["max_tokens"] == nil)
    #expect(json["max_completion_tokens"] == nil)
    #expect(json["stream"] as? Bool == true)
  }

  @Test("non-OpenAI hosts keep max_tokens")
  func otherHostKeepsMaxTokens() throws {
    for host in ["https://openrouter.ai/api/v1", "https://api.openai.com.evil.com/v1"] {
      let urlRequest = OpenAICompatibleClient.makeRequest(
        request(), baseURL: URL(string: host)!, apiKey: "")
      let body = try #require(urlRequest.httpBody)
      let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
      #expect(json["max_tokens"] as? Int == 100)
      #expect(json["max_completion_tokens"] == nil)
    }
  }

  @Test("stream yields text and stops at [DONE]")
  func streamsText() async throws {
    AIStubURLProtocol.handler = { _ in
      let sse = """
        data: {"choices":[{"delta":{"role":"assistant","content":""}}]}

        data: {"choices":[{"delta":{"content":"SELECT"}}]}

        data: {"choices":[{"delta":{"content":" 1"}}]}

        data: [DONE]

        data: {"choices":[{"delta":{"content":" ignored"}}]}


        """
      return (200, [Data(sse.utf8)])
    }
    defer { AIStubURLProtocol.reset() }
    let text = try await collect(client().stream(request()))
    #expect(text == "SELECT 1")
    #expect(AIStubURLProtocol.lastRequest?.url?.path == "/v1/chat/completions")
  }

  @Test("401 maps to http error with provider message")
  func unauthorized() async {
    AIStubURLProtocol.handler = { _ in
      (401, [Data(#"{"error":{"message":"Incorrect API key"}}"#.utf8)])
    }
    defer { AIStubURLProtocol.reset() }
    let stream = client().stream(request())
    await #expect(throws: AIClientError.http(status: 401, message: "Incorrect API key")) {
      _ = try await collect(stream)
    }
  }

  @Test("listModels parses and sorts data[].id")
  func listModels() async throws {
    AIStubURLProtocol.handler = { _ in
      (
        200,
        [Data(#"{"object":"list","data":[{"id":"zeta"},{"id":"alpha","object":"model"}]}"#.utf8)]
      )
    }
    defer { AIStubURLProtocol.reset() }
    let models = try await client(apiKey: "sk-x").listModels()
    #expect(models == ["alpha", "zeta"])
    #expect(AIStubURLProtocol.lastRequest?.httpMethod == "GET")
    #expect(AIStubURLProtocol.lastRequest?.url?.path == "/v1/models")
    #expect(
      AIStubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-x")
  }

  @Test("listModels 500 throws http error")
  func listModelsServerError() async {
    AIStubURLProtocol.handler = { _ in (500, [Data("boom".utf8)]) }
    defer { AIStubURLProtocol.reset() }
    let client = client()
    await #expect(throws: AIClientError.http(status: 500, message: "boom")) {
      _ = try await client.listModels()
    }
  }

  @Test("detectOllama returns nil on 500")
  func detectOllamaFailure() async {
    AIStubURLProtocol.handler = { _ in (500, [Data("boom".utf8)]) }
    defer { AIStubURLProtocol.reset() }
    let models = await OpenAICompatibleClient.detectOllama(session: AIStubURLProtocol.makeSession())
    #expect(models == nil)
  }

  @Test("detectOllama returns nil on an empty list")
  func detectOllamaEmpty() async {
    AIStubURLProtocol.handler = { _ in (200, [Data(#"{"data":[]}"#.utf8)]) }
    defer { AIStubURLProtocol.reset() }
    let models = await OpenAICompatibleClient.detectOllama(session: AIStubURLProtocol.makeSession())
    #expect(models == nil)
  }

  @Test("detectOllama returns the model list on 200")
  func detectOllamaSuccess() async {
    AIStubURLProtocol.handler = { _ in (200, [Data(#"{"data":[{"id":"llama3"}]}"#.utf8)]) }
    defer { AIStubURLProtocol.reset() }
    let models = await OpenAICompatibleClient.detectOllama(session: AIStubURLProtocol.makeSession())
    #expect(models == ["llama3"])
    #expect(
      AIStubURLProtocol.lastRequest?.url?.absoluteString == "http://127.0.0.1:11434/v1/models")
    #expect(AIStubURLProtocol.lastRequest?.timeoutInterval == 2)
  }

  @Test("factory builds an OpenAI-compatible client without a key for local kinds")
  func factory() throws {
    let made = try AIClientFactory.make(
      kind: .ollama, config: AIProviderConfig(baseURL: base.absoluteString, model: "m"),
      apiKey: nil, session: AIStubURLProtocol.makeSession())
    #expect(made is OpenAICompatibleClient)
  }
}

@Suite("AIRedirectGuard")
struct AIRedirectGuardTests {
  private func allows(_ from: String, _ to: String) -> Bool {
    AIRedirectGuard.allows(from: URL(string: from)!, to: URL(string: to)!)
  }

  @Test("same-host redirect is allowed")
  func sameHost() {
    #expect(allows("https://api.example.com/v1/models", "https://api.example.com/v2/models"))
  }

  @Test("different-host redirect is refused")
  func differentHost() {
    #expect(!allows("https://api.example.com/v1", "https://evil.example.net/v1"))
  }

  @Test("https to http downgrade is refused")
  func downgrade() {
    #expect(!allows("https://api.example.com/v1", "http://api.example.com/v1"))
  }
}
