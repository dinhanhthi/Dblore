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

  /// JSONSerialization key order changes per process, so the body is compared in a sorted-key
  /// form: every key, value, type and nesting must match the text-only body sent before tools.
  @Test("text-only request body is unchanged")
  func textOnlyBodyPinned() throws {
    let urlRequest = AnthropicClient.makeRequest(request(), baseURL: base, apiKey: "sk-test")
    let body = try #require(urlRequest.httpBody)
    let object = try JSONSerialization.jsonObject(with: body)
    let sorted = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    #expect(
      String(decoding: sorted, as: UTF8.self)
        == #"{"max_tokens":100,"messages":[{"content":"hi","role":"user"}],"model":"claude-sonnet-4-5","stream":true,"system":"Be brief."}"#
    )
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

  private let weatherTool = AIToolSpec(
    name: "get_weather", description: "Get the current weather in a given location",
    parameters: .object([
      "type": .string("object"),
      "properties": .object(["location": .object(["type": .string("string")])]),
      "required": .array([.string("location")]),
    ]))

  private func body(_ request: AIChatRequest) throws -> [String: Any] {
    let urlRequest = AnthropicClient.makeRequest(request, baseURL: base, apiKey: "sk-test")
    let body = try #require(urlRequest.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
  }

  @Test("tools are sent with name, description and input_schema")
  func toolsShape() throws {
    var request = request()
    request.tools = [weatherTool]
    let tools = try #require(try body(request)["tools"] as? [[String: Any]])
    #expect(tools.count == 1)
    #expect(tools[0]["name"] as? String == "get_weather")
    #expect(tools[0]["description"] as? String == "Get the current weather in a given location")
    let schema = try #require(tools[0]["input_schema"] as? [String: Any])
    #expect(schema["type"] as? String == "object")
    #expect(schema["required"] as? [String] == ["location"])
    #expect(tools[0]["parameters"] == nil)
  }

  @Test("assistant tool_use turn and tool_result turn use content blocks")
  func toolTurnsShape() throws {
    var request = request()
    let call = AIToolCall(
      id: "toolu_1", name: "get_weather", inputJSON: #"{"location":"San Francisco, CA"}"#)
    request.messages += [
      AIChatMessage(role: .assistant, blocks: [.text("Checking."), .toolUse(call)]),
      AIChatMessage(
        role: .user,
        blocks: [
          .text("Thanks"),
          .toolResult(AIToolResult(id: "toolu_1", content: "15 degrees", isError: false)),
          .toolResult(AIToolResult(id: "toolu_2", content: "HTTP 500", isError: true)),
        ]),
    ]
    let messages = try #require(try body(request)["messages"] as? [[String: Any]])
    #expect(messages.count == 3)
    #expect(messages[0]["content"] as? String == "hi")

    #expect(messages[1]["role"] as? String == "assistant")
    let assistant = try #require(messages[1]["content"] as? [[String: Any]])
    #expect(assistant[0] as NSDictionary == ["type": "text", "text": "Checking."] as NSDictionary)
    #expect(assistant[1]["type"] as? String == "tool_use")
    #expect(assistant[1]["id"] as? String == "toolu_1")
    #expect(assistant[1]["name"] as? String == "get_weather")
    #expect(
      assistant[1]["input"] as? NSDictionary == ["location": "San Francisco, CA"] as NSDictionary)

    #expect(messages[2]["role"] as? String == "user")
    let results = try #require(messages[2]["content"] as? [[String: Any]])
    #expect(
      results[0] as NSDictionary
        == ["type": "tool_result", "tool_use_id": "toolu_1", "content": "15 degrees"]
        as NSDictionary)
    #expect(
      results[1] as NSDictionary
        == [
          "type": "tool_result", "tool_use_id": "toolu_2", "content": "HTTP 500", "is_error": true,
        ] as NSDictionary)
    #expect(results[2] as NSDictionary == ["type": "text", "text": "Thanks"] as NSDictionary)
  }

  @Test("a streamed tool call is echoed as the canonical object the parser validated")
  func echoesCanonicalToolCall() throws {
    var parser = AISSEParser(wire: .anthropicMessages, toolNames: ["get_weather"])
    var deltas: [AIStreamDelta] = []
    for line in [
      #"data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t1","name":"get_weather","input":{}}}"#,
      "",
      #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{ \"b\" : 2, \"a\" : 1, \"a\" : 3 }"}}"#,
      "", #"data: {"type":"content_block_stop","index":0}"#, "",
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
    let block = try #require((messages[1]["content"] as? [[String: Any]])?.first)
    let input = try #require(block["input"])
    let echoed = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
    #expect(String(decoding: echoed, as: UTF8.self) == call.inputJSON)
  }

  @Test("a stored tool call that does not parse is dropped, never sent as an empty input")
  func dropsUnparseableToolCall() throws {
    var request = request()
    let bad = AIToolCall(id: "toolu_bad", name: "get_weather", inputJSON: "not json")
    request.messages.append(
      AIChatMessage(role: .assistant, blocks: [.text("Checking."), .toolUse(bad)]))
    let messages = try #require(try body(request)["messages"] as? [[String: Any]])
    let content = try #require(messages[1]["content"] as? [[String: Any]])
    #expect(content.count == 1)
    #expect(content[0] as NSDictionary == ["type": "text", "text": "Checking."] as NSDictionary)
  }

  @Test("stream yields the tool call of an offered tool and the stop reason")
  func streamsToolCall() async throws {
    AIStubURLProtocol.handler = { _ in (200, [Data(AIToolCallFixtures.messagesToolUseStream.utf8)])
    }
    defer { AIStubURLProtocol.reset() }
    var request = request()
    request.tools = [weatherTool]
    var events: [AIStreamEvent] = []
    for try await event in client().stream(request) {
      if case .text = event { continue }
      events.append(event)
    }
    #expect(
      events == [
        .toolCall(
          AIToolCall(
            id: "toolu_01T1x1fJ34qAmk2tNTrN7Up6", name: "get_weather",
            inputJSON: #"{"location":"San Francisco, CA"}"#)),
        .stop(.toolUse),
      ])
  }

  @Test("stream refuses a tool call when the request offered no tools")
  func streamRefusesUnofferedTool() async {
    AIStubURLProtocol.handler = { _ in (200, [Data(AIToolCallFixtures.messagesToolUseStream.utf8)])
    }
    defer { AIStubURLProtocol.reset() }
    let stream = client().stream(request())
    await #expect(throws: AIStreamError.self) { _ = try await collect(stream) }
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

}
