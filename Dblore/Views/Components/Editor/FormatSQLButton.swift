//
//  FormatSQLButton.swift
//  Dblore
//
//  Floating button that formats the SQL in the editor
//

import SwiftUI

// MARK: - Format SQL Button

/// Floating button that pretty-prints the editor's SQL.
struct FormatSQLButton: View {
  let textView: SQLTextView?
  @State private var isHovering = false

  var body: some View {
    Button(action: {
      textView?.formatDocument()
    }) {
      Image(systemName: "text.alignleft")
        .font(.system(size: 12))
    }
    .buttonStyle(FloatingPanelButtonStyle())
    .help("Format SQL")
    .opacity(isHovering ? 1.0 : 0.6)
    .onHover { hovering in
      isHovering = hovering
    }
  }
}
