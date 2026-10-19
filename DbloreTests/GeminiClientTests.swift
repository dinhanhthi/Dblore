// GeminiClientTests.swift
// Unit tests for the Gemini client: request shape, tool turns, streamed calls and model list

import Foundation
import Testing

@testable import Dblore

@Suite("GeminiClient", .serialized, AIStubScope())
struct GeminiClientTests {
  private typealias F = AIToolCallFixtures

  private let base = URL(string: "https://generativelanguage.googleapis.com/v1beta")!
  private let key = "gm-secret-key"

  private func client() -> GeminiClient {
    GeminiClient(baseURL: base, apiKey: key, session: AIStubURLProtocol.makeSession())
  }

  private func request(model: String = "gemini-2.5-flash") -> AIChatRequest {
    AIChatRequest(
      model: model, system: "Be brief.", messages: [AIChatMessage(role: .user, text: "hi")],
      maxTokens: 100)
  }

  private let weatherTool = AIToolSpec(
    name: "get_weather", description: "Get the current weather",
    parameters: .object([
      "type": .string("object"),
      "properties": .object(["location": .object(["type": .string("string")])]),
      "required": .array([.string("location")]),
    ]))

  private func body(_ request: AIChatRequest) throws -> [String: Any] {
    let urlRequest = try GeminiClient.makeRequest(request, baseURL: base, apiKey: key)
    let body = try #require(urlRequest.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
  }

  private func contents(_ request: AIChatRequest) throws -> [[String: Any]] {
    try #require(try body(request)["contents"] as? [[String: Any]])
  }

  private func parts(_ content: [String: Any]) throws -> [[String: Any]] {
    try #require(content["parts"] as? [[String: Any]])
  }

  /// Parses an SSE stream with the Gemini parser, one line at a time
  private func deltas(
    _ sse: String, tools: Set<String> = ["get_weather"]
  ) throws
    -> [AIStreamDelta]
  {
    var parser = AISSEParser(wire: .geminiGenerateContent, toolNames: tools)
    var out: [AIStreamDelta] = []
    for line in sse.split(separator: "\n", omittingEmptySubsequences: false) {
      out += try parser.consume(line: String(line))
    }
    return out + (try parser.consume(line: ""))
  }

  private func chunk(_ candidate: String) -> String {
    "data: {\"candidates\": [\(candidate)]}\n\n"
  }

  private func callChunk(_ functionCall: String, extra: String = "") -> String {
    chunk(
      #"{"content": {"parts": [{"functionCall": "# + functionCall + extra
        + #"}], "role": "model"}, "index": 0}"#)
  }

  private func toolCalls(_ deltas: [AIStreamDelta]) -> [AIToolCall] {
    deltas.compactMap { delta in
      if case .toolCall(let call) = delta { return call }
      return nil
    }
  }

  // MARK: - Request

  @Test("makeRequest posts to models/<id>:streamGenerateContent?alt=sse with the key header")
  func makeRequestShape() throws {
    let urlRequest = try GeminiClient.makeRequest(request(), baseURL: base, apiKey: key)
    #expect(urlRequest.httpMethod == "POST")
    #expect(
      urlRequest.url?.absoluteString
        == "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse"
    )
    #expect(urlRequest.value(forHTTPHeaderField: "x-goog-api-key") == key)
    #expect(urlRequest.value(forHTTPHeaderField: "content-type") == "application/json")
    #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == nil)
  }

