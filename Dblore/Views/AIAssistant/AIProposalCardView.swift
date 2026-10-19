//
//  AIProposalCardView.swift
//  Dblore
//
//  A statement the model proposed (propose_sql): its reason, the exact SQL or mongosh command,
//  the kind the app reads from it, the MongoDB database it targets, and Copy / Insert / Run.
//  Run only collects the typed name of a destructive statement and asks the workspace; nothing
//  here runs by itself. Text with invisible format characters shows why it cannot run.
//

import AppKit
import SwiftUI

struct AIProposalCardView: View {
  let proposal: AIProposal
  /// Dialect of the connection, to classify the text
  let dialect: SQLDialect
  /// Places the text in the active tab (a new cell in a notebook; never runs); nil disables it
  let onInsert: ((String) -> Void)?
  /// Runs the proposal with the typed name (`WorkspaceManager.runAIProposal`); nil disables Run
  let onRun: ((AIProposal, String?) -> WorkspaceManager.AIProposalRunOutcome)?

  @State private var typedName = ""
  @State private var status: (text: String, isError: Bool)?
  @State private var copied = false
  @State private var cache = CheckCache()

  var body: some View {
    let check = cache.read(proposal, dialect: dialect)
    VStack(alignment: .leading, spacing: 0) {
      header(check)
      Rectangle().fill(Color.border).frame(height: 1)
      VStack(alignment: .leading, spacing: Spacing.sm) {
        if !proposal.reason.isEmpty {
          Text(verbatim: String(proposal.reason.prefix(AITools.maxReasonCharacters)))
            .font(.labelText)
            .foregroundColor(.foreground)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
        if dialect == .mongodb, let database = proposal.database {
          // Run refuses any other database
          Text(verbatim: "Database: \(WorkspaceManager.aiProposalMongoDatabase(database))")
            .font(.small)
            .foregroundColor(.foregroundMuted)
            .textSelection(.enabled)
        }
        code
        if check.kind == .destructive, let name = check.confirmName, check.runRefusal == nil {
          confirmation(name)
        }
        if let refusal = check.runRefusal {
          note(refusal, isError: true)
        } else if let status {
          note(status.text, isError: status.isError)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(Spacing.sm)
      .background(Color.cellBackground)
    }
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
    .overlay(HairlineBorder(shape: RoundedRectangle(cornerRadius: CornerRadius.md)))
  }

  /// Title and buttons on the first row, the badges on their own row: the AI panel is narrow
  private func header(_ check: AIProposalCheck) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      HStack(spacing: Spacing.xs) {
        Text("Proposal")
          .font(.small)
          .foregroundColor(.foregroundMuted)
          .lineLimit(1)
        Spacer(minLength: 0)
        Button(copied ? "Copied" : "Copy") { copy() }
          .buttonStyle(AICodeActionButtonStyle())
        Button("Insert") { onInsert?(proposal.sql) }
          .buttonStyle(AICodeActionButtonStyle())
          .disabled(onInsert == nil)
          .help(onInsert == nil ? "No active tab" : "Insert into the active tab (does not run)")
        Button("Run") { run(check) }
          .buttonStyle(AICodeActionButtonStyle())
          .disabled(!canRun(check))
          .help(
            onRun == nil
              ? "Not connected"
              : "Run in the active query tab, with the same checks as typed SQL")
      }
      HStack(spacing: Spacing.xs) {
        badge(check.kind.label, color: color(check.kind))
        if check.affectsAllRows, check.kind != .destructive {
          badge("All rows", color: .warning)
        }
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.xs)
    .background(Color.cardHeaderBackground)
  }

  /// The exact text; a saved one longer than the cap shows its start only (it cannot run)
  private var code: some View {
    let text =
      proposal.sql.count > AITools.maxSQLCharacters
      ? String(proposal.sql.prefix(AITools.maxSQLCharacters)) + "…" : proposal.sql
    return ScrollView(.horizontal, showsIndicators: false) {
      Text(verbatim: text)
        .font(.monoMedium)
        .foregroundColor(.foreground)
        .textSelection(.enabled)
        .padding(Spacing.sm)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.cardBackground)
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm))
    .overlay(HairlineBorder(shape: RoundedRectangle(cornerRadius: CornerRadius.sm)))
  }

