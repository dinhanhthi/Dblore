// AISSEParser.swift
// Incremental Server-Sent Events parser for chat-completions and Anthropic Messages streams

import Foundation

nonisolated enum AIStreamDelta: Equatable, Sendable {
  case text(String)
  case done
}

nonisolated enum AIStreamError: LocalizedError, Equatable, Sendable {
  case provider(String)

  var errorDescription: String? {
    switch self {
    case .provider(let message): return message
    }
  }
}

/// Feed one line at a time; a blank line dispatches the buffered event.
nonisolated struct AISSEParser: Sendable {
  private let wire: AIWire
  private var eventName: String?
  private var dataLines: [String] = []

  init(wire: AIWire) {
    self.wire = wire
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
    if data.trimmingCharacters(in: .whitespaces) == "[DONE]" { return [.done] }
    guard let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any]
    else { return [] }

    switch wire {
    case .chatCompletions: return try chatDeltas(object)
    case .anthropicMessages: return try anthropicDeltas(object)
    }
  }

  private func chatDeltas(_ object: [String: Any]) throws(AIStreamError) -> [AIStreamDelta] {
    if let message = Self.errorMessage(object) { throw .provider(message) }
    guard let choices = object["choices"] as? [[String: Any]],
      let delta = choices.first?["delta"] as? [String: Any],
      let content = delta["content"] as? String, !content.isEmpty
    else { return [] }
    return [.text(content)]
  }

  private func anthropicDeltas(_ object: [String: Any]) throws(AIStreamError) -> [AIStreamDelta] {
    let type = (object["type"] as? String) ?? eventName
    switch type {
    case "error":
      throw .provider(Self.errorMessage(object) ?? "The provider returned an error.")
    case "message_stop":
      return [.done]
    case "content_block_delta":
      guard let delta = object["delta"] as? [String: Any],
        delta["type"] as? String == "text_delta",
        let text = delta["text"] as? String, !text.isEmpty
      else { return [] }
      return [.text(text)]
    default:
      return []
    }
  }

  private static func errorMessage(_ object: [String: Any]) -> String? {
    if let text = object["error"] as? String, !text.isEmpty { return text }
    return (object["error"] as? [String: Any])?["message"] as? String
  }
}
