//
//  SQLCodeWell.swift
//  Dblore
//
//  Read-only SQL well shared by modals. Own input surface, syntax highlight,
//  and the word-wrap / syntax-highlight toggles at the bottom right.
//

import SwiftUI

/// SQL sits on `inputBackground`. Word wrap is local to this well and does not
/// write the editor setting. Syntax highlight follows `AppSettings`.
struct SQLCodeWell: View {
  let sql: String
  var placeholder: String?
  var dialect: SQLDialect = .postgresql

  @Bindable private var appSettings = AppSettings.shared
  @State private var wordWrapEnabled: Bool

  init(sql: String, placeholder: String? = nil, dialect: SQLDialect = .postgresql) {
    self.sql = sql
    self.placeholder = placeholder
    self.dialect = dialect
    self._wordWrapEnabled = State(initialValue: AppSettings.shared.wordWrapEnabled)
  }

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      sqlScroll
        .frame(maxWidth: .infinity, maxHeight: .infinity)

      HStack(spacing: Spacing.xs) {
        WordWrapToggleButton(isEnabled: $wordWrapEnabled)
        SyntaxHighlightToggleButton()
      }
      .padding(.trailing, Spacing.sm)
      .padding(.bottom, Spacing.sm)
    }
    .background(Color.inputBackground)
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
  }

  private var showsPlaceholder: Bool {
    sql.isEmpty && placeholder != nil
  }

  @ViewBuilder
  private var sqlScroll: some View {
    if wordWrapEnabled {
      ScrollView(.vertical, showsIndicators: true) {
        sqlText
          .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    } else {
      // Horizontal outside so the bottom scrollbar stays visible. Matches the
      // executed-query sidebar, which avoids a centered single-axis ScrollView.
      ScrollView(.horizontal, showsIndicators: true) {
        ScrollView(.vertical, showsIndicators: true) {
          sqlText
        }
      }
    }
  }

  private var sqlText: some View {
    Group {
      if showsPlaceholder {
        Text(placeholder ?? "")
          .foregroundColor(.foregroundMuted)
      } else {
        Text(highlightedSQL)
      }
    }
    .font(.system(size: 13, design: .monospaced))
    .textSelection(.enabled)
    .fixedSize(horizontal: !wordWrapEnabled, vertical: true)
    .padding(Spacing.md)
    // Clears the floating toggles so the last line can scroll above them.
    .padding(.bottom, 26)
    .id(appSettings.syntaxHighlightingEnabled)
  }

  private var highlightedSQL: AttributedString {
    AttributedString(SQLSyntaxHighlighter.highlight(sql, dialect: dialect))
  }
}

/// Same chrome as `SyntaxHighlightToggleButton`. Toggles the bound flag only.
struct WordWrapToggleButton: View {
  @Binding var isEnabled: Bool
  @State private var isHovering = false

  var body: some View {
    Button {
      isEnabled.toggle()
    } label: {
      Image(systemName: isEnabled ? "text.alignleft" : "text.word.spacing")
        .font(.system(size: 12))
        .contentTransition(.symbolEffect(.replace))
    }
    .buttonStyle(FloatingPanelButtonStyle())
    .help(isEnabled ? "Disable Word Wrap" : "Enable Word Wrap")
    .opacity(isHovering ? 1.0 : 0.6)
    .onHover { hovering in
      isHovering = hovering
    }
  }
}