  @Test("the API key never appears in the URL")
  func keyNeverInURL() throws {
    let url = try #require(
      try GeminiClient.makeRequest(request(), baseURL: base, apiKey: key).url)
    #expect(!url.absoluteString.contains(key))
    #expect(url.query == "alt=sse")
    #expect(!url.absoluteString.contains("key="))
  }

  /// JSONSerialization key order changes per process, so the body is compared sorted
  @Test("text-only request body is pinned")
  func textOnlyBodyPinned() throws {
    let urlRequest = try GeminiClient.makeRequest(request(), baseURL: base, apiKey: key)
    let object = try JSONSerialization.jsonObject(with: try #require(urlRequest.httpBody))
    let sorted = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    #expect(
      String(decoding: sorted, as: UTF8.self)
        == #"{"contents":[{"parts":[{"text":"hi"}],"role":"user"}],"systemInstruction":{"parts":[{"text":"Be brief."}]}}"#
    )
  }

  @Test("an empty system prompt sends no systemInstruction; assistant maps to model")
  func rolesAndNoSystem() throws {
    var request = request()
    request.system = ""
    request.messages += [
      AIChatMessage(role: .assistant, text: "SELECT 1"), AIChatMessage(role: .user, text: ""),
    ]
    let body = try body(request)
    #expect(body["systemInstruction"] == nil)
    let contents = try #require(body["contents"] as? [[String: Any]])
    #expect(contents.count == 2)
    #expect(contents[1]["role"] as? String == "model")
    #expect(try parts(contents[1]) as NSArray == [["text": "SELECT 1"]] as NSArray)
  }

  @Test("a models/ prefix on the model id is accepted")
  func modelsPrefixAccepted() throws {
    let url = try GeminiClient.makeRequest(
      request(model: "models/gemini-2.5-pro"), baseURL: base, apiKey: key
    ).url
    #expect(url?.path == "/v1beta/models/gemini-2.5-pro:streamGenerateContent")
  }

  @Test(
    "a model id that could change the URL is refused",
    arguments: [
      "a/b", "../x", "..", ".hidden", "a?key=1", "a#f", "models/", "gemini 2", "gemini\n",
      "a%2Fb", "tunedModels/x",
    ])
  func invalidModelRefused(model: String) {
    #expect(
      throws: AIClientError.invalidEndpoint(AIEndpointError.invalidModel.localizedDescription)
    ) {
      try GeminiClient.makeRequest(request(model: model), baseURL: base, apiKey: key)
    }
  }

  @Test("an empty model is reported as missing")
  func emptyModel() {
    #expect(throws: AIClientError.missingModel) {
      try GeminiClient.makeRequest(request(model: ""), baseURL: base, apiKey: key)
    }
  }

  @Test("tools go in one functionDeclarations entry with the JSON Schema as is")
  func toolsShape() throws {
    var request = request()
    request.tools = [weatherTool]
    let tools = try #require(try body(request)["tools"] as? [[String: Any]])
    #expect(tools.count == 1)
    let declarations = try #require(tools[0]["functionDeclarations"] as? [[String: Any]])
    #expect(declarations.count == 1)
    #expect(declarations[0]["name"] as? String == "get_weather")
    #expect(declarations[0]["description"] as? String == "Get the current weather")
    let schema = try #require(declarations[0]["parametersJsonSchema"] as? [String: Any])
    #expect(schema["type"] as? String == "object")
    #expect(schema["required"] as? [String] == ["location"])
    #expect(declarations[0]["parameters"] == nil)
  }

  @Test("a streamed call is echoed in its original part, signature beside the functionCall")
  func echoesCallAsFixture() throws {
    let call = try #require(toolCalls(try deltas(F.geminiFunctionCallStream)).first)
    var request = request()
    request.messages = [
      AIChatMessage(role: .user, text: "What is the weather like in Boston, MA?"),
      AIChatMessage(role: .assistant, blocks: [.toolUse(call)]),
      AIChatMessage(
        role: .user,
        blocks: [.toolResult(AIToolResult(id: call.id, content: "15 C", isError: false))]),
    ]
    let sent = try contents(request)
    let fixture = try #require(
      try JSONSerialization.jsonObject(with: Data(F.geminiFollowUpRequest.utf8))
        as? [String: Any])
    let expected = try #require(fixture["contents"] as? [[String: Any]])
    #expect(sent[1] as NSDictionary == expected[1] as NSDictionary)
    #expect(sent[2]["role"] as? String == "user")
    let response = try #require(try parts(sent[2]).first?["functionResponse"] as? [String: Any])
    #expect(
      response as NSDictionary
        == ["name": "get_weather", "response": ["result": "15 C"]] as NSDictionary)
  }

  @Test("a provider id is sent back on the call and its response; a local id never is")
  func providerAndLocalIDs() throws {
    let remote = AIToolCall(
      id: "fc_1", name: "get_weather", inputJSON: #"{"location":"Paris"}"#, signature: "sig")
    let local = AIToolCall(
      id: AISSEParser.localToolIDPrefix + "x", name: "get_weather",
      inputJSON: #"{"location":"London"}"#)
    var request = request()
    request.messages += [
      AIChatMessage(role: .assistant, blocks: [.toolUse(remote), .toolUse(local)]),
      AIChatMessage(
        role: .user,
        blocks: [
          .toolResult(AIToolResult(id: remote.id, content: "15", isError: false)),
          .toolResult(AIToolResult(id: local.id, content: "boom", isError: true)),
        ]),
    ]
    let sent = try contents(request)
    let calls = try parts(sent[1])
    #expect(
      calls[0] as NSDictionary
        == [
          "functionCall": ["id": "fc_1", "name": "get_weather", "args": ["location": "Paris"]],
          "thoughtSignature": "sig",
        ] as NSDictionary)
    #expect(
      calls[1] as NSDictionary
        == ["functionCall": ["name": "get_weather", "args": ["location": "London"]]]
        as NSDictionary)
    let responses = try parts(sent[2]).compactMap { $0["functionResponse"] as? [String: Any] }
    #expect(
      responses[0] as NSDictionary
        == ["id": "fc_1", "name": "get_weather", "response": ["result": "15"]] as NSDictionary)
    #expect(
      responses[1] as NSDictionary
        == ["name": "get_weather", "response": ["error": "boom"]] as NSDictionary)
  }

  @Test("function responses come before text in the user turn; text order kept in model turn")
  func partOrder() throws {
    let call = AIToolCall(id: "fc_1", name: "get_weather", inputJSON: "{}")
    var request = request()
    request.messages += [
      AIChatMessage(role: .assistant, blocks: [.text("Checking."), .toolUse(call)]),
      AIChatMessage(
        role: .user,
        blocks: [
          .text("Thanks"), .toolResult(AIToolResult(id: "fc_1", content: "x", isError: false)),
        ]
      ),
    ]
    let sent = try contents(request)
    let model = try parts(sent[1])
    #expect(model[0] as NSDictionary == ["text": "Checking."] as NSDictionary)
    #expect(model[1]["functionCall"] != nil)
    let user = try parts(sent[2])
    #expect(user[0]["functionResponse"] != nil)
    #expect(user[1] as NSDictionary == ["text": "Thanks"] as NSDictionary)
  }

  @Test("a result without a matching call, or for a call that does not parse, is dropped")
  func dropsUnmatchedResults() throws {
    let bad = AIToolCall(id: "fc_bad", name: "get_weather", inputJSON: "not json")
    var request = request()
    request.messages += [
      AIChatMessage(role: .assistant, blocks: [.text("Checking."), .toolUse(bad)]),
      AIChatMessage(
        role: .user,
        blocks: [
          .toolResult(AIToolResult(id: "fc_bad", content: "x", isError: false)),
          .toolResult(AIToolResult(id: "fc_unknown", content: "y", isError: false)),
        ]),
    ]
    let sent = try contents(request)
    #expect(sent.count == 2)
    #expect(try parts(sent[1]) as NSArray == [["text": "Checking."]] as NSArray)
  }

  // MARK: - Streamed calls

  @Test("a whole functionCall yields one validated call with its signature, then toolUse")
  func parsesFunctionCall() throws {
    let out = try deltas(F.geminiFunctionCallStream)
    #expect(out.count == 2)
    let call = try #require(toolCalls(out).first)
    #expect(call.name == "get_weather")
    #expect(call.inputJSON == #"{"location":"Boston, MA"}"#)
    #expect(call.signature == "ZGJsb3JlLXNwaWtlLW9wYXF1ZS10aG91Z2h0LXNpZ25hdHVyZQ==")
    #expect(call.id.hasPrefix(AISSEParser.localToolIDPrefix))
    #expect(out.last == .stop(.toolUse))
  }

  @Test("parallel calls: only the first carries the signature, each gets its own id")
  func parsesParallelCalls() throws {
    let out = try deltas(F.geminiParallelCallsStream, tools: ["get_current_temperature"])
    let calls = toolCalls(out)
    #expect(calls.map(\.inputJSON) == [#"{"location":"Paris"}"#, #"{"location":"London"}"#])
    #expect(calls.map(\.signature) == ["<SIGNATURE_A>", nil])
    #expect(calls[0].id != calls[1].id)
    #expect(out.last == .stop(.toolUse))
  }

  @Test("text streams; a signature on an empty text part is dropped; STOP is endTurn")
  func parsesTextWithTrailingSignature() throws {
    #expect(
      try deltas(F.geminiTextSignatureStream) == [.text("It is sunny in Boston."), .stop(.endTurn)])
  }

  @Test("a provider call id is kept; arguments are canonical with sorted keys")
  func keepsProviderID() throws {
    let call = try #require(
      toolCalls(
        try deltas(callChunk(#"{"id": "fc_7", "name": "get_weather", "args": {"b": 2, "a": 1}}"#))
      ).first)
    #expect(call == AIToolCall(id: "fc_7", name: "get_weather", inputJSON: #"{"a":1,"b":2}"#))
  }

  @Test("missing args mean an empty object")
  func missingArgs() throws {
    let call = try #require(toolCalls(try deltas(callChunk(#"{"name": "get_weather"}"#))).first)
    #expect(call.inputJSON == "{}")
  }

  @Test(
    "a refused function call throws invalidToolCall",
    arguments: [
      #"{"name": "drop_table", "args": {}}"#,
      #"{"args": {}}"#,
      #"{"name": "get_weather", "args": [1]}"#,
      #"{"name": "get_weather", "args": "x"}"#,
      #"{"name": "get_weather", "args": {"n": -1e999}}"#,
      #"{"id": ""# + String(repeating: "i", count: 257) + #"", "name": "get_weather"}"#,
      #"{"name": "get_weather", "args": {"s": ""# + String(repeating: "x", count: 64 * 1024)
        + #""}}"#,
    ])
  func refusedCalls(functionCall: String) {
    #expect(throws: AIStreamError.self) { try deltas(callChunk(functionCall)) }
  }

  @Test("an oversized thought signature is refused")
  func oversizedSignature() {
    let signature = String(repeating: "s", count: AISSEParser.maxSignatureBytes + 1)
    let sse = callChunk(
      #"{"name": "get_weather"}"#, extra: #", "thoughtSignature": ""# + signature + "\"")
    #expect(throws: AIStreamError.self) { try deltas(sse) }
  }

  @Test("refused errors never echo model text")
  func genericMessages() {
    #expect(throws: AIStreamError.invalidToolCall("The model called a tool that was not offered."))
    {
      try deltas(callChunk(#"{"name": "SECRET_TOOL"}"#))
    }
  }

  @Test("more than 32 calls in one turn are refused")
  func tooManyCalls() {
    let one = #"{"functionCall": {"name": "get_weather"}}"#
    let parts = Array(repeating: one, count: AISSEParser.maxPendingToolCalls + 1)
      .joined(separator: ",")
    #expect(throws: AIStreamError.invalidToolCall("The model sent too many tool calls.")) {
      try deltas(chunk(#"{"content": {"parts": ["# + parts + #"]}}"#))
    }
  }

  @Test(
    "tool finish reasons are errors",
    arguments: ["MALFORMED_FUNCTION_CALL", "UNEXPECTED_TOOL_CALL", "TOO_MANY_TOOL_CALLS"])
  func toolFinishReasons(reason: String) {
    #expect(throws: AIStreamError.invalidToolCall("The provider refused the model's tool call.")) {
      try deltas(chunk(#"{"finishReason": ""# + reason + #""}"#))
    }
  }

  @Test("MAX_TOKENS maps to maxTokens, other reasons are kept, thought parts are hidden")
  func otherFinishReasons() throws {
    #expect(try deltas(chunk(#"{"finishReason": "MAX_TOKENS"}"#)) == [.stop(.maxTokens)])
    #expect(try deltas(chunk(#"{"finishReason": "SAFETY"}"#)) == [.stop(.other("SAFETY"))])
    let thought = #"{"content": {"parts": [{"text": "hmm", "thought": true}, {"text": "ok"}]}}"#
    #expect(try deltas(chunk(thought)) == [.text("ok")])
  }

  @Test("a blocked prompt stops with its reason; an error event throws")
  func blockedAndError() throws {
    #expect(
      try deltas(#"data: {"promptFeedback": {"blockReason": "SAFETY"}}"# + "\n\n")
        == [.stop(.other("SAFETY"))])
    #expect(throws: AIStreamError.provider("quota")) {
      try deltas(#"data: {"error": {"code": 429, "message": "quota"}}"# + "\n\n")
    }
  }

  // MARK: - Network (stubbed)

  @Test("stream yields text, calls and stop over the stubbed SSE response")
  func streamsOverHTTP() async throws {
    AIStubURLProtocol.handler = { _ in (200, [Data(F.geminiFunctionCallStream.utf8)]) }
    defer { AIStubURLProtocol.reset() }
    var request = request()
    request.tools = [weatherTool]
    var events: [AIStreamEvent] = []
    for try await event in client().stream(request) { events.append(event) }
    #expect(events.count == 2)
    #expect(events.last == .stop(.toolUse))
    let sent = try #require(AIStubURLProtocol.lastRequest)
    #expect(sent.value(forHTTPHeaderField: "x-goog-api-key") == key)
    #expect(sent.url?.absoluteString.contains(key) == false)
  }

  @Test("an invalid model fails the stream without a request")
  func invalidModelStream() async {
    defer { AIStubURLProtocol.reset() }
    let stream = client().stream(request(model: "a/b"))
    await #expect(throws: AIClientError.self) {
      for try await _ in stream {}
    }
    #expect(AIStubURLProtocol.lastRequest == nil)
  }

  @Test("HTTP errors carry the provider message")
  func httpError() async {
    AIStubURLProtocol.handler = { _ in
      (
        400,
        [
          Data(
            #"{"error":{"code":400,"message":"API key not valid.","status":"INVALID_ARGUMENT"}}"#
              .utf8)
        ]
      )
    }
    defer { AIStubURLProtocol.reset() }
    let stream = client().stream(request())
    await #expect(throws: AIClientError.http(status: 400, message: "API key not valid.")) {
      for try await _ in stream {}
    }
  }

  @Test("listModels keeps generateContent models, strips models/, key in the header only")
  func listModels() async throws {
    AIStubURLProtocol.handler = { _ in (200, [Data(F.geminiModelsListResponse.utf8)]) }
    defer { AIStubURLProtocol.reset() }
    #expect(try await client().listModels() == ["gemini-2.5-flash-lite"])
    let sent = try #require(AIStubURLProtocol.lastRequest)
    #expect(sent.httpMethod == "GET")
    #expect(sent.url?.path == "/v1beta/models")
    #expect(sent.url?.query == "pageSize=1000")
    #expect(sent.url?.absoluteString.contains(key) == false)
    #expect(sent.value(forHTTPHeaderField: "x-goog-api-key") == key)
  }

  @Test("listModels keeps models without the methods field and drops unusable names")
  func listModelsFiltering() async throws {
    AIStubURLProtocol.handler = { _ in
      (
        200,
        [
          Data(
            #"{"models":[{"name":"models/gemini-a"},{"name":"tunedModels/t1"},{"name":"models/b/c"},{"displayName":"x"}]}"#
              .utf8)
        ]
      )
    }
    defer { AIStubURLProtocol.reset() }
    #expect(try await client().listModels() == ["gemini-a"])
  }

  @Test("listModels maps HTTP errors")
  func listModelsError() async {
    AIStubURLProtocol.handler = { _ in (403, [Data(#"{"error":{"message":"denied"}}"#.utf8)]) }
    defer { AIStubURLProtocol.reset() }
    await #expect(throws: AIClientError.http(status: 403, message: "denied")) {
      _ = try await client().listModels()
    }
  }

  // MARK: - Factory

  @Test("the factory makes a native-tools Gemini client and needs a key")
  func factory() throws {
    let config = AIProviderConfig(baseURL: AIProviderKind.gemini.defaultBaseURL, model: "m")
    let made = try AIClientFactory.make(kind: .gemini, config: config, apiKey: " k ")
    let gemini = try #require(made as? GeminiClient)
    #expect(gemini.supportsNativeTools)
    #expect(gemini.apiKey == "k")
    #expect(gemini.baseURL.absoluteString == "https://generativelanguage.googleapis.com/v1beta")
    #expect(throws: AIClientError.missingAPIKey) {
      try AIClientFactory.make(kind: .gemini, config: config, apiKey: nil)
    }
  }
}
