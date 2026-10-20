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

  /// JSONSerialization key order changes per process, so the body is compared in a sorted-key
  /// form: every key, value, type and nesting must match the text-only body sent before tools.
  @Test("text-only request body is unchanged")
  func textOnlyBodyPinned() throws {
    for (host, expected) in [
      (
        "http://127.0.0.1:11434/v1",
        #"{"max_tokens":100,"messages":[{"content":"Be brief.","role":"system"},{"content":"hi","role":"user"}],"model":"llama3","stream":true}"#
      ),
      (
        "https://api.openai.com/v1",
        #"{"messages":[{"content":"Be brief.","role":"system"},{"content":"hi","role":"user"}],"model":"llama3","stream":true}"#
      ),
    ] {
      let urlRequest = OpenAICompatibleClient.makeRequest(
        request(), baseURL: URL(string: host)!, apiKey: "")
      let body = try #require(urlRequest.httpBody)
      let object = try JSONSerialization.jsonObject(with: body)
      let sorted = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
      #expect(String(decoding: sorted, as: UTF8.self) == expected)
    }
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

  private let weatherTool = AIToolSpec(
    name: "get_weather", description: "Get the current weather in a given location",
    parameters: .object([
      "type": .string("object"),
      "properties": .object(["location": .object(["type": .string("string")])]),
    ]))

  private func body(_ request: AIChatRequest) throws -> [String: Any] {
    let urlRequest = OpenAICompatibleClient.makeRequest(request, baseURL: base, apiKey: "")
    let body = try #require(urlRequest.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
  }

  @Test("tools nest name, description and parameters under a function")
  func toolsShape() throws {
    var request = request()
    request.tools = [weatherTool]
    let tools = try #require(try body(request)["tools"] as? [[String: Any]])
    #expect(tools.count == 1)
    #expect(tools[0]["type"] as? String == "function")
    let function = try #require(tools[0]["function"] as? [String: Any])
    #expect(function["name"] as? String == "get_weather")
    #expect(function["description"] as? String == "Get the current weather in a given location")
    let parameters = try #require(function["parameters"] as? [String: Any])
    #expect(parameters["type"] as? String == "object")
  }

  @Test("assistant tool_calls turn and role tool messages carry the call id")
  func toolTurnsShape() throws {
    var request = request()
    let call = AIToolCall(id: "call_weather", name: "get_weather", inputJSON: #"{"city":"Paris"}"#)
    request.messages += [
      AIChatMessage(role: .assistant, blocks: [.toolUse(call)]),
      AIChatMessage(
        role: .user,
        blocks: [
          .toolResult(AIToolResult(id: "call_weather", content: "18 C", isError: false)),
          .toolResult(AIToolResult(id: "call_other", content: "failed", isError: true)),
          .text("And tomorrow?"),
        ]),
    ]
    let messages = try #require(try body(request)["messages"] as? [[String: Any]])
    #expect(messages.count == 6)
    let assistant = messages[2]
    #expect(assistant["role"] as? String == "assistant")
    #expect(assistant["content"] == nil)
    let calls = try #require(assistant["tool_calls"] as? [[String: Any]])
    #expect(
      calls[0] as NSDictionary
        == [
          "id": "call_weather", "type": "function",
          "function": ["name": "get_weather", "arguments": #"{"city":"Paris"}"#],
        ] as NSDictionary)
    #expect(
      messages[3] as NSDictionary
        == ["role": "tool", "tool_call_id": "call_weather", "content": "18 C"] as NSDictionary)
    #expect(
      messages[4] as NSDictionary
        == ["role": "tool", "tool_call_id": "call_other", "content": "failed"] as NSDictionary)
    #expect(
      messages[5] as NSDictionary == ["role": "user", "content": "And tomorrow?"] as NSDictionary)
  }

  @Test("a streamed tool call is echoed with the canonical arguments the parser validated")
  func echoesCanonicalToolCall() throws {
    var parser = AISSEParser(wire: .chatCompletions, toolNames: ["get_weather"])
    var deltas: [AIStreamDelta] = []
    for line in [
      #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"get_weather","arguments":"{ \"b\" : 2, \"a\" : 1, \"a\" : 3 }"}}]}}]}"#,
      "", #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#, "",
    ] {
      deltas += try parser.consume(line: line)
    }
    guard case .toolCall(let call) = try #require(deltas.first) else {
      Issue.record("expected a tool call")
      return
    }
    #expect(call.inputJSON == #"{"a":1,"b":2}"#)
    var request = request()
    request.messages.append(AIChatMessage(role: .assistant, blocks: [.toolUse(call)]))
    let messages = try #require(try body(request)["messages"] as? [[String: Any]])
    let calls = try #require(messages.last?["tool_calls"] as? [[String: Any]])
    let function = try #require(calls.first?["function"] as? [String: Any])
    #expect(function["arguments"] as? String == #"{"a":1,"b":2}"#)
  }

  @Test("stream yields tool calls of an offered tool and the stop reason")
  func streamsToolCall() async throws {
    AIStubURLProtocol.handler = { _ in
      (200, [Data(AIToolCallFixtures.chatCompletionsParallelStream.utf8)])
    }
    defer { AIStubURLProtocol.reset() }
    var request = request()
    request.tools = [weatherTool]
    var events: [AIStreamEvent] = []
    for try await event in client().stream(request) { events.append(event) }
    #expect(
      events == [
        .toolCall(
          AIToolCall(
            id: "call_paris", name: "get_weather", inputJSON: #"{"location":"Paris, France"}"#)
        ),
        .toolCall(
          AIToolCall(
            id: "call_london", name: "get_weather", inputJSON: #"{"location":"London, UK"}"#)
        ),
        .stop(.toolUse),
      ])
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

  @Test("detectOllama returns nil on 500")
  func detectOllamaFailure() async {
    AIStubURLProtocol.handler = { _ in (500, [Data("boom".utf8)]) }
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
