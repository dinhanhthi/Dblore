// AIAssistantViewModel+SettingsTools.swift
// The app settings tools of a turn: list_settings and change_setting run here, never through
// the workspace's tool runner, and read no connection. A real change shows one entry with an
// Undo card; Undo writes the old value back only while the setting still holds the new one.

import Foundation

extension AIAssistantViewModel {
  /// What one settings call answers and shows
  private struct SettingsReply {
    var content: String
    var text: String
    var isError = false
    var change: AISettingChange? = nil

    static func error(_ error: AITools.ToolError, tool: String) -> SettingsReply {
      SettingsReply(
        content: AITools.errorContent(error), text: "Tool \(tool) failed: \(error.message)",
        isError: true)
    }
  }

  /// Runs one list_settings or change_setting call and shows it as one entry, saved with no
  /// session key. A real change gets a `settingChange` card; a no-op, a refusal or an invalid
  /// call is a plain tool entry. Nil once stopped or stale; a change applied before that still
  /// gets its entry while its conversation is open, so Undo stays reachable. In another
  /// conversation nothing is appended: the setting stays changed, revertible in Settings.
  func runSettingsTool(_ call: AIToolCall, token: Int) async -> AIToolResult? {
    guard !Task.isCancelled, token == generation else { return nil }
    let conversation = conversationId
    let reply: SettingsReply
    do {
      switch try AppSettingsTools.decode(call) {
      case .listSettings:
        reply = SettingsReply(
          content: AppSettingsTools.listText(settings: appSettings), text: "Ran tool \(call.name)")
      case .changeSetting(let change):
        reply = await changeSetting(change, tool: call.name)
      }
    } catch {
      reply = .error(error as? AITools.ToolError ?? .invalidArguments, tool: call.name)
    }
    let fresh = !Task.isCancelled && token == generation
    guard fresh || (reply.change != nil && conversationId == conversation) else { return nil }
    let result = AIToolResult(id: call.id, content: reply.content, isError: reply.isError)
    messages.append(
      AIChatEntry(
        id: UUID(), role: .assistant, text: reply.text, isError: false, toolCalls: [call],
        toolResults: [result], toolSessionKey: nil, settingChange: reply.change))
    saveConversation()
    return fresh ? result : nil
  }

  private func changeSetting(
    _ change: AppSettingsTools.Change, tool: String
  ) async -> SettingsReply {
    let outcome = await AppSettingsTools.apply(
      change, settings: appSettings, authorize: requestNotificationAuthorization)
    switch (outcome, AppSettingsTools.entry(change.key)) {
    case (.refused(let error), _):
      return .error(error, tool: tool)
    case (.applied(let old, let new), let entry?):
      let text = AIPrompts.settingChanged(
        title: entry.title, old: entry.display(old), new: entry.display(new))
      let shadowed = isSettingShadowed(entry.key)
      return SettingsReply(
        content: shadowed
          ? text + " A workspace setting overrides it, so the change may not show here."
          : text,
        text: text,
        change: AISettingChange(
          key: entry.key, oldValue: old, newValue: new, shadowed: shadowed, state: .applied))
    case (.noOp(.alreadySet), let entry?):
      let text =
        "\(entry.title) is already \(entry.display(entry.read(appSettings))) "
        + "(Settings > \(entry.tab)). Nothing changed."
      return SettingsReply(content: text, text: text)
    case (.noOp(.stayedOff), let entry?):
      return .error(
        AITools.ToolError(
          message: "\(entry.title) stayed off: notification permission was refused. Nothing "
            + "changed. The user allows notifications for Dblore in System Settings, then turns "
            + "it on in Settings > \(entry.tab)."), tool: tool)
    case (.applied, nil), (.noOp, nil):
      // `apply` refuses a key outside the catalog first
      return .error(
        AITools.ToolError(message: "That is not a setting you can change."), tool: tool)
    }
  }

  /// Undo on the card of entry `id`: the saved change (untrusted JSON) is validated again and
  /// the old value written back only while the setting still holds the new one. The card shows
  /// undone, changed since, or (a revert to notifications on refused permission) stays applied
  /// with `notificationsStayedOff`. An invalid change writes and shows nothing.
  func undoSettingChange(_ id: UUID) async {
    guard let change = messages.first(where: { $0.id == id })?.settingChange,
      change.state == .applied,
      AppSettingsTools.validateUndo(
        key: change.key, oldValue: change.oldValue, newValue: change.newValue)
    else { return }
    let outcome = await AppSettingsTools.undo(
      key: change.key, oldValue: change.oldValue, newValue: change.newValue,
      settings: appSettings, authorize: requestNotificationAuthorization)
    // The permission prompt can take a while: another Undo may have answered the card
    guard let index = messages.firstIndex(where: { $0.id == id }),
      messages[index].settingChange == change
    else { return }
    switch outcome {
    case .undone:
      messages[index].settingChange?.state = .undone
      messages[index].settingChange?.notificationsStayedOff = false
    case .changedSince:
      messages[index].settingChange?.state = .changedSince
    case .stayedOff:
      messages[index].settingChange?.notificationsStayedOff = true
    case .refused:
      return
    }
    saveConversation()
  }
}
