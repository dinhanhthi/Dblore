// AISSEParser.swift
// Incremental Server-Sent Events parser for chat-completions, Anthropic Messages and Responses streams

import Foundation

nonisolated enum AIStreamDelta: Equatable, Sendable {
  case text(String)
  /// A complete, validated tool call (known tool, JSON object arguments within the size cap)
  case toolCall(AIToolCall)
  case stop(AIStopReason)
  case done
}

nonisolated enum AIStreamError: LocalizedError, Equatable, Sendable {
  case provider(String)
  /// The model sent a tool call that is refused (unknown tool, malformed or oversized arguments)
  case invalidToolCall(String)

  var errorDescription: String? {
    switch self {
    case .provider(let message): return message
    case .invalidToolCall(let message): return message
    }
  }
}

/// Feed one line at a time; a blank line dispatches the buffered event.
nonisolated struct AISSEParser: Sendable {
  /// Max bytes of one tool call's streamed arguments
  static let maxToolInputBytes = 64 * 1024
  /// Max tool calls assembled at once in one turn
  static let maxPendingToolCalls = 32
  /// Max bytes of one tool call id
  static let maxToolIDBytes = 256

  private struct PendingToolCall: Sendable {
    var id: String?
    var name: String?
    var input = ""
  }

  private let wire: AIWire
  /// Names of the tools offered in the request; a call to any other name is refused
  private let toolNames: Set<String>
  private var eventName: String?
  private var dataLines: [String] = []
  /// Tool calls being assembled, keyed by Messages block index or Chat Completions call index
  private var pendingTools: [Int: PendingToolCall] = [:]

  init(wire: AIWire, toolNames: Set<String> = []) {
    self.wire = wire
    self.toolNames = toolNames
  }

  mutating func consume(line: String) throws(AIStreamError) -> [AIStreamDelta] {
    if line.isEmpty { return try dispatch() }
    if line.hasPrefix(":") { return [] }

    let name: String
    var value: Substring
    if let colon = line.firstIndex(of: ":") {
      name = String(line[..<colon])
      value = line[line.index(after: colon)...]
      if value.hasPrefix(" ") { value = value.dropFirst() }
    } else {
      name = line
      value = ""
    }
    switch name {
    case "event": eventName = String(value)
    case "data": dataLines.append(String(value))
    default: break
    }
    return []
  }

  private mutating func dispatch() throws(AIStreamError) -> [AIStreamDelta] {
    defer {
      eventName = nil
      dataLines = []
    }
    guard !dataLines.isEmpty else { return [] }
    let data = dataLines.joined(separator: "\n")
    if data.trimmingCharacters(in: .whitespaces) == "[DONE]" { return try endStream() }
    guard let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any]
    else { return [] }

    switch wire {
    case .chatCompletions: return try chatDeltas(object)
    case .anthropicMessages: return try anthropicDeltas(object)
    case .responses: return try responsesDeltas(object)
    }
  }

  /// A `choices: []` chunk (the usage chunk of `stream_options.include_usage`) yields nothing.
  /// Tool call fragments join by `index`; a later fragment's absent or null id or name never
  /// overwrites the first one. `finish_reason` completes every pending call.
  private mutating func chatDeltas(
    _ object: [String: Any]
  ) throws(AIStreamError) -> [AIStreamDelta] {
    if let message = Self.errorMessage(object) { throw .provider(message) }
    guard let choices = object["choices"] as? [[String: Any]], let choice = choices.first
    else { return [] }
    var out: [AIStreamDelta] = []
    let delta = choice["delta"] as? [String: Any]
    if let content = delta?["content"] as? String, !content.isEmpty { out.append(.text(content)) }
    let fragments = delta?["tool_calls"] as? [[String: Any]] ?? []
    for (position, fragment) in fragments.enumerated() {
      let index = fragment["index"] as? Int ?? position
      let function = fragment["function"] as? [String: Any]
      try appendTool(
        index: index, id: fragment["id"] as? String, name: function?["name"] as? String,
        input: function?["arguments"] as? String ?? "")
    }
    if let reason = choice["finish_reason"] as? String {
      for index in pendingTools.keys.sorted() { out.append(try finishTool(index: index)) }
      out.append(.stop(Self.chatStopReason(reason)))
    }
    return out
  }

  private mutating func anthropicDeltas(
    _ object: [String: Any]
  ) throws(AIStreamError) -> [AIStreamDelta] {
    let type = (object["type"] as? String) ?? eventName
    switch type {
    case "error":
      throw .provider(Self.errorMessage(object) ?? "The provider returned an error.")
    case "message_stop":
      return try endStream()
    case "content_block_start":
      guard let index = object["index"] as? Int,
        let block = object["content_block"] as? [String: Any],
        block["type"] as? String == "tool_use"
      else { return [] }
      guard let id = block["id"] as? String, let name = block["name"] as? String else {
        throw .invalidToolCall("The model sent a tool call without an id or a name.")
      }
      try appendTool(index: index, id: id, name: name, input: "")
      return []
    case "content_block_delta":
      guard let delta = object["delta"] as? [String: Any] else { return [] }
      switch delta["type"] as? String {
      case "text_delta":
        guard let text = delta["text"] as? String, !text.isEmpty else { return [] }
        return [.text(text)]
      case "input_json_delta":
        guard let index = object["index"] as? Int, pendingTools[index] != nil,
          let piece = delta["partial_json"] as? String
        else { return [] }
        try appendTool(index: index, id: nil, name: nil, input: piece)
        return []
      default:
        return []
      }
    case "content_block_stop":
      guard let index = object["index"] as? Int, pendingTools[index] != nil else { return [] }
      return [try finishTool(index: index)]
    case "message_delta":
      guard let delta = object["delta"] as? [String: Any],
        let reason = delta["stop_reason"] as? String
      else { return [] }
      return [.stop(Self.anthropicStopReason(reason))]
    default:
      return []
    }
  }

  /// Adds one streamed piece to a pending tool call, refusing an unknown tool name or arguments
  /// over the cap before they are buffered
  private mutating func appendTool(
    index: Int, id: String?, name: String?, input: String
  ) throws(AIStreamError) {
    if pendingTools[index] == nil, pendingTools.count >= Self.maxPendingToolCalls {
      throw .invalidToolCall("The model sent too many tool calls.")
    }
    var call = pendingTools[index] ?? PendingToolCall()
    if let id, call.id == nil {
      guard id.utf8.count <= Self.maxToolIDBytes else {
        throw .invalidToolCall("The model sent an oversized tool call id.")
      }
      call.id = id
    }
    if let name, call.name == nil {
      guard toolNames.contains(name) else {
        throw .invalidToolCall("The model called a tool that was not offered.")
      }
      call.name = name
    }
    guard call.input.utf8.count + input.utf8.count <= Self.maxToolInputBytes else {
      throw .invalidToolCall("The model sent tool arguments over 64 KiB.")
    }
    call.input += input
    pendingTools[index] = call
  }

  /// Completes a pending tool call: an id, an offered name and a JSON object (empty means `{}`).
  /// `inputJSON` is the parsed object re-serialized (sorted keys), never the raw text, so the
  /// call executed and the call echoed back are the one validated here. A non-finite number
  /// (`-1e999` parses to -inf) is refused: serializing it would raise.
  private mutating func finishTool(index: Int) throws(AIStreamError) -> AIStreamDelta {
    let call = pendingTools.removeValue(forKey: index) ?? PendingToolCall()
    guard let id = call.id, !id.isEmpty, let name = call.name else {
      throw .invalidToolCall("The model sent a tool call without an id or a name.")
    }
    let input = call.input.isEmpty ? "{}" : call.input
    guard let object = try? JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any],
      JSONSerialization.isValidJSONObject(object),
      let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
      let inputJSON = String(data: data, encoding: .utf8)
    else { throw .invalidToolCall("The model sent malformed tool arguments.") }
    return .toolCall(AIToolCall(id: id, name: name, inputJSON: inputJSON))
  }

  /// The end of the stream; a tool call still being assembled was cut off
  private func endStream() throws(AIStreamError) -> [AIStreamDelta] {
    guard pendingTools.isEmpty else {
      throw .invalidToolCall("The model's tool call was cut off.")
    }
    return [.done]
  }

  private static func anthropicStopReason(_ reason: String) -> AIStopReason {
    switch reason {
    case "end_turn": return .endTurn
    case "tool_use": return .toolUse
    case "max_tokens": return .maxTokens
    default: return .other(reason)
    }
  }

  private static func chatStopReason(_ reason: String) -> AIStopReason {
    switch reason {
    case "stop": return .endTurn
    case "tool_calls": return .toolUse
    case "length": return .maxTokens
    default: return .other(reason)
    }
  }

  private func responsesDeltas(_ object: [String: Any]) throws(AIStreamError) -> [AIStreamDelta] {
    let type = (object["type"] as? String) ?? eventName
    switch type {
    case "response.output_text.delta":
      guard let text = object["delta"] as? String, !text.isEmpty else { return [] }
      return [.text(text)]
    case "response.completed", "response.incomplete":
      return [.done]
    case "response.failed":
      let response = object["response"] as? [String: Any]
      let message = (response?["error"] as? [String: Any])?["message"] as? String
      throw .provider(message ?? "The provider returned an error.")
    case "error":
      let message = Self.errorMessage(object) ?? (object["message"] as? String)
      throw .provider(message ?? "The provider returned an error.")
    default:
      return []
    }
  }

  private static func errorMessage(_ object: [String: Any]) -> String? {
    if let text = object["error"] as? String, !text.isEmpty { return text }
    return (object["error"] as? [String: Any])?["message"] as? String
  }
}
