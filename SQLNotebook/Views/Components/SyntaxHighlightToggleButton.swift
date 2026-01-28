//
//  SyntaxHighlightToggleButton.swift
//  SQLNotebook
//
//  Floating toggle button for syntax highlighting
//

import SwiftUI

// MARK: - Syntax Highlight Toggle Button

/// Floating toggle button for quickly enabling/disabling syntax highlighting.
/// Syncs with AppSettings.syntaxHighlightingEnabled.
struct SyntaxHighlightToggleButton: View {
  @Bindable private var appSettings = AppSettings.shared
  @State private var isHovering = false

  var body: some View {
    Button(action: {
      appSettings.syntaxHighlightingEnabled.toggle()
    }) {
      Image(systemName: appSettings.syntaxHighlightingEnabled ? "paintbrush.fill" : "paintbrush")
        .font(.system(size: 12))
        .contentTransition(.symbolEffect(.replace))
    }
    .buttonStyle(FloatingPanelButtonStyle())
    .help(
      appSettings.syntaxHighlightingEnabled
        ? "Disable syntax highlighting" : "Enable syntax highlighting"
    )
    .opacity(isHovering ? 1.0 : 0.6)
    .onHover { hovering in
      isHovering = hovering
    }
  }
}
