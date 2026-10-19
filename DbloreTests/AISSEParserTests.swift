import Foundation
import Testing

@testable import Dblore

@Suite("AISSEParser")
struct AISSEParserTests {

  private typealias F = AIToolCallFixtures

  private func run(
    _ wire: AIWire, _ lines: [String], tools: Set<String> = []
  ) throws(AIStreamError) -> [AIStreamDelta] {
    var parser = AISSEParser(wire: wire, toolNames: tools)
    var out: [AIStreamDelta] = []
    for line in lines { out += try parser.consume(line: line) }
    return out
  }

  /// Feeds a whole fixture stream; blank lines dispatch events
  private func run(
    _ wire: AIWire, stream: String, tools: Set<String> = ["get_weather"]
  ) throws(AIStreamError) -> [AIStreamDelta] {
    try run(
      wire, stream.split(separator: "\n", omittingEmptySubsequences: false).map(String.init),
      tools: tools)
  }

  private func toolCalls(_ deltas: [AIStreamDelta]) -> [AIToolCall] {
    deltas.compactMap { delta in
      if case .toolCall(let call) = delta { return call }
      return nil
    }
  }

  @Test("chatCompletions accumulates text and ends with done")
  func chatText() throws {
    let out = try run(
      .chatCompletions,
      [
        #"data: {"choices":[{"delta":{"content":"SELECT"}}]}"#, "",
        #"data: {"choices":[{"delta":{"content":" 1"}}]}"#, "",
        #"data: {"choices":[{"delta":{}}]}"#, "",
        "data: [DONE]", "",
      ])
    #expect(out == [.text("SELECT"), .text(" 1"), .done])
  }

