// MarkdownPreviewBridge.swift
// Pure logic for the Milkdown preview (no WebKit): parses bridge messages, keeps the note source
// byte-identical unless a real WYSIWYG edit happened, filters links, and resolves theme colors.

import SwiftUI

/// A message posted by the editor page via `window.webkit.messageHandlers.dblore`.
enum MarkdownBridgeMessage: Equatable {
  case ready(String)
  case changed(String)
  case openLink(String)

  /// Parses a `WKScriptMessage.body`; nil for any shape outside the bridge contract.
  init?(body: Any) {
    guard let dict = body as? [String: Any], let type = dict["type"] as? String else { return nil }
    switch type {
    case "ready":
      guard let markdown = dict["markdown"] as? String else { return nil }
      self = .ready(markdown)
    case "changed":
      guard let markdown = dict["markdown"] as? String else { return nil }
      self = .changed(markdown)
    case "openLink":
      guard let href = dict["href"] as? String else { return nil }
      self = .openLink(href)
    default:
      return nil
    }
  }
}

/// Maps editor output back to note text. Milkdown normalizes the source on load, so output is
/// compared with the `ready` baseline: equal means no real edit, and the original `source` is kept.
struct MarkdownPreviewSync {
  let source: String
  private(set) var baseline: String?

  init(source: String) {
    self.source = source
  }

  /// Text to store for a message, or nil when the note text must not change.
  mutating func text(for message: MarkdownBridgeMessage) -> String? {
    switch message {
    case .ready(let markdown):
      baseline = markdown
      return nil
    case .changed(let markdown):
      return text(forSnapshot: markdown)
    case .openLink:
      return nil
    }
  }

  /// Text to store for a serialization fetched on demand (save flush); nil before `ready`.
  func text(forSnapshot markdown: String) -> String? {
    guard let baseline else { return nil }
    return markdown == baseline ? source : markdown
  }
}

/// Decides which preview links may be opened outside the app.
enum MarkdownLinkPolicy {
  /// Returns the URL only for http/https with a host or mailto with an address.
  static func externalURL(_ href: String) -> URL? {
    guard let url = URL(string: href), let scheme = url.scheme?.lowercased() else { return nil }
    switch scheme {
    case "http", "https":
      guard let host = url.host, !host.isEmpty else { return nil }
    case "mailto":
      guard !url.path.isEmpty else { return nil }
    default:
      return nil
    }
    return url
  }
}

/// Oxide tokens as `--dblore-*` CSS variables for the editor page.
enum MarkdownEditorTheme {
  /// Values are lowercase sRGB `#rrggbb`; alpha is dropped (all these tokens are opaque).
  static func variables(colorScheme: ColorScheme) -> [String: String] {
    let tokens: [String: Color] = [
      "--dblore-bg": .appBackground,
      "--dblore-fg": .foreground,
      "--dblore-fg-muted": .foregroundMuted,
      "--dblore-fg-subtle": .foregroundSubtle,
      "--dblore-border": .border,
      "--dblore-code-bg": .inputBackground,
      "--dblore-accent": .accent,
      "--dblore-accent-muted": .accentMuted,
    ]
    var environment = EnvironmentValues()
    environment.colorScheme = colorScheme
    return tokens.mapValues { hex($0.resolve(in: environment)) }
  }

  private static func hex(_ color: Color.Resolved) -> String {
    func byte(_ component: Float) -> Int { Int((min(max(component, 0), 1) * 255).rounded()) }
    return String(format: "#%02x%02x%02x", byte(color.red), byte(color.green), byte(color.blue))
  }
}
