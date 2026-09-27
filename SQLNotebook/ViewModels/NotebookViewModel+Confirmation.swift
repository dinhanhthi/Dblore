//
//  NotebookViewModel+Confirmation.swift
//  SQLNotebook
//

import CryptoKit
import Foundation

// MARK: - Safe Mode Confirmation (classifier-driven)

extension NotebookViewModel {
  /// Shows the Safe Mode confirmation dialog for `query` if needed.
  /// Returns true if the dialog was shown (the caller must not run the query).
  func presentConfirmationIfNeeded(for query: String, cellId: UUID?) -> Bool {
    // Use per-connection SafeMode if set, otherwise fall back to global setting
    let safeMode = notebook.connectionConfig?.safeMode ?? AppSettings.shared.safeMode
    let classified = SQLStatementClassifier.classify(query)
    guard let statements = Self.statementsNeedingConfirmation(classified, safeMode: safeMode)
    else { return false }

    queryConfirmationState.pendingCellId = cellId
    queryConfirmationState.pendingQuery = query
    if queryConfirmationState.runAllAwaitingUnlock {
      queryConfirmationState.runAllAwaitingUnlock = false
      queryConfirmationState.clearRunAll()
    }
    // DELETE/UPDATE without WHERE clause anywhere in the cell (affects ALL rows)
    queryConfirmationState.affectsAllRows =
      SQLStatementClassifier.summary(classified).affectsAllRows
    queryConfirmationState.requiresPassword = safeMode.requiresPassword
    queryConfirmationState.statements = statements
    queryConfirmationState.showDialog = true
    return true
  }

  /// "Forgot Password?" fallback of the Safe Mode unlock: the database password unlocks only
  /// when no Safe Mode password exists, never when the stored or typed password is empty, and
  /// is compared in constant time (SHA-256 digests, so lengths do not leak either).
  nonisolated static func acceptsDatabasePasswordFallback(
    entry: String, storedPassword: String?, hasSafeModePassword: Bool
  ) -> Bool {
    guard !hasSafeModePassword, let storedPassword, !storedPassword.isEmpty, !entry.isEmpty
    else { return false }
    return SafeModePasswordRecord.constantTimeEquals(
      Data(SHA256.hash(data: Data(entry.utf8))), Data(SHA256.hash(data: Data(storedPassword.utf8))))
  }

  /// "Use database password" affordances are offered only while no Safe Mode password exists.
  nonisolated static func showsDatabasePasswordFallback(hasSafeModePassword: Bool) -> Bool {
    !hasSafeModePassword
  }

  /// Settings > Safe Mode credential check ("Change Password", "Authentication Required"):
  /// the database password path goes through `acceptsDatabasePasswordFallback`, the Safe Mode
  /// password path through `verifySafeModePassword`.
  nonisolated static func settingsAcceptsCredential(
    entry: String, usingDatabasePassword: Bool, storedDatabasePassword: String?,
    hasSafeModePassword: Bool, verifySafeModePassword: (String) -> Bool
  ) -> Bool {
    guard usingDatabasePassword else { return verifySafeModePassword(entry) }
    return acceptsDatabasePasswordFallback(
      entry: entry, storedPassword: storedDatabasePassword,
      hasSafeModePassword: hasSafeModePassword)
  }

