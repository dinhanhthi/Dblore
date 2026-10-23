// AIToolSpec.swift
// Provider-agnostic tool definitions, tool calls and tool results for AI chat

import Foundation

/// A tool offered to the model. `parameters` is the JSON Schema of its arguments.
nonisolated struct AIToolSpec: Sendable, Equatable {
  let name: String
  let description: String
  let parameters: JSONValue

  /// `parameters` as a JSONSerialization object, for request bodies
  var parametersObject: Any {
    guard let data = try? JSONEncoder().encode(parameters),
      let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    else { return [String: Any]() }
    return object
  }
}

/// A tool call from the model. `inputJSON` is the validated arguments object re-serialized with
/// sorted keys (never the raw model text); it is still untrusted model output.
nonisolated struct AIToolCall: Codable, Equatable, Sendable {
  let id: String
  let name: String
  let inputJSON: String
  /// Opaque provider value (Gemini `thoughtSignature`) sent back unchanged with the call
  var signature: String? = nil
}

/// The app's answer to a tool call, matched by `id`
nonisolated struct AIToolResult: Codable, Equatable, Sendable {
  let id: String
  let content: String
  let isError: Bool
}

/// An outside MCP tool a turn offers (`AITools.outsideTools`): the name the model calls and the
/// server tool it maps back to. The map is rebuilt every turn; a name is never parsed.
nonisolated struct AIOutsideTool: Equatable, Sendable {
  let name: String
  let serverID: UUID
  /// The server's name as shown (sanitized)
  let serverName: String
  /// The tool's name on its server
  let tool: String
  let spec: AIToolSpec
}
