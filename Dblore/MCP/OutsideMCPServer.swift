// OutsideMCPServer.swift
// An outside MCP server the AI chat may call: name, endpoint URL, on/off and the tools allowed
// on it, each with the fingerprint of the tool as it was when ticked. `OutsideMCPToolGate` is
// the one rule for offering and calling a tool. The token is not here: it lives in the Keychain
// (`OutsideMCPTokenStore`), keyed by the server id. `OutsideMCPText` makes server text safe to
// show and to hand to the model.

import Foundation

nonisolated struct OutsideMCPServer: Codable, Identifiable, Equatable, Sendable {
  static let nameLimit = 64
  static let urlLimit = 2_048

  var id: UUID
  var name: String
  /// Checked by `MCPClient.endpoint` when added, when loaded and when a client is made
  var url: String
  /// Off when added: the server is tested and its tools ticked first
  var isEnabled: Bool
  /// Tool name to `MCPClientTool.fingerprint` of the tool the user ticked. A tool whose
  /// description or schema changed since then no longer matches and is refused.
  var allowedTools: [String: String]

  init(
    id: UUID = UUID(), name: String, url: String, isEnabled: Bool = false,
    allowedTools: [String: String] = [:]
  ) {
    self.id = id
    self.name = name
    self.url = url
    self.isEnabled = isEnabled
    self.allowedTools = Self.validTools(allowedTools)
  }

  /// Saved data is untrusted: a missing flag is off, bad entries are dropped. Data saved before
  /// fingerprints (`allowedToolNames`) is ignored, so those tools are ticked again.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    url = try container.decode(String.self, forKey: .url)
    isEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? false
    allowedTools = Self.validTools(
      ((try? container.decodeIfPresent([String: String].self, forKey: .allowedTools)) ?? nil)
        ?? [:])
  }

  /// Valid names with a SHA-256 hex fingerprint, at most `MCPClient.maxTools` (by name order).
  static func validTools(_ tools: [String: String]) -> [String: String] {
    let valid = tools.filter {
      MCPClient.isValidToolName($0.key) && MCPClientTool.isFingerprint($0.value)
    }
    let kept = valid.keys.sorted().prefix(MCPClient.maxTools)
    return valid.filter { kept.contains($0.key) }
  }

  /// Shown text, at most `nameLimit` scalars; nil when blank.
  static func normalizedName(_ name: String) -> String? {
    let shown = OutsideMCPText.capped(
      OutsideMCPText.display(name, limit: .max), limit: nameLimit, note: "")
    return shown.isEmpty ? nil : shown
  }
}

/// The one rule for outside tools. A tool is offered to the AI chat, and a tools/call sent, only
/// when the server is on, the name is valid, the user ticked it, it is in the latest tools/list
/// from that server, and its fingerprint still matches the one ticked. `MCPClient.callTool`
/// checks it on the live server, against the client's own latest list, before any request.
nonisolated enum OutsideMCPToolGate {
  enum ToolState: Equatable, Sendable {
    case notAllowed
    case allowed
    /// Ticked, but the description or schema changed since: review and tick again
    case changed
  }

  /// The listed tool `name` when it may be called on `server`; throws why not.
  static func allowedTool(
    _ name: String, on server: OutsideMCPServer, listed: [MCPClientTool]
  ) throws -> MCPClientTool {
    guard server.isEnabled else { throw MCPClientError.serverDisabled }
    guard MCPClient.isValidToolName(name) else { throw MCPClientError.invalidToolName }
    guard let fingerprint = server.allowedTools[name] else {
      throw MCPClientError.toolNotAllowed
    }
    guard let tool = listed.first(where: { $0.name == name }) else {
      throw MCPClientError.toolNotListed
    }
    guard tool.fingerprint == fingerprint else { throw MCPClientError.toolChanged }
    return tool
  }

  /// The listed tools that may be offered on `server`, in list order.
  static func offeredTools(on server: OutsideMCPServer, listed: [MCPClientTool]) -> [MCPClientTool]
  {
    listed.filter { (try? allowedTool($0.name, on: server, listed: listed)) != nil }
  }

  /// Whether `tool`, as listed now, is ticked on `server`; ignores the on/off switch.
  static func state(of tool: MCPClientTool, on server: OutsideMCPServer) -> ToolState {
    guard let fingerprint = server.allowedTools[tool.name] else { return .notAllowed }
    return fingerprint == tool.fingerprint ? .allowed : .changed
  }
}

/// Server text made safe: format characters (bidi controls, zero-width, the tag block),
/// private-use, unassigned and other default-ignorable code points are dropped; every space
/// separator becomes a plain space; at most `maxMarksPerBase` combining marks follow one base.
/// Every cap counts unicode scalars, not characters.
nonisolated enum OutsideMCPText {
  static let maxMarksPerBase = 8

  /// One line to show: controls and line separators become spaces; runs of white space become
  /// one space, trimmed; then at most `limit` scalars, with "…" when cut.
  static func display(_ text: String, limit: Int) -> String {
    let shown = String(filtered(text, keepsLines: false)).split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
    return capped(shown, limit: limit, note: "…")
  }

  /// Text for the model, still untrusted data: tab and line breaks are kept (line and paragraph
  /// separators become "\n"), other controls are dropped; then at most `limit` scalars, with
  /// `note` when cut.
  static func untrusted(_ text: String, limit: Int, note: String = "") -> String {
    capped(String(filtered(text, keepsLines: true)), limit: limit, note: note)
  }

  /// At most `limit` unicode scalars of `text`, then `note` when cut.
  static func capped(_ text: String, limit: Int, note: String) -> String {
    guard !text.unicodeScalars.dropFirst(max(limit, 0)).isEmpty else { return text }
    var scalars = String.UnicodeScalarView()
    scalars.append(contentsOf: text.unicodeScalars.prefix(max(limit, 0)))
    return String(scalars) + note
  }

  private static func filtered(_ text: String, keepsLines: Bool) -> String.UnicodeScalarView {
    var scalars = String.UnicodeScalarView()
    // Combining marks kept since the last kept scalar that is not one
    var marks = 0
    for scalar in text.unicodeScalars {
      let kept: Unicode.Scalar?
      switch scalar.properties.generalCategory {
      case .format, .privateUse, .unassigned, .surrogate:
        kept = nil
      case .spaceSeparator:
        kept = " "
      case .control:
        if !keepsLines {
          kept = " "
        } else if scalar == "\t" || scalar == "\n" || scalar == "\r" {
          kept = scalar
        } else {
          kept = nil
        }
      case .lineSeparator, .paragraphSeparator:
        kept = keepsLines ? "\n" : " "
      case .nonspacingMark, .spacingMark, .enclosingMark:
        guard !scalar.properties.isDefaultIgnorableCodePoint, marks < maxMarksPerBase else {
          continue
        }
        marks += 1
        scalars.append(scalar)
        continue
      default:
        kept = scalar.properties.isDefaultIgnorableCodePoint ? nil : scalar
      }
      guard let kept else { continue }
      marks = 0
      scalars.append(kept)
    }
    return scalars
  }
}
