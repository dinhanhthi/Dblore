// AITextToolProtocol.swift
// Tool calls written as one fenced tool block of strict JSON, for wires without native tools

import Foundation

/// The text protocol for tool calls: the system prompt lists the tools and the model answers
/// with one fenced `tool` block of strict JSON `{"tool": name, "arguments": {...}}`, which
/// `AIMessageParser.toolCall(in:toolNames:)` reads. Never used for on-device models (no tools).
nonisolated enum AITextToolProtocol {

  /// Fence language of a tool call block
  static let fenceLanguage = "tool"

  /// System prompt section describing the protocol and the offered tools (name, description and
  /// the JSON Schema of the arguments)
  static func systemSection(tools: [AIToolSpec]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let list = tools.map { tool in
      let schema =
        (try? encoder.encode(tool.parameters)).flatMap { String(data: $0, encoding: .utf8) }
        ?? "{}"
      return "- \(tool.name): \(tool.description)\n  Arguments schema: \(schema)"
    }
    return """
      Tools:
      - To call a tool, reply with exactly one ```\(fenceLanguage) block and stop; call at most one tool per reply.
      - The block holds only one strict JSON object with exactly two keys: "tool" (the tool name) and "arguments" (a JSON object matching the tool's arguments schema, {} when it has none). Example:
      ```\(fenceLanguage)
      {"tool": "name", "arguments": {}}
      ```
      - Any explanation goes outside the block. Only call the tools listed here.
      Available tools:
      \(list.joined(separator: "\n"))
      """
  }
}
