import Foundation
import Testing

@testable import Dblore

@Suite("AISSEParser")
struct AISSEParserTests {

  private func run(_ wire: AIWire, _ lines: [String]) throws -> [AIStreamDelta] {
    var parser = AISSEParser(wire: wire)
    var out: [AIStreamDelta] = []
    for line in lines { out += try parser.consume(line: line) }
    return out
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
}