  @Test("chatCompletions top-level error throws its message")
  func chatError() {
    #expect(throws: AIStreamError.provider("Rate limited")) {
      try run(.chatCompletions, [#"data: {"error":{"message":"Rate limited"}}"#, ""])
    }
  }

  @Test("chatCompletions top-level string error throws its text")
  func chatStringError() {
    #expect(throws: AIStreamError.provider("model not found")) {
      try run(.chatCompletions, [#"data: {"error":"model not found"}"#, ""])
    }
  }

  @Test("multi-line data is joined with newline")
  func multiLineData() throws {
    let out = try run(
      .chatCompletions,
      [
        #"data: {"choices":[{"delta":"#,
        #"data: {"content":"hi"}}]}"#, "",
      ])
    #expect(out == [.text("hi")])
  }

  @Test("malformed JSON is skipped")
  func malformed() throws {
    let out = try run(
      .chatCompletions,
      ["data: {not json", "", #"data: {"choices":[{"delta":{"content":"ok"}}]}"#, ""])
    #expect(out == [.text("ok")])
  }

  @Test("comments are ignored")
  func comments() throws {
    let out = try run(
      .chatCompletions, [": keep-alive", #"data: {"choices":[{"delta":{"content":"a"}}]}"#, ""])
    #expect(out == [.text("a")])
  }

  @Test("anthropic text deltas and message_stop")
  func anthropicText() throws {
    let out = try run(
      .anthropicMessages,
      [
        "event: message_start", #"data: {"type":"message_start","message":{}}"#, "",
        "event: content_block_delta",
        #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}"#,
        "",
        "event: content_block_delta",
        #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}"#,
        "",
        "event: message_stop", #"data: {"type":"message_stop"}"#, "",
      ])
    #expect(out == [.text("Hel"), .text("lo"), .done])
  }

  @Test("anthropic non-text deltas and ping are ignored")
  func anthropicIgnored() throws {
    let out = try run(
      .anthropicMessages,
      [
        "event: ping", #"data: {"type":"ping"}"#, "",
        "event: content_block_delta",
        #"data: {"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"{}"}}"#,
        "",
      ])
    #expect(out.isEmpty)
  }

  @Test("anthropic error event throws its message")
  func anthropicError() {
    #expect(throws: AIStreamError.provider("Overloaded")) {
      try run(
        .anthropicMessages,
        [
          "event: error",
          #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#,
          "",
        ])
    }
  }

  // MARK: - Tool calls

  @Test("anthropic tool_use stream assembles one call after the text, then stops on tool_use")
  func anthropicToolUseFixture() throws {
    let out = try run(.anthropicMessages, stream: F.messagesToolUseStream)
    let call = AIToolCall(
      id: "toolu_01T1x1fJ34qAmk2tNTrN7Up6", name: "get_weather",
      inputJSON: #"{"location":"San Francisco, CA"}"#)
    let text = out.compactMap { delta -> String? in
      if case .text(let text) = delta { return text }
      return nil
    }
    #expect(text.joined() == "Okay, let's check the weather for San Francisco, CA:")
    #expect(Array(out.suffix(3)) == [.toolCall(call), .stop(.toolUse), .done])
    #expect(toolCalls(out) == [call])
  }

  @Test("anthropic stop_reason values map to stop reasons")
  func anthropicStopReasons() throws {
    for (raw, reason) in [
      ("end_turn", AIStopReason.endTurn), ("max_tokens", .maxTokens),
      ("stop_sequence", .other("stop_sequence")),
    ] {
      let out = try run(
        .anthropicMessages,
        [#"data: {"type":"message_delta","delta":{"stop_reason":"\#(raw)"}}"#, ""])
      #expect(out == [.stop(reason)])
    }
  }

  @Test("anthropic tool call with no input deltas has empty object arguments")
  func anthropicEmptyInput() throws {
    let out = try run(
      .anthropicMessages,
      [
        #"data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t1","name":"list_tables","input":{}}}"#,
        "",
        #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":""}}"#,
        "", #"data: {"type":"content_block_stop","index":0}"#, "",
      ], tools: ["list_tables"])
    #expect(out == [.toolCall(AIToolCall(id: "t1", name: "list_tables", inputJSON: "{}"))])
  }

  @Test("anthropic unknown tool name is refused")
  func anthropicUnknownTool() {
    #expect(throws: AIStreamError.invalidToolCall("The model called a tool that was not offered."))
    {
      try run(.anthropicMessages, stream: F.messagesToolUseStream, tools: ["list_tables"])
    }
  }

  @Test("anthropic malformed tool arguments are refused at block stop")
  func anthropicMalformedInput() {
    #expect(throws: AIStreamError.invalidToolCall("The model sent malformed tool arguments.")) {
      try run(
        .anthropicMessages,
        [
          #"data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"t1","name":"get_weather","input":{}}}"#,
          "",
          #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"location\":"}}"#,
          "", #"data: {"type":"content_block_stop","index":1}"#, "",
        ], tools: ["get_weather"])
    }
  }

  @Test("anthropic tool arguments over 64 KiB are refused before the block stops")
  func anthropicOversizedInput() throws {
    var parser = AISSEParser(wire: .anthropicMessages, toolNames: ["get_weather"])
    for line in [
      #"data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t1","name":"get_weather","input":{}}}"#,
      "",
    ] {
      _ = try parser.consume(line: line)
    }
    let piece = "{\\\"location\\\":\\\"" + String(repeating: "a", count: 40_000)
    let delta =
      #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":""#
      + piece + #""}}"#
    _ = try parser.consume(line: delta)
    _ = try parser.consume(line: "")
    _ = try parser.consume(line: delta)
    #expect(throws: AIStreamError.invalidToolCall("The model sent tool arguments over 64 KiB.")) {
      try parser.consume(line: "")
    }
  }

  @Test("chat tool call fragments join by index, then stop on tool_calls")
  func chatToolCallFixture() throws {
    let call = AIToolCall(
      id: "call_DdmO9pD3xa9XTPNJ32zg2hcA", name: "get_weather",
      inputJSON: #"{"location":"Paris, France"}"#)
    for stream in [F.chatCompletionsToolCallStream, F.chatCompletionsNullFragmentStream] {
      let out = try run(.chatCompletions, stream: stream)
      #expect(out == [.toolCall(call), .stop(.toolUse), .done])
    }
  }

  @Test("chat parallel tool calls come out in index order")
  func chatParallelFixture() throws {
    let out = try run(.chatCompletions, stream: F.chatCompletionsParallelStream)
    #expect(
      out == [
        .toolCall(
          AIToolCall(
            id: "call_paris", name: "get_weather", inputJSON: #"{"location":"Paris, France"}"#)
        ),
        .toolCall(
          AIToolCall(
            id: "call_london", name: "get_weather", inputJSON: #"{"location":"London, UK"}"#)
        ),
        .stop(.toolUse), .done,
      ])
  }

  @Test("chat empty choices usage chunk is accepted before [DONE]")
  func chatEmptyChoicesUsage() throws {
    let out = try run(
      .chatCompletions,
      [
        #"data: {"choices":[{"index":0,"delta":{"content":"hi"},"finish_reason":null}]}"#, "",
        #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#, "",
        #"data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":9,"completion_tokens":1,"total_tokens":10}}"#,
        "", "data: [DONE]", "",
      ])
    #expect(out == [.text("hi"), .stop(.endTurn), .done])
  }

  @Test("chat finish_reason values map to stop reasons")
  func chatStopReasons() throws {
    for (raw, reason) in [
      ("length", AIStopReason.maxTokens), ("content_filter", .other("content_filter")),
    ] {
      let out = try run(
        .chatCompletions, [#"data: {"choices":[{"delta":{},"finish_reason":"\#(raw)"}]}"#, ""])
      #expect(out == [.stop(reason)])
    }
  }

  @Test("chat unknown tool name is refused")
  func chatUnknownTool() {
    #expect(throws: AIStreamError.invalidToolCall("The model called a tool that was not offered."))
    {
      try run(.chatCompletions, stream: F.chatCompletionsToolCallStream, tools: [])
    }
  }

  @Test("chat malformed tool arguments are refused at finish_reason")
  func chatMalformedArguments() {
    #expect(throws: AIStreamError.invalidToolCall("The model sent malformed tool arguments.")) {
      try run(
        .chatCompletions,
        [
          #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"get_weather","arguments":"{\"loc"}}]}}]}"#,
          "", #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#, "",
        ], tools: ["get_weather"])
    }
  }

  @Test("chat tool arguments that are JSON but not an object are refused")
  func chatNonObjectArguments() {
    #expect(throws: AIStreamError.invalidToolCall("The model sent malformed tool arguments.")) {
      try run(
        .chatCompletions,
        [
          #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"get_weather","arguments":"[1]"}}]}}]}"#,
          "", #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#, "",
        ], tools: ["get_weather"])
    }
  }

  @Test("chat tool arguments over 64 KiB are refused while streaming")
  func chatOversizedArguments() {
    let piece = String(repeating: "a", count: AISSEParser.maxToolInputBytes + 1)
    #expect(throws: AIStreamError.invalidToolCall("The model sent tool arguments over 64 KiB.")) {
      try run(
        .chatCompletions,
        [
          #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"get_weather","arguments":""}}]}}]}"#,
          "",
          #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":""#
            + piece + #""}}]}}]}"#,
          "",
        ], tools: ["get_weather"])
    }
  }

  private func chatToolLine(index: Int, id: String = "c1", arguments: String) -> String {
    let escaped = arguments.replacingOccurrences(of: "\"", with: #"\""#)
    return
      #"data: {"choices":[{"delta":{"tool_calls":[{"index":\#(index),"id":"\#(id)","type":"function","function":{"name":"get_weather","arguments":"\#(escaped)"}}]}}]}"#
  }

  private let chatFinish = #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#

  @Test("tool arguments come out re-serialized with sorted keys on both wires")
  func canonicalArguments() throws {
    let raw = #"{ "b" : 2,  "a" : 1, "a" : 3 }"#
    let chat = try run(
      .chatCompletions, [chatToolLine(index: 0, arguments: raw), "", chatFinish, ""],
      tools: ["get_weather"])
    #expect(toolCalls(chat).map(\.inputJSON) == [#"{"a":1,"b":2}"#])
    let escaped = raw.replacingOccurrences(of: "\"", with: #"\""#)
    let messages = try run(
      .anthropicMessages,
      [
        #"data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t1","name":"get_weather","input":{}}}"#,
        "",
        #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\#(escaped)"}}"#,
        "", #"data: {"type":"content_block_stop","index":0}"#, "",
      ], tools: ["get_weather"])
    #expect(toolCalls(messages).map(\.inputJSON) == [#"{"a":1,"b":2}"#])
  }

  /// `1e999` fails to parse; `-1e999` parses to -inf, which would raise when serialized
  @Test("non-finite tool arguments are refused, never serialized", arguments: ["1e999", "-1e999"])
  func nonFiniteArguments(number: String) {
    #expect(throws: AIStreamError.invalidToolCall("The model sent malformed tool arguments.")) {
      try run(
        .chatCompletions,
        [chatToolLine(index: 0, arguments: #"{"x": \#(number)}"#), "", chatFinish, ""],
        tools: ["get_weather"])
    }
  }

  @Test("chat refuses more pending tool calls than the cap")
  func chatTooManyToolCalls() {
    let fragments = (0...AISSEParser.maxPendingToolCalls).map { index in
      #"{"index":\#(index),"id":"c\#(index)","type":"function","function":{"name":"get_weather","arguments":""}}"#
    }
    let line =
      #"data: {"choices":[{"delta":{"tool_calls":["#
      + fragments.joined(separator: ",") + "]}}]}"
    #expect(throws: AIStreamError.invalidToolCall("The model sent too many tool calls.")) {
      try run(.chatCompletions, [line, ""], tools: ["get_weather"])
    }
  }

  @Test("tool call id over 256 bytes is refused")
  func oversizedToolID() throws {
    let atCap = String(repeating: "a", count: AISSEParser.maxToolIDBytes)
    let out = try run(
      .chatCompletions, [chatToolLine(index: 0, id: atCap, arguments: "{}"), "", chatFinish, ""],
      tools: ["get_weather"])
    #expect(toolCalls(out).map(\.id) == [atCap])
    #expect(throws: AIStreamError.invalidToolCall("The model sent an oversized tool call id.")) {
      try run(
        .chatCompletions, [chatToolLine(index: 0, id: atCap + "a", arguments: "{}"), ""],
        tools: ["get_weather"])
    }
  }

  @Test("chat [DONE] with a pending tool call is refused")
  func chatCutOffToolCall() {
    #expect(throws: AIStreamError.invalidToolCall("The model's tool call was cut off.")) {
      try run(
        .chatCompletions, [chatToolLine(index: 0, arguments: "{}"), "", "data: [DONE]", ""],
        tools: ["get_weather"])
    }
  }

  @Test("end of body without a terminal event refuses a pending tool call")
  func bodyEndsWithPendingToolCall() throws {
    var parser = AISSEParser(wire: .chatCompletions, toolNames: ["get_weather"])
    _ = try parser.consume(line: chatToolLine(index: 0, arguments: "{}"))
    _ = try parser.consume(line: "")
    #expect(throws: AIStreamError.invalidToolCall("The model's tool call was cut off.")) {
      try parser.endOfBody()
    }
    try AISSEParser(wire: .chatCompletions).endOfBody()
  }

  @Test("anthropic message_stop with a pending tool call is refused")
  func anthropicCutOffToolCall() {
    #expect(throws: AIStreamError.invalidToolCall("The model's tool call was cut off.")) {
      try run(
        .anthropicMessages,
        [
          #"data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t1","name":"get_weather","input":{}}}"#,
          "", #"data: {"type":"message_stop"}"#, "",
        ], tools: ["get_weather"])
    }
  }

  /// The ChatGPT route uses the text protocol (no native tools), so the Responses wire has no
  /// function-call handling: its events are ignored even when the name was offered.
  @Test("responses function_call events never become tool calls", arguments: [[], ["get_weather"]])
  func responsesFunctionCallIgnored(tools: Set<String>) throws {
    let out = try run(.responses, stream: F.responsesFunctionCallStream, tools: tools)
    #expect(out == [.done])
  }
}
