//
//  AISettingChangeCardView.swift
//  Dblore
//
//  A Dblore setting the AI changed (change_setting): its title and Settings tab, the old and
//  new values, and Undo. Saved chats are plain JSON, so the title, tab and value names come
//  from the catalog by key, and a saved change the catalog does not accept shows plain text.
//

import SwiftUI

struct AISettingChangeCardView: View {
  let change: AISettingChange
  /// Reverts the change (`AIAssistantViewModel.undoSettingChange`); nil disables Undo
  let onUndo: (@MainActor () async -> Void)?

  /// Set on the Undo click, so a second click while it runs (the notification permission
  /// prompt) cannot undo twice; cleared when the undo returns, also when it was refused
  @State private var isUndoing = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Rectangle().fill(Color.border).frame(height: 1)
      VStack(alignment: .leading, spacing: Spacing.sm) {
        if let entry = checkedEntry {
          details(entry)
        } else {
          Text("A setting was changed.")
            .font(.labelText)
            .foregroundColor(.foreground)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(Spacing.sm)
      .background(Color.cellBackground)
    }
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
    .overlay(HairlineBorder(shape: RoundedRectangle(cornerRadius: CornerRadius.md)))
  }

  /// The catalog entry when the saved key and both values are valid for it, else nil
  private var checkedEntry: AppSettingsTools.Entry? {
    guard
      AppSettingsTools.validateUndo(
        key: change.key, oldValue: change.oldValue, newValue: change.newValue)
    else { return nil }
    return AppSettingsTools.entry(change.key)
  }

  private var header: some View {
    Text("Setting")
      .font(.small)
      .foregroundColor(.foregroundMuted)
      .lineLimit(1)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xs)
      .background(Color.cardHeaderBackground)
  }

  @ViewBuilder
  private func details(_ entry: AppSettingsTools.Entry) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xxs) {
      Text(verbatim: entry.title)
        .font(.labelText)
        .foregroundColor(.foreground)
      Text(verbatim: "Settings > \(entry.tab)")
        .font(.small)
        .foregroundColor(.foregroundMuted)
    }
    Text(verbatim: "\(entry.display(change.oldValue)) → \(entry.display(change.newValue))")
      .font(.labelText)
      .foregroundColor(.foreground)
      .fixedSize(horizontal: false, vertical: true)
    if change.shadowed {
      note("A workspace setting overrides this here.")
    }
    state(entry)
  }

  @ViewBuilder
  private func state(_ entry: AppSettingsTools.Entry) -> some View {
    switch change.state {
    case .applied:
      HStack(spacing: Spacing.sm) {
        Button("Undo") {
          guard let onUndo else { return }
          isUndoing = true
          Task {
            await onUndo()
            isUndoing = false
          }
        }
        .buttonStyle(SecondaryButtonStyle())
        .controlSize(.small)
        .disabled(isUndoing || onUndo == nil)
        .accessibilityLabel("Undo the \(entry.title) change")
        .help("Set \(entry.title) back to \(entry.display(change.oldValue))")
        if change.notificationsStayedOff {
          note("Notifications stayed off")
        }
      }
    case .undone:
      note("Undone")
    case .changedSince:
      note("Changed since; not undone")
    }
  }

  private func note(_ text: String) -> some View {
    Text(verbatim: text)
      .font(.small)
      .foregroundColor(.foregroundMuted)
      .fixedSize(horizontal: false, vertical: true)
  }
}

#Preview("AISettingChangeCardView") {
  VStack(spacing: Spacing.md) {
    AISettingChangeCardView(
      change: AISettingChange(
        key: "themePreference", oldValue: "Dark", newValue: "Light", shadowed: false,
        state: .applied),
      onUndo: {})
    AISettingChangeCardView(
      change: AISettingChange(
        key: "notifyLongQueries", oldValue: "true", newValue: "false", shadowed: false,
        notificationsStayedOff: true, state: .applied),
      onUndo: {})
    AISettingChangeCardView(
      change: AISettingChange(
        key: "showLineNumbers", oldValue: "true", newValue: "false", shadowed: false,
        state: .undone),
      onUndo: {})
    AISettingChangeCardView(
      change: AISettingChange(
        key: "wordWrapEnabled", oldValue: "false", newValue: "true", shadowed: true,
        state: .changedSince),
      onUndo: {})
  }
  .padding(Spacing.md)
  .frame(width: ComponentSize.sidebarWidth)
  .background(Color.appBackground)
}
