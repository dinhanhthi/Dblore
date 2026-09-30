import Foundation
import Testing

@testable import Dblore

@Suite("AnthropicClient", .serialized, AIStubScope())
struct AnthropicClientTests {

  private let base = URL(string: "https://api.anthropic.com/v1")!

  private func client() -> AnthropicClient {
    AnthropicClient(baseURL: base, apiKey: "sk-test", session: AIStubURLProtocol.makeSession())
  }

  private func request() -> AIChatRequest {
    AIChatRequest(
      model: "claude-sonnet-4-5", system: "Be brief.",
      messages: [AIChatMessage(role: .user, text: "hi")], maxTokens: 100)
  }

  private func collect(_ stream: AsyncThrowingStream<AIStreamEvent, Error>) async throws -> String {
    var text = ""
    for try await case .text(let piece) in stream { text += piece }
    return text
  }

  @Test("makeRequest sets url, headers and JSON body")
  func makeRequestShape() throws {
    let urlRequest = AnthropicClient.makeRequest(request(), baseURL: base, apiKey: "sk-test")
    #expect(urlRequest.httpMethod == "POST")
    #expect(urlRequest.url?.absoluteString == "https://api.anthropic.com/v1/messages")
    #expect(urlRequest.value(forHTTPHeaderField: "x-api-key") == "sk-test")
    #expect(urlRequest.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    #expect(urlRequest.value(forHTTPHeaderField: "content-type") == "application/json")
    let body = try #require(urlRequest.httpBody)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["model"] as? String == "claude-sonnet-4-5")
    #expect(json["system"] as? String == "Be brief.")
    #expect(json["max_tokens"] as? Int == 100)
    #expect(json["stream"] as? Bool == true)
    let messages = try #require(json["messages"] as? [[String: String]])
    #expect(messages == [["role": "user", "content": "hi"]])
  }

  @Test("stream concatenates text deltas")
  func streamsText() async throws {
    AIStubURLProtocol.handler = { _ in
      let sse = """
        event: message_start
        data: {"type":"message_start","message":{"id":"m1"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"SELECT"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" 1"}}

        event: message_stop
        data: {"type":"message_stop"}


        """
      return (200, [Data(sse.utf8)])
    }
    defer { AIStubURLProtocol.reset() }
    let text = try await collect(client().stream(request()))
    #expect(text == "SELECT 1")
    #expect(AIStubURLProtocol.lastRequest?.url?.path == "/v1/messages")
    #expect(AIStubURLProtocol.lastBody != nil)
  }

  @Test("401 maps to http error with provider message")
  func unauthorized() async {
    AIStubURLProtocol.handler = { _ in
      (401, [Data(#"{"error":{"message":"invalid x-api-key"}}"#.utf8)])
    }
    defer { AIStubURLProtocol.reset() }
    let stream = client().stream(request())
    await #expect(throws: AIClientError.http(status: 401, message: "invalid x-api-key")) {
      _ = try await collect(stream)
    }
  }

  @Test("listModels parses data[].id")
  func listModels() async throws {
    AIStubURLProtocol.handler = { _ in
      (
        200,
        [
          Data(
            #"{"data":[{"id":"claude-a","type":"model"},{"id":"claude-b"}],"has_more":false}"#.utf8)
        ]
      )
    }
    defer { AIStubURLProtocol.reset() }
    let models = try await client().listModels()
    #expect(models == ["claude-a", "claude-b"])
    #expect(AIStubURLProtocol.lastRequest?.httpMethod == "GET")
    #expect(AIStubURLProtocol.lastRequest?.value(forHTTPHeaderField: "x-api-key") == "sk-test")
  }

  @Test("listModels 404 returns fallback models")
  func listModelsFallback() async throws {
    AIStubURLProtocol.handler = { _ in (404, [Data("{}".utf8)]) }
    defer { AIStubURLProtocol.reset() }
    let models = try await client().listModels()
    #expect(models == AIProviderKind.anthropic.fallbackModels)
  }

  @Test("listModelsResult flags the fallback on 404 only")
  func listModelsResultFallbackFlag() async throws {
    defer { AIStubURLProtocol.reset() }
    AIStubURLProtocol.handler = { _ in (404, [Data("{}".utf8)]) }
    let fallback = try await client().listModelsResult()
    #expect(fallback.isFallback)
    #expect(fallback.models == AIProviderKind.anthropic.fallbackModels)

    AIStubURLProtocol.handler = { _ in (200, [Data(#"{"data":[{"id":"claude-a"}]}"#.utf8)]) }
    let live = try await client().listModelsResult()
    #expect(!live.isFallback)
    #expect(live.models == ["claude-a"])
  }

  @Test("listModels 401 throws http error")
  func listModelsUnauthorized() async {
    AIStubURLProtocol.handler = { _ in
      (401, [Data(#"{"error":{"message":"invalid x-api-key"}}"#.utf8)])
    }
    defer { AIStubURLProtocol.reset() }
    let client = client()
    await #expect(throws: AIClientError.http(status: 401, message: "invalid x-api-key")) {
      _ = try await client.listModels()
    }
  }

  @Test("factory builds an anthropic client")
  func factory() throws {
    let made = try AIClientFactory.make(
      kind: .anthropic, config: AIProviderConfig(baseURL: base.absoluteString, model: "m"),
      apiKey: "k", session: AIStubURLProtocol.makeSession())
    #expect(made is AnthropicClient)
  }
}
