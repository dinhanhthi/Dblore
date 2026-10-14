// MCPClientConfigSnippetTests.swift
// The client setup snippets shown in Settings > MCP: the Claude Code command and the Cursor
// `mcpServers` JSON carry the port and the bearer token.

import Foundation
import Testing

@testable import Dblore

@Suite("MCP client config snippets")
struct MCPClientConfigSnippetTests {
  private let token = "AbC-123_xyz"

  @Test("Cursor JSON parses to mcpServers.dblore with url and Authorization header")
  func cursorJSON() throws {
    let json = MCPClientConfigSnippet.cursorJSON(port: 5000, token: token)
    #expect(json.contains(#""url" : "http://127.0.0.1:5000/mcp""#))
    let object = try #require(
      try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    let servers = try #require(object["mcpServers"] as? [String: Any])
    let dblore = try #require(servers["dblore"] as? [String: Any])
    #expect(dblore["url"] as? String == "http://127.0.0.1:5000/mcp")
    #expect(dblore["headers"] as? [String: String] == ["Authorization": "Bearer AbC-123_xyz"])
  }
}
