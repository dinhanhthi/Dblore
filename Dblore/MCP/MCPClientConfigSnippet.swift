// MCPClientConfigSnippet.swift
// What Settings > MCP copies for a client: the Claude Code command and the Cursor `mcpServers`
// JSON, both pointing at the loopback endpoint with the bearer token. The token is base64url,
// so single quotes keep the header one shell word in zsh and bash.

import Foundation

nonisolated enum MCPClientConfigSnippet {
  static let serverName = "dblore"

  static func url(port: Int) -> String {
    "http://\(MCPHTTPServer.host):\(port)\(MCPRequestValidator.path)"
  }

  static func claudeCodeCommand(port: Int, token: String) -> String {
    "claude mcp add --transport http \(serverName) \(url(port: port))"
      + " --header 'Authorization: Bearer \(token)'"
  }

  /// Pretty, sorted keys, slashes unescaped.
  static func cursorJSON(port: Int, token: String) -> String {
    let object: [String: Any] = [
      "mcpServers": [
        serverName: [
          "url": url(port: port),
          "headers": ["Authorization": "Bearer \(token)"],
        ]
      ]
    ]
    let data =
      (try? JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
      ?? Data()
    return String(decoding: data, as: UTF8.self)
  }
}