  private func note(_ text: String, isError: Bool) -> some View {
    Text(verbatim: text)
      .font(.small)
      .foregroundColor(isError ? .destructive : .foregroundMuted)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func confirmation(_ name: String) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text("This cannot be undone. Type the name to run it:")
        .font(.small)
        .foregroundColor(.destructive)
      Text(verbatim: name)
        .font(.monoSmall)
        .foregroundColor(.foreground)
        .textSelection(.enabled)
      TextField("Name", text: $typedName)
        .font(.monoSmall)
        .textFieldStyle(.plain)
        .autocorrectionDisabled()
        .inputCapsuleStyle()
    }
  }

  private func canRun(_ check: AIProposalCheck) -> Bool {
    guard onRun != nil, check.runRefusal == nil else { return false }
    guard check.kind == .destructive else { return true }
    return check.confirmName.map { TypedNameConfirmation.matches(typedName, name: $0) } ?? false
  }

  private func run(_ check: AIProposalCheck) {
    guard let onRun, canRun(check) else { return }
    let name = check.kind == .destructive ? typedName : nil
    // Every run asks again: the typed name is not kept
    typedName = ""
    switch onRun(proposal, name) {
    case .ran: status = ("Sent to the active tab.", false)
    case .openedTab: status = ("Opened a new query tab to run it.", false)
    case .refused(let reason): status = (reason, true)
    }
  }

  private func badge(_ label: String, color: Color) -> some View {
    Text(label)
      .font(.smallest)
      .foregroundColor(color)
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xxs)
      .background(color.opacity(0.14))
      .clipShape(Capsule())
  }

  private func color(_ kind: AIProposalCheck.Kind) -> Color {
    switch kind {
    case .read: .success
    case .write, .schema: .warning
    case .destructive: .destructive
    }
  }

  private func copy() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(proposal.sql, forType: .string)
    copied = true
    Task {
      try? await Task.sleep(for: .seconds(1.5))
      copied = false
    }
  }
}

/// The check of the shown proposal, kept across re-renders (the panel redraws on every streamed
/// token of a later answer) and redone only when the text or the dialect changes
private final class CheckCache {
  private var key: (sql: String, dialect: SQLDialect, database: String?)?
  private var value = AIProposalCheck(
    kind: .write, affectsAllRows: false, confirmName: nil, runRefusal: nil)

  func read(_ proposal: AIProposal, dialect: SQLDialect) -> AIProposalCheck {
    if let key, key.sql == proposal.sql, key.dialect == dialect, key.database == proposal.database {
      return value
    }
    // Blank names the session's default database, as the card's "Database:" line shows
    value = AIProposalCheck.make(
      sql: proposal.sql, dialect: dialect,
      database: proposal.database.map(WorkspaceManager.aiProposalMongoDatabase))
    key = (proposal.sql, dialect, proposal.database)
    return value
  }
}

#Preview("AIProposalCardView") {
  VStack(spacing: Spacing.md) {
    AIProposalCardView(
      proposal: AIProposal(
        sql: "DELETE FROM sessions WHERE expires_at < now()", reason: "Removes expired sessions"),
      dialect: .postgresql, onInsert: { _ in }, onRun: { _, _ in .ran(tabID: UUID()) })
    AIProposalCardView(
      proposal: AIProposal(sql: "DROP TABLE staging_orders", reason: "The table is unused"),
      dialect: .postgresql, onInsert: nil, onRun: { _, _ in .refused("Not connected") })
    AIProposalCardView(
      proposal: AIProposal(sql: "db.logs.deleteMany({})", reason: "Clears the log collection"),
      dialect: .mongodb, onInsert: { _ in }, onRun: nil)
  }
  .padding(Spacing.md)
  .frame(width: ComponentSize.sidebarWidth)
  .background(Color.appBackground)
}
