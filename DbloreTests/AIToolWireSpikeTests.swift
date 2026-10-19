// AIToolWireSpikeTests.swift
// Spike 2.1: are the streamed tool-call fixtures in AIToolCallFixtures well formed, and which
// fields must the phase 8 tool-call parsers read on each wire? The tests read the fixtures with
// a tiny SSE splitter and JSONSerialization, not the production AISSEParser (it has no tool
// support yet).

import Foundation
import Testing

@Suite("AI tool wire spike")
struct AIToolWireSpikeTests {
  private typealias F = AIToolCallFixtures

  // MARK: - Helpers

  private struct SSEEvent {
    let name: String?
    let data: String
  }

  /// Splits an SSE stream into events: `event:` names the event, `data:` lines join with "\n",
  /// `:` lines are comments, a blank line ends the event.
  private func events(_ stream: String) -> [SSEEvent] {
    var out: [SSEEvent] = []
    var name: String?
    var data: [String] = []
    func flush() {
      if !data.isEmpty { out.append(SSEEvent(name: name, data: data.joined(separator: "\n"))) }
      name = nil
      data = []
    }
    for line in stream.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.isEmpty {
        flush()
      } else if line.hasPrefix("event:") {
        name = field(line, "event:")
      } else if line.hasPrefix("data:") {
        data.append(field(line, "data:"))
      }
    }
    flush()
    return out
  }

  private func field(_ line: Substring, _ prefix: String) -> String {
    let value = line.dropFirst(prefix.count)
    return String(value.hasPrefix(" ") ? value.dropFirst() : value)
  }

  private func json(_ text: String) throws -> Any {
    try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
  }

  private func object(_ text: String) throws -> [String: Any] {
    try #require(try json(text) as? [String: Any])
  }

  private func objects(_ stream: String) throws -> [[String: Any]] {
    try events(stream).filter { $0.data != "[DONE]" }.map { try object($0.data) }
  }

  private func dict(_ value: Any?) throws -> [String: Any] {
    try #require(value as? [String: Any])
  }

  private func list(_ value: Any?) throws -> [Any] {
    try #require(value as? [Any])
  }

  private func isEqual(_ lhs: Any, _ rhs: Any) -> Bool {
    (lhs as AnyObject).isEqual(rhs)
  }

  // MARK: - Messages API

  @Test("messages: every data payload is JSON and its type equals the event name")
  func messagesEventNamesMatchType() throws {
    let all = events(F.messagesToolUseStream)
    #expect(all.count == 27)
    for event in all {
      let payload = try object(event.data)
      #expect(event.name != nil)
      #expect(payload["type"] as? String == event.name)
    }
    #expect(all.first?.name == "message_start")
    #expect(all.last?.name == "message_stop")
  }

  @Test("messages: a ping may arrive between blocks and must be skipped")
  func messagesPingMayArriveBetweenBlocks() throws {
    let names = events(F.messagesToolUseStream).compactMap(\.name)
    #expect(names.contains("ping"))
    #expect(names.firstIndex(of: "ping")! < names.firstIndex(of: "content_block_delta")!)
  }

  @Test("messages: content_block_start of a tool_use block carries id, name and input {}")
  func messagesToolUseStartCarriesIdAndName() throws {
    let starts = try objects(F.messagesToolUseStream).filter {
      $0["type"] as? String == "content_block_start"
    }
    let toolStart = try #require(
      starts.first { (($0["content_block"] as? [String: Any])?["type"] as? String) == "tool_use" })
    let block = try dict(toolStart["content_block"])
    #expect(toolStart["index"] as? Int == 1)
    #expect(block["id"] as? String == "toolu_01T1x1fJ34qAmk2tNTrN7Up6")
    #expect(block["name"] as? String == "get_weather")
    #expect(try dict(block["input"]).isEmpty)
  }

  @Test("messages: text deltas join per block index")
  func messagesTextDeltasJoinByIndex() throws {
    let text = try deltas(in: F.messagesToolUseStream, index: 0, kind: "text_delta", key: "text")
    #expect(text.joined() == "Okay, let's check the weather for San Francisco, CA:")
  }

  @Test("messages: the first input_json_delta partial_json is the empty string")
  func messagesFirstInputJSONDeltaIsEmpty() throws {
    let pieces = try deltas(
      in: F.messagesToolUseStream, index: 1, kind: "input_json_delta", key: "partial_json")
    #expect(pieces.first == "")
  }

  @Test("messages: partial_json pieces concatenate to the input object only once complete")
  func messagesInputJSONDeltaConcatenatesToObject() throws {
    let pieces = try deltas(
      in: F.messagesToolUseStream, index: 1, kind: "input_json_delta", key: "partial_json")
    #expect(throws: (any Error).self) { try json(pieces.dropLast().joined()) }
    let input = try object(pieces.joined())
    #expect(input as NSDictionary == ["location": "San Francisco, CA"] as NSDictionary)
  }

  @Test("messages: stop_reason tool_use arrives in message_delta, null in message_start")
  func messagesStopReasonArrivesInMessageDelta() throws {
    let payloads = try objects(F.messagesToolUseStream)
    let start = try dict(payloads.first?["message"])
    #expect(start["stop_reason"] is NSNull)
    let delta = try #require(payloads.first { $0["type"] as? String == "message_delta" })
    #expect(try dict(delta["delta"])["stop_reason"] as? String == "tool_use")
  }

  @Test("messages: request tools carry name and input_schema, stream true")
  func messagesToolRequestShape() throws {
    let request = try object(F.messagesToolRequest)
    let tool = try dict(try list(request["tools"]).first)
    #expect(tool["name"] as? String == "get_weather")
    #expect(try dict(tool["input_schema"])["type"] as? String == "object")
    #expect(request["stream"] as? Bool == true)
  }

  @Test("messages: tool_result turns echo the tool_use id, is_error only on failure")
  func messagesToolResultEchoesToolUseId() throws {
    let echo = try object(F.messagesAssistantEchoTurn)
    #expect(echo["role"] as? String == "assistant")
    let toolUse = try #require(
      try list(echo["content"]).compactMap { $0 as? [String: Any] }.first {
        $0["type"] as? String == "tool_use"
      })
    #expect(toolUse["input"] is [String: Any])
    for (fixture, isError) in [
      (F.messagesToolResultTurn, false), (F.messagesToolResultErrorTurn, true),
    ] {
      let turn = try object(fixture)
      #expect(turn["role"] as? String == "user")
      let result = try dict(try list(turn["content"]).first)
      #expect(result["type"] as? String == "tool_result")
      #expect(result["tool_use_id"] as? String == toolUse["id"] as? String)
      #expect(result["content"] is String)
      #expect((result["is_error"] as? Bool ?? false) == isError)
    }
  }

  private func deltas(
    in stream: String, index: Int, kind: String, key: String
  ) throws
    -> [String]
  {
    try objects(stream).compactMap { payload -> String? in
      guard payload["type"] as? String == "content_block_delta",
        payload["index"] as? Int == index
      else { return nil }
      let delta = try dict(payload["delta"])
      guard delta["type"] as? String == kind else { return nil }
      return try #require(delta[key] as? String)
    }
  }

  // MARK: - Chat Completions

  private static let chatStreams = [
    F.chatCompletionsToolCallStream, F.chatCompletionsNullFragmentStream,
    F.chatCompletionsParallelStream,
  ]

  private struct AccumulatedCall: Equatable {
    var id: String?
    var type: String?
    var name: String?
    var arguments = ""
  }

  /// Joins `choices[0].delta.tool_calls` fragments by `index`. A null or absent id, type or
  /// name never overwrites the value of an earlier fragment.
  private func accumulateChatToolCalls(_ stream: String) throws -> [Int: AccumulatedCall] {
    var calls: [Int: AccumulatedCall] = [:]
    for chunk in try objects(stream) {
      let choice = try dict(try list(chunk["choices"]).first)
      let fragments = try dict(choice["delta"])["tool_calls"] as? [[String: Any]] ?? []
      for fragment in fragments {
        let index = try #require(fragment["index"] as? Int)
        var call = calls[index] ?? AccumulatedCall()
        let function = fragment["function"] as? [String: Any] ?? [:]
        call.id = fragment["id"] as? String ?? call.id
        call.type = fragment["type"] as? String ?? call.type
        call.name = function["name"] as? String ?? call.name
        call.arguments += function["arguments"] as? String ?? ""
        calls[index] = call
      }
    }
    return calls
  }

  @Test("chat: data payloads are JSON chunks until data: [DONE], no event names")
  func chatCompletionsChunksParseUntilDone() throws {
    for stream in Self.chatStreams {
      let all = events(stream)
      #expect(all.last?.data == "[DONE]")
      #expect(all.allSatisfy { $0.name == nil })
      for event in all.dropLast() {
        #expect(try object(event.data)["object"] as? String == "chat.completion.chunk")
      }
    }
  }

  @Test("chat: the first fragment carries index, id, type function, name and empty arguments")
  func chatCompletionsFirstFragmentCarriesIdTypeName() throws {
    let first = try #require(try objects(F.chatCompletionsToolCallStream).first)
    let delta = try dict(try dict(try list(first["choices"]).first)["delta"])
    #expect(delta["role"] as? String == "assistant")
    #expect(delta["content"] is NSNull)
    let fragment = try dict(try list(delta["tool_calls"]).first)
    let function = try dict(fragment["function"])
    #expect(fragment["index"] as? Int == 0)
    #expect(fragment["id"] as? String == "call_DdmO9pD3xa9XTPNJ32zg2hcA")
    #expect(fragment["type"] as? String == "function")
    #expect(function["name"] as? String == "get_weather")
    #expect(function["arguments"] as? String == "")
  }

  @Test("chat: fragments join by index into whole calls with JSON arguments")
  func chatCompletionsFragmentsJoinByIndex() throws {
    let single = try accumulateChatToolCalls(F.chatCompletionsToolCallStream)
    #expect(
      single == [
        0: AccumulatedCall(
          id: "call_DdmO9pD3xa9XTPNJ32zg2hcA", type: "function", name: "get_weather",
          arguments: #"{"location":"Paris, France"}"#)
      ])
    let parallel = try accumulateChatToolCalls(F.chatCompletionsParallelStream)
    #expect(parallel.keys.sorted() == [0, 1])
    #expect(parallel[0]?.id == "call_paris")
    #expect(parallel[1]?.id == "call_london")
    for call in parallel.values {
      #expect(try object(call.arguments)["location"] is String)
    }
  }

  @Test("chat: later fragments may omit or null id, type and name")
  func chatCompletionsLaterFragmentsMayNullId() throws {
    func laterFragments(_ stream: String) throws -> [[String: Any]] {
      try objects(stream).dropFirst().compactMap { chunk in
        let delta = try dict(try dict(try list(chunk["choices"]).first)["delta"])
        return (delta["tool_calls"] as? [[String: Any]])?.first
      }
    }
    let omitted = try laterFragments(F.chatCompletionsToolCallStream)
    let nulled = try laterFragments(F.chatCompletionsNullFragmentStream)
    #expect(!omitted.isEmpty && omitted.count == nulled.count)
    #expect(omitted.allSatisfy { $0["id"] == nil && $0["type"] == nil })
    #expect(nulled.allSatisfy { $0["id"] is NSNull && $0["type"] is NSNull })
    #expect(
      try accumulateChatToolCalls(F.chatCompletionsNullFragmentStream)
        == accumulateChatToolCalls(F.chatCompletionsToolCallStream))
  }

  @Test("chat: finish_reason tool_calls arrives on the last chunk, null before")
  func chatCompletionsFinalChunkFinishReasonToolCalls() throws {
    for stream in Self.chatStreams {
      let choices = try objects(stream).map { try dict(try list($0["choices"]).first) }
      #expect(choices.last?["finish_reason"] as? String == "tool_calls")
      #expect(try dict(choices.last?["delta"]).isEmpty)
      #expect(choices.dropLast().allSatisfy { $0["finish_reason"] is NSNull })
    }
  }

  @Test("chat: request tools nest name and parameters under function")
  func chatCompletionsToolsRequestNestsFunction() throws {
    let request = try object(F.chatCompletionsToolsRequest)
    let tool = try dict(try list(request["tools"]).first)
    #expect(tool["type"] as? String == "function")
    let function = try dict(tool["function"])
    #expect(function["name"] as? String == "get_current_weather")
    #expect(try dict(function["parameters"])["type"] as? String == "object")
  }

  @Test("chat: the tool message answers the assistant tool_calls id via tool_call_id")
  func chatCompletionsToolMessageCarriesToolCallId() throws {
    let messages = try list(json(F.chatCompletionsFollowUpMessages)).map { try dict($0) }
    let assistant = try #require(messages.first { $0["role"] as? String == "assistant" })
    let call = try dict(try list(assistant["tool_calls"]).first)
    let arguments = try #require(try dict(call["function"])["arguments"] as? String)
    #expect(try object(arguments)["city"] as? String == "Paris")
    let tool = try #require(messages.first { $0["role"] as? String == "tool" })
    #expect(tool["tool_call_id"] as? String == call["id"] as? String)
    #expect(tool["content"] is String)
  }

  // MARK: - Responses API

  @Test("responses: every event name equals the payload type, stream ends at response.completed")
  func responsesEventNamesMatchType() throws {
    let all = events(F.responsesFunctionCallStream)
    for event in all {
      #expect(event.name != nil)
      #expect(try object(event.data)["type"] as? String == event.name)
    }
    #expect(!all.contains { $0.data == "[DONE]" })
    #expect(all.last?.name == "response.completed")
  }

  @Test("responses: output_item.added carries a function_call item with id, call_id, name")
  func responsesOutputItemAddedCarriesCallIdAndName() throws {
    let added = try #require(try objects(F.responsesFunctionCallStream).first)
    #expect(added["type"] as? String == "response.output_item.added")
    let item = try dict(added["item"])
    #expect(item["type"] as? String == "function_call")
    #expect(item["id"] as? String == "fc_1234xyz")
    #expect(item["call_id"] as? String == "call_1234xyz")
    #expect(item["name"] as? String == "get_weather")
    #expect(item["arguments"] as? String == "")
  }

  @Test("responses: joined argument deltas equal arguments.done and output_item.done")
  func responsesArgumentsDeltaJoinsToDone() throws {
    let framed = try objects(F.responsesFunctionCallStream)
    let bare = try F.responsesGuideEventLines.split(separator: "\n").map { try object(String($0)) }
    for payloads in [framed, bare] {
      func ofType(_ type: String) -> [[String: Any]] {
        payloads.filter { $0["type"] as? String == type }
      }
      let joined = ofType("response.function_call_arguments.delta")
        .compactMap { $0["delta"] as? String }.joined()
      let done = try #require(ofType("response.function_call_arguments.done").first)
      let item = try dict(ofType("response.output_item.done").first?["item"])
      #expect(joined == done["arguments"] as? String)
      #expect(joined == item["arguments"] as? String)
      #expect(try object(joined) as NSDictionary == ["location": "Paris, France"] as NSDictionary)
    }
  }

  @Test("responses: argument deltas key on item_id (the item id), not call_id")
  func responsesDeltasKeyOnItemIdNotCallId() throws {
    let payloads = try objects(F.responsesFunctionCallStream)
    let item = try dict(payloads.first?["item"])
    let deltas = payloads.filter {
      $0["type"] as? String == "response.function_call_arguments.delta"
    }
    #expect(deltas.count == 7)
    #expect(deltas.allSatisfy { $0["item_id"] as? String == item["id"] as? String })
    #expect(item["id"] as? String != item["call_id"] as? String)
  }

  @Test("responses: events may carry response_id or sequence_number, parsers require neither")
  func responsesEventsNeedNeitherResponseIdNorSequenceNumber() throws {
    let bare = try F.responsesGuideEventLines.split(separator: "\n").map { try object(String($0)) }
    #expect(bare.count == 10)
    #expect(bare.allSatisfy { $0["response_id"] is String && $0["sequence_number"] == nil })
    let numbers = try objects(F.responsesFunctionCallStream).map {
      try #require($0["sequence_number"] as? Int)
    }
    #expect(numbers == numbers.sorted())
  }

  @Test("responses: response.completed output holds the finished function_call item")
  func responsesCompletedOutputHoldsFunctionCall() throws {
    let completed = try #require(try objects(F.responsesFunctionCallStream).last)
    let response = try dict(completed["response"])
    #expect(response["status"] as? String == "completed")
    let item = try dict(try list(response["output"]).first)
    #expect(item["type"] as? String == "function_call")
    #expect(item["call_id"] as? String == "call_1234xyz")
  }

  @Test("responses: function tools are flat, a namespace groups them under tools")
  func responsesFunctionToolIsFlat() throws {
    let tool = try object(F.responsesFunctionTool)
    #expect(tool["type"] as? String == "function")
    #expect(tool["name"] as? String == "get_weather")
    #expect(tool["function"] == nil)
    #expect(tool["parameters"] is [String: Any])
    let namespace = try object(F.responsesNamespaceTool)
    #expect(namespace["type"] as? String == "namespace")
    let inner = try dict(try list(namespace["tools"]).first)
    #expect(inner["type"] as? String == "function")
  }

  @Test("responses: function_call_output follows the echoed call and keys on call_id")
  func responsesFunctionCallOutputUsesCallId() throws {
    let input = try list(json(F.responsesFollowUpInput)).map { try dict($0) }
    let callIndex = try #require(input.firstIndex { $0["type"] as? String == "function_call" })
    let outputIndex = try #require(
      input.firstIndex { $0["type"] as? String == "function_call_output" })
    #expect(callIndex < outputIndex)
    #expect(input[outputIndex]["call_id"] as? String == input[callIndex]["call_id"] as? String)
    #expect(input[outputIndex]["output"] is String)
  }

  // MARK: - Gemini

  private func geminiParts(_ chunk: [String: Any]) throws -> [[String: Any]] {
    let candidate = try dict(try list(chunk["candidates"]).first)
    return try list(try dict(candidate["content"])["parts"]).map { try dict($0) }
  }

  private func geminiCandidate(_ chunk: [String: Any]?) throws -> [String: Any] {
    try dict(try list(chunk?["candidates"]).first)
  }

  @Test("gemini: alt=sse chunks are data-only JSON GenerateContentResponses")
  func geminiDataPayloadsParse() throws {
    for stream in [
      F.geminiFunctionCallStream, F.geminiParallelCallsStream, F.geminiTextSignatureStream,
    ] {
      let all = events(stream)
      #expect(!all.isEmpty)
      #expect(all.allSatisfy { $0.name == nil && $0.data != "[DONE]" })
      for event in all {
        #expect(try object(event.data)["candidates"] is [Any])
      }
    }
  }

  @Test("gemini: a functionCall arrives whole in one chunk, args an object, finishReason STOP")
  func geminiFunctionCallArrivesWhole() throws {
    let chunks = try objects(F.geminiFunctionCallStream)
    #expect(chunks.count == 1)
    let call = try dict(try geminiParts(chunks[0]).first?["functionCall"])
    #expect(call["name"] as? String == "get_weather")
    #expect(try dict(call["args"]) as NSDictionary == ["location": "Boston, MA"] as NSDictionary)
    let candidate = try geminiCandidate(chunks.first)
    #expect(candidate["finishReason"] as? String == "STOP")
    #expect(try dict(candidate["content"])["role"] as? String == "model")
  }

  @Test("gemini: thoughtSignature is an opaque string echoed back in its original part")
  func geminiThoughtSignatureIsOpaqueString() throws {
    let streamed = try #require(try geminiParts(try objects(F.geminiFunctionCallStream)[0]).first)
    let signature = try #require(streamed["thoughtSignature"] as? String)
    #expect(!signature.isEmpty)
    let request = try object(F.geminiFollowUpRequest)
    let contents = try list(request["contents"]).map { try dict($0) }
    let model = try #require(contents.first { $0["role"] as? String == "model" })
    let echoed = try dict(try list(model["parts"]).first)
    #expect(isEqual(echoed, streamed))
  }

  @Test("gemini: with parallel calls only the first functionCall part carries a signature")
  func geminiParallelCallsOnlyFirstCarriesSignature() throws {
    let parts = try geminiParts(try objects(F.geminiParallelCallsStream)[0])
    #expect(parts.count == 2)
    #expect(parts.allSatisfy { $0["functionCall"] is [String: Any] })
    #expect(parts[0]["thoughtSignature"] is String)
    #expect(parts[1]["thoughtSignature"] == nil)
  }

  @Test("gemini: a signature may trail on an empty text part in the finishReason chunk")
  func geminiSignatureMayTrailOnEmptyTextPart() throws {
    let chunks = try objects(F.geminiTextSignatureStream)
    #expect(chunks.count == 2)
    #expect(try geminiCandidate(chunks.first)["finishReason"] == nil)
    #expect(try geminiCandidate(chunks.last)["finishReason"] as? String == "STOP")
    let last = try #require(try geminiParts(chunks[1]).last)
    #expect(last["text"] as? String == "")
    #expect(last["thoughtSignature"] is String)
  }

  @Test("gemini: functionResponse goes back in a user content with the call's name")
  func geminiFunctionResponseRoleIsUser() throws {
    let contents = try list(try object(F.geminiFollowUpRequest)["contents"]).map { try dict($0) }
    let last = try #require(contents.last)
    #expect(last["role"] as? String == "user")
    let response = try dict(try dict(try list(last["parts"]).first)["functionResponse"])
    #expect(response["name"] as? String == "get_weather")
    #expect(response["response"] is [String: Any])
  }

  @Test("gemini: request tools are [{functionDeclarations}], key sent as x-goog-api-key")
  func geminiToolsRequestShape() throws {
    #expect(F.geminiAPIKeyHeader == "x-goog-api-key")
    let tools = try list(try object(F.geminiToolsRequest)["tools"])
    let declaration = try dict(try list(try dict(tools.first)["functionDeclarations"]).first)
    #expect(declaration["name"] as? String == "get_weather")
    #expect(try dict(declaration["parameters"])["type"] as? String == "OBJECT")
  }

  @Test("gemini: models.list lists models/{id} with supportedGenerationMethods, nextPageToken")
  func geminiModelsListShape() throws {
    let response = try object(F.geminiModelsListResponse)
    let models = try list(response["models"]).map { try dict($0) }
    let chatModels = models.filter {
      ($0["supportedGenerationMethods"] as? [String])?.contains("generateContent") == true
    }
    #expect(chatModels.compactMap { $0["name"] as? String } == ["models/gemini-2.5-flash-lite"])
    #expect(chatModels.allSatisfy { $0["displayName"] is String })
    #expect(response["nextPageToken"] as? String == "spike-next-page")
  }
}
