// AIAssistantViewModel+SlashCommands.swift
// Runs the slash command the draft starts with: a built-in calls its existing flow, a custom
// command is expanded locally into the draft. Like Explain and Fix nothing is sent: the user
// reads the draft and presses Send, where the hold rules of connection text apply.

import Foundation

extension AIAssistantViewModel {
  enum SlashOutcome: Equatable {
    /// The draft does not start with a command name: nothing changed
    case notACommand
    /// No built-in or custom command has this name: nothing changed
    case unknown(String)
    /// The built-in cannot run for this tab (no SQL, no error, or not offered on this
    /// connection): nothing changed
    case unavailable(AISlashCommand.BuiltIn)
    /// The draft was filled. `withheld`: the template's placeholders were left empty because the
    /// gate denies the connection.
    case filled(withheld: Bool)
    /// The template reads the connection, which is not yet allowed this session: the Allow
    /// prompt shows (`pendingApproval`) and Allow runs the command again. Nothing changed.
    case awaitingApproval
  }

  /// Runs the command the draft starts with, for the active tab. Text after the command name is
  /// kept below the filled prompt.
  @discardableResult
  func runSlashCommand(in tab: NotebookViewModel?) -> SlashOutcome {
    guard let invocation = AISlashCommand.parse(draft) else { return .notACommand }
    let custom = settings.configuration.customCommands
    switch AISlashCommand.resolve(invocation.name, custom: custom) {
    case nil:
      return .unknown(invocation.name)
    case .builtIn(let builtIn):
      return runBuiltIn(builtIn, argument: invocation.argument, tab: tab)
    case .custom(let command):
      return runCustom(command, argument: invocation.argument, tab: tab)
    }
  }

  /// The quick actions' conditions: Explain needs SQL, Fix SQL and its error, Review and
  /// Optimize `offersReview` (never MongoDB)
  private func runBuiltIn(
    _ builtIn: AISlashCommand.BuiltIn, argument: String, tab: NotebookViewModel?
  ) -> SlashOutcome {
    guard let tab, let sql = tab.aiCurrentSQL else { return .unavailable(builtIn) }
    let error = tab.aiLastError
    let offersReview = Self.offersReview(in: tab, dialect: sqlDialect)
    switch builtIn {
    case .fix where error == nil, .review where !offersReview, .optimize where !offersReview:
      return .unavailable(builtIn)
    default: break
    }
    // The command text never goes to the model
    draft = ""
    switch builtIn {
    case .explain: explain(sql: sql, sessionKey: tab.aiSessionKey)
    case .fix: fixError(sql: sql, error: error ?? "", sessionKey: tab.aiSessionKey)
    case .review: review(.review, in: tab)
    case .optimize: review(.optimize, in: tab)
    }
    if !argument.isEmpty { draft += "\n\n" + argument }
    return .filled(withheld: false)
  }

  /// Placeholders are read only when the gate allows the connection; one not yet allowed this
  /// session asks first. A draft that took a value is connection text, stamped with the tab's
  /// session key (the workspace's for schema alone); a draft without one is the user's own text.
  private func runCustom(
    _ command: AICustomCommand, argument: String, tab: NotebookViewModel?
  ) -> SlashOutcome {
    let used = AISlashCommand.placeholders(in: command.template)
    let check: AccessCheck
    if used.isEmpty {
      check = aiAccessCheck()
    } else {
      guard
        let admitted = admitTurn(resume: { [weak self, weak tab] in
          self?.runSlashCommand(in: tab)
        })
      else { return .awaitingApproval }
      check = admitted
    }
    let allowed = check.decision == .allowed
    let values =
      allowed
      ? slashValues(for: used, tab: tab, question: command.template + " " + argument)
      : AISlashCommand.Values()
    var text = AISlashCommand.expand(template: command.template, values: values)
    if !argument.isEmpty { text += "\n\n" + argument }

    draft = ""
    let tabValues: Set<AISlashCommand.Placeholder> = [.query, .selection, .error]
    let filled = used.filter { !(values[$0] ?? "").isEmpty }
    if filled.isEmpty {
      draft = text
    } else {
      let workspaceKey = check.context.map { AIAccessGate.sessionKey(for: $0.config) }
      fillDraft(
        text, sessionKey: filled.isDisjoint(with: tabValues) ? workspaceKey : tab?.aiSessionKey)
    }
    return .filled(withheld: !allowed && !used.isEmpty)
  }

  /// The values of the placeholders in `used`. Query and selection come from `aiCurrentSQL`
  /// (nil on a read-only source or Markdown tab; the mongosh text on MongoDB); the selection only
  /// when the editor has one. The schema is the structure of the tables the picker or the
  /// question selects (sampled fields on MongoDB). Gate-unaware: call it only once
  /// `aiAccessCheck()` allows the connection.
  private func slashValues(
    for used: Set<AISlashCommand.Placeholder>, tab: NotebookViewModel?, question: String
  ) -> AISlashCommand.Values {
    var values = AISlashCommand.Values()
    let sql = tab?.aiCurrentSQL
    if used.contains(.query) { values.query = sql }
    if used.contains(.selection), tab?.aiCurrentSelection != nil { values.selection = sql }
    if used.contains(.error) { values.error = tab?.aiLastError }
    if used.contains(.schema) {
      let snapshot = schemaSource()
      let tables = AISchemaContext.selectTables(
        explicit: selectedTableNames, question: question + " " + (sql ?? ""),
        tables: snapshot.tables, foreignKeys: snapshot.foreignKeys)
      values.schema = AISchemaContext.render(
        tables: tables, foreignKeys: snapshot.foreignKeys,
        budgetChars: AISlashCommand.maxValueChars)
    }
    return values
  }
}
