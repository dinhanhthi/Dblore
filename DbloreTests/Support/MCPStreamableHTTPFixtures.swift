// MCPStreamableHTTPFixtures.swift
// Scripted MCP Streamable HTTP bodies (spec 2025-06-18) for client-side parsing tests: a POST
// answered with `Content-Type: text/event-stream`, where the server sends a notification before
// the JSON-RPC response of the request, each as one SSE event. Dblore's own server answers JSON
// only, so this shape comes from other MCP servers.

import Foundation

enum MCPStreamableHTTPFixtures {
  /// The JSON-RPC id of the request `toolsCallStream` answers.
  static let responseID = 7

  /// A notification with no id, sent before the response.
  static let progressNotification =
    #"{"jsonrpc":"2.0","method":"notifications/progress","#
    + #""params":{"progressToken":"t1","progress":1,"total":2}}"#

  /// The tools/call response that ends the stream.
  static let toolsCallResponse =
    #"{"jsonrpc":"2.0","id":\#(responseID),"result":{"content":["#
    + #"{"type":"text","text":"ok"}],"isError":false}}"#

  /// A JSON-RPC error response, as an SSE stream may carry instead of a result.
  static let errorResponse =
    #"{"jsonrpc":"2.0","id":\#(responseID),"error":{"code":-32602,"message":"Unknown tool"}}"#

  /// A `text/event-stream` body: a comment, the notification, then the response, each an
  /// `event: message` with one `data:` line and a blank line after it.
  static let toolsCallStream = stream(progressNotification, toolsCallResponse)

  /// The same framing ending with `errorResponse`.
  static let errorStream = stream(errorResponse)

  private static func stream(_ messages: String...) -> String {
    ": keep-alive\n\n"
      + messages.map { "id: \(UUID().uuidString)\nevent: message\ndata: \($0)\n\n" }.joined()
  }
}