  /// Statements to list in the confirmation dialog, or nil when no confirmation is needed.
  ///
  /// Every statement of the cell is checked, not only the first:
  /// - `alertRead` / `safeRead`: confirm when any statement modifies data or schema, runs a
  ///   utility (DO, CALL, COPY, ...) or an unrecognized statement (fail closed: these may write),
  ///   changes the session brakes, or changes role/privileges.
  /// - `alertAll` / `safeAll`: confirm every run and list every statement.
  /// - `silent`: no dialog, EXCEPT a statement that changes the session brakes
  ///   (`SET statement_timeout`, `RESET ALL`, ...) or role/privileges (`SET ROLE`, ...) always
  ///   needs confirmation, because it silently disables the app's safety net for the session.
  nonisolated static func statementsNeedingConfirmation(
    _ classified: [ClassifiedStatement], safeMode: SafeMode
  ) -> [StatementConfirmation]? {
    let all = classified.enumerated().map {
      makeConfirmation(index: $0.offset, statement: $0.element)
    }
    let listed: [StatementConfirmation]
    switch safeMode {
    case .alertAll, .safeAll:
      return all
    case .alertRead, .safeRead:
      listed = zip(classified, all).filter { mayWrite($0.0) }.map(\.1)
    case .silent:
      listed = all.filter { $0.touchesBrake || $0.changesPrivileges }
    }
    return listed.isEmpty ? nil : listed
  }

  /// True if the statement may change data, schema, session brakes or privileges.
  private nonisolated static func mayWrite(_ statement: ClassifiedStatement) -> Bool {
    switch SQLStatementClassifier.effectiveKind(statement.kind) {
    case .dml, .ddl, .utility, .unknown: return true
    default: return statement.resetsSessionBrakes || statement.changesPrivileges
    }
  }

  private nonisolated static func makeConfirmation(
    index: Int, statement: ClassifiedStatement
  ) -> StatementConfirmation {
    StatementConfirmation(
      index: index, preview: preview(statement.text),
      kindLabel: DatabaseConnectionManager.describe(statement.kind),
      affectsAllRows: statement.affectsAllRows, touchesBrake: statement.resetsSessionBrakes,
      changesPrivileges: statement.changesPrivileges)
  }

  /// First non-empty line of the statement after any leading comments, truncated to 80
  /// characters.
  private nonisolated static func preview(_ text: String) -> String {
    let line =
      withoutLeadingComments(text).split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .first { !$0.isEmpty } ?? ""
    return line.count > 80 ? String(line.prefix(79)) + "…" : line
  }

  /// `text` from its first token on (leading whitespace, `--` and `/* */` comments dropped);
  /// `text` unchanged if it holds only comments.
  private nonisolated static func withoutLeadingComments(_ text: String) -> String {
    let scalars = Array(text.unicodeScalars)
    var offset = 0
    while offset < scalars.count {
      let lexeme = SQLTokenizer.lexeme(in: scalars, at: offset)
      switch lexeme.kind {
      case .whitespace, .comment: offset = lexeme.range.upperBound
      default: return SQLTokenizer.text(scalars, offset..<scalars.count)
      }
    }
    return text
  }

  // MARK: - Dialog text

  /// Maximum number of statements listed in a confirmation dialog message
  nonisolated static let confirmationListLimit = 8

  /// Plain-text statement list for the Safe Mode dialog message, capped at `limit` statements.
  nonisolated static func confirmationSummary(
    _ statements: [StatementConfirmation], limit: Int = confirmationListLimit
  ) -> String {
    cappedList(statements.map { summaryLine($0, prefix: "") }, limit: limit)
  }

  /// Plain-text list of the Run All cells that need confirmation, capped at `limit` statements.
  nonisolated static func runAllSummary(
    _ cells: [RunAllCell], limit: Int = confirmationListLimit
  ) -> String {
    let lines = cells.flatMap { cell in
      cell.statements.map { summaryLine($0, prefix: "Cell \(cell.number), ") }
    }
    return cappedList(lines, limit: limit)
  }

  private nonisolated static func summaryLine(
    _ statement: StatementConfirmation, prefix: String
  ) -> String {
    let reasons = statement.reasons.map { "\n   ! \($0)" }.joined()
    return "\(prefix)\(statement.index + 1). \(statement.preview)\(reasons)"
  }

  private nonisolated static func cappedList(_ lines: [String], limit: Int) -> String {
    guard lines.count > limit else { return lines.joined(separator: "\n") }
    return (lines.prefix(limit) + ["…and \(lines.count - limit) more"]).joined(separator: "\n")
  }
}
