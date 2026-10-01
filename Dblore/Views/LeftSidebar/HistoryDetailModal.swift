//
//  HistoryDetailModal.swift
//  Dblore
//
//  Small modal with the full recorded SQL, and Copy / Cancel.
//  The SQL sits on its own input background, with the editor's word wrap
//  and syntax highlight toggles.
//

import SwiftUI

struct HistoryDetailModal: View {
  let sql: String
  @Binding var isPresented: Bool
  let onCopy: () -> Void

  @Bindable private var appSettings = AppSettings.shared
  @State private var copied = false
  /// Local to this viewer. Starts from the editor setting and does not write it back.
  @State private var wordWrapEnabled: Bool

  init(sql: String, isPresented: Binding<Bool>, onCopy: @escaping () -> Void) {
    self.sql = sql
    self._isPresented = isPresented
    self.onCopy = onCopy
    self._wordWrapEnabled = State(initialValue: AppSettings.shared.wordWrapEnabled)
  }

  var body: some View {
    VStack(spacing: 0) {
      codeArea
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Spacing.md)

      GenericModalFooter {
        Spacer()
        Button(copied ? "Copied" : "Copy", action: copy)
          .buttonStyle(PrimaryButtonStyle())
        Button("Cancel") { isPresented = false }
          .buttonStyle(SecondaryButtonStyle())
          .keyboardShortcut(.cancelAction)
      }
    }
    .frame(width: 440, height: 260)
    .background(Color.cardBackground)
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.xxl))
    .overlay(
      RoundedRectangle(cornerRadius: CornerRadius.xxl)
        .stroke(Color.border.opacity(0.5), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.25), radius: 24, x: 0, y: 8)
    .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)
  }

  /// SQL well. `inputBackground` is the editor surface; the modal stays `cardBackground`.
  private var codeArea: some View {
    ZStack(alignment: .bottomTrailing) {
      sqlScroll
        .frame(maxWidth: .infinity, maxHeight: .infinity)

      HStack(spacing: Spacing.xs) {
        HistoryWordWrapButton(isEnabled: $wordWrapEnabled)
        SyntaxHighlightToggleButton()
      }
      .padding(.trailing, Spacing.sm)
      .padding(.bottom, Spacing.sm)
    }
    .background(Color.inputBackground)
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
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
    Text(highlightedSQL)
      .font(.system(size: 13, design: .monospaced))
      .textSelection(.enabled)
      .fixedSize(horizontal: !wordWrapEnabled, vertical: true)
      .padding(Spacing.md)
      // Clears the floating toggles so the last line can scroll above them.
      .padding(.bottom, 26)
      .id(appSettings.syntaxHighlightingEnabled)
  }

  private var highlightedSQL: AttributedString {
    AttributedString(SQLSyntaxHighlighter.highlight(sql))
  }

  private func copy() {
    onCopy()
    copied = true
    Task {
      try? await Task.sleep(for: .seconds(1.5))
      copied = false
    }
  }
}

/// Same chrome as `SyntaxHighlightToggleButton`. Does not change the editor setting.
private struct HistoryWordWrapButton: View {
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

extension View {
  /// Presents the history detail modal driven by `workspaceManager.historyDetail`.
  func historyDetailModal(workspaceManager: WorkspaceManager) -> some View {
    let isPresented = Binding(
      get: { workspaceManager.historyDetail != nil },
      set: { if !$0 { workspaceManager.historyDetail = nil } }
    )
    return modalOverlay(isPresented: isPresented) {
      if let entry = workspaceManager.historyDetail {
        HistoryDetailModal(
          sql: entry.sql,
          isPresented: isPresented,
          onCopy: { workspaceManager.copyHistory(entry) }
        )
        .id(entry.id)
      }
    }
  }
}
