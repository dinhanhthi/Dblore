// RedisCommandRunner.swift
// Runs the Redis command tab's text: Run takes the selection, else the caret's line; Run All
// takes every command. The whole text to run is tokenized (`RedisTokenizer`) and each command
// classified (`RedisCommandClassifier`) and checked against the connection's rules before
// anything is sent: an editor refusal, a tokenize error or a blocked command sends nothing.
// Confirmation follows the connection's commit style as the MongoDB write models do: under
// Confirm / Password every command that is not a read asks first (the editor's `mayWrite` rule),
// and a destructive command always asks. The commands then go one by one through
// `executeGatedRedisCommand` in the workspace's db; the first error stops the rest. A reply is
// cut at 10,000 rows, Cancel stops the command in flight and the rest. History gets each sent
// command as `RedisTokenizer.render(args)`, never one that holds a password, never reply rows.

import Foundation
import Observation

/// The connection, rules and history sink of the command tab
struct RedisCommandContext {
  var manager: DatabaseConnectionManager
  /// Read at each run (and again when a confirmation is answered), so a write unlock or a
  /// protection change meanwhile counts
  var policy: @MainActor () -> ProtectionPolicy
  /// Read at run time, so a commit style changed meanwhile counts
  /// (`commitStyle(of:)` for a connection's config)
  var commitStyle: @MainActor () -> CommitStyle
  /// The workspace's db index, read at run time
  var database: @MainActor () -> Int
  /// The tab's caller token (another tab's pending transaction refuses the command)
  var caller: UUID?
  /// Records outcomes in History (the tab honours the History setting)
  var recordHistory: @MainActor ([QueryHistoryOutcome]) async -> Void

  /// The commit style the runner follows for `config`, as the MongoDB write models read it
  @MainActor static func commitStyle(of config: ConnectionConfig) -> CommitStyle {
    config.resolvedCommitStyle(fallback: AppSettings.shared.commitStyle)
  }
}

@MainActor
@Observable
final class RedisCommandRunner {
  /// The most reply rows kept for one command; the rest of a longer reply is cancelled
  nonisolated static let maxReplyRows = 10_000
  /// The banner over a reply cut at `maxReplyRows`
  nonisolated static let truncatedMessage = "The reply was cut at 10,000 rows."

  /// One command of the text to run, checked and classified
  nonisolated struct PlannedCommand: Sendable, Equatable {
    /// Its line in the editor, from 1
    let line: Int
    /// The exact bytes sent
    let args: [Data]
    /// `RedisCommandClassifier.redactedText`: what the confirmation and results show
    let text: String
    /// Not a read under Confirm / Password, or destructive
    let needsConfirmation: Bool
  }

  /// What the confirmation shows before anything is sent
  struct Confirmation: Equatable {
    /// One per request: a late answer meant for an earlier confirmation never sends a later one
    let id = UUID()
    /// Every command of the run, sent in order once confirmed
    let commands: [PlannedCommand]
    /// The db index they run in
    let database: Int
    /// Show `SafeModeConfirmationPanel` (Confirm / Password); else a plain confirmation
    let needsSafeModePanel: Bool
    let requiresPassword: Bool
    /// The connection the commands were checked on: a reconnect since refuses them
    fileprivate let connectionEpoch: UInt64

    /// The commands that asked for the confirmation
    var listed: [PlannedCommand] { commands.filter(\.needsConfirmation) }
  }

  nonisolated enum Outcome: Sendable, Equatable {
    case reply(RedisReply)
    /// The first `maxReplyRows` rows of a longer reply, flat (a cut reply is no tree), shown
    /// with `truncatedMessage`
    case truncated([RedisReplyDisplayRow])
    case failed(String)
    case cancelled
  }

  struct CommandResult: Identifiable, Equatable {
    let id = UUID()
    let line: Int
    /// The redacted command text
    let text: String
    let outcome: Outcome
    let elapsed: TimeInterval
  }

  /// Checking or sending commands
  private(set) var isRunning = false
  /// One per command sent, in order
  private(set) var results: [CommandResult] = []
  /// Waits for `confirm` or `cancelConfirmation`; nothing was sent
  private(set) var pendingConfirmation: Confirmation?
  /// Why nothing (or not everything) was sent: a refusal, a tokenize error, a stop
  private(set) var message: String?

  @ObservationIgnored private let context: RedisCommandContext
  /// Cancel was asked during this run: no further command is sent
  @ObservationIgnored private var cancelRequested = false
  /// The connection the running commands were checked on
  @ObservationIgnored private var runningEpoch: UInt64?

  init(context: RedisCommandContext) {
    self.context = context
  }

  /// Runs the selected text, or the caret's line when nothing is selected. `selection` is in
  /// UTF-16 offsets of `text` (the text view's range).
  func run(text: String, selection: NSRange) async {
    await start(text, selection: selection)
  }

  /// Runs every command of `text`
  func runAll(text: String) async {
    await start(text, selection: nil)
  }

  /// Sends `confirmation`'s commands while it is still the one asked. The Safe Mode panel
  /// (password / Touch ID) is verified by the view before this.
  func confirm(_ confirmation: Confirmation) async {
    guard !isRunning, pendingConfirmation?.id == confirmation.id else { return }
    pendingConfirmation = nil
    cancelRequested = false
    await send(
      confirmation.commands, db: confirmation.database, epoch: confirmation.connectionEpoch,
      policy: context.policy(), confirmed: true)
  }

  /// Leaves the confirmation without sending anything
  func cancelConfirmation() {
    pendingConfirmation = nil
  }

  /// Stops the command in flight (`cancelRunningStatement`); no later command is sent
  func cancel() async {
    guard isRunning else { return }
    // Set first: a cancel between two commands finds nothing in flight
    cancelRequested = true
    guard let epoch = runningEpoch else { return }
    let manager = context.manager
    let status = await manager.runningStatementStatus()
    guard status.inFlight else { return }
    _ = await manager.cancelRunningStatement(
      expectedGeneration: status.generation, expectedUserTxOpen: status.userTxOpen,
      expectedEpoch: epoch)
  }

  // MARK: - Private

  private nonisolated enum Prepared: Sendable {
    case commands([PlannedCommand])
    case refused(String)
  }

  private func start(_ text: String, selection: NSRange?) async {
    guard !isRunning else { return }
    isRunning = true
    cancelRequested = false
    pendingConfirmation = nil
    results = []
    message = nil
    let style = context.commitStyle()
    let db = context.database()
    let manager = context.manager
    let basePolicy = context.policy()
    let epoch = await manager.connectionEpoch
    let policy = await manager.effectivePolicy(for: basePolicy)
    let prepared = await Self.prepare(text, selection: selection, policy: policy, style: style)
    let commands: [PlannedCommand]
    switch prepared {
    case .refused(let reason):
      message = reason
      isRunning = false
      return
    case .commands(let planned):
      commands = planned
    }
    guard !cancelRequested else {
      message = "Cancelled; nothing was sent."
      isRunning = false
      return
    }
    if commands.contains(where: \.needsConfirmation) {
      pendingConfirmation = Confirmation(
        commands: commands, database: db, needsSafeModePanel: style != .immediate,
        requiresPassword: style.requiresPassword, connectionEpoch: epoch)
      isRunning = false
      return
    }
    await send(commands, db: db, epoch: epoch, policy: basePolicy, confirmed: false)
  }

  /// Sends `commands` one by one; stops at the first error or a Cancel
  private func send(
    _ commands: [PlannedCommand], db: Int, epoch: UInt64, policy: ProtectionPolicy,
    confirmed: Bool
  ) async {
    isRunning = true
    runningEpoch = epoch
    defer {
      isRunning = false
      runningEpoch = nil
    }
    for (index, planned) in commands.enumerated() {
      let unsent = commands.count - index
      guard !cancelRequested else {
        message = "Cancelled; \(Self.commandCount(unsent)) not sent."
        return
      }
      let started = Date()
      let outcome: Outcome
      do {
        let result = try await context.manager.executeGatedRedisCommand(
          RedisCommand(args: planned.args, db: db), policy: policy,
          connectionEpoch: epoch, caller: context.caller, userInitiated: true,
          confirmed: confirmed, truncatingAt: Self.maxReplyRows)
        outcome = await Self.outcome(of: result)
      } catch DatabaseError.queryCancelled {
        outcome = .cancelled
      } catch {
        outcome = .failed(error.localizedDescription)
      }
      let elapsed = Date().timeIntervalSince(started)
      results.append(
        CommandResult(line: planned.line, text: planned.text, outcome: outcome, elapsed: elapsed))
      await record(planned.args, outcome: outcome, elapsed: elapsed)
      switch outcome {
      case .reply, .truncated: continue
      case .failed, .cancelled:
        if unsent > 1 { message = "\(Self.commandCount(unsent - 1)) after it not sent." }
        return
      }
    }
    if cancelRequested { message = "Cancelled after the last command." }
  }

  /// One History row for a sent command, unless it holds a password
  private func record(_ args: [Data], outcome: Outcome, elapsed: TimeInterval) async {
    guard !RedisCommandClassifier.containsSecret(args) else { return }
    let status: QueryHistoryEntry.Status
    var errorMessage: String?
    switch outcome {
    case .reply, .truncated: status = .success
    case .cancelled: status = .cancelled
    case .failed(let reason):
      status = .error
      errorMessage = reason
    }
    await context.recordHistory([
      QueryHistoryOutcome(
        sql: RedisTokenizer.render(args), duration: elapsed, rowCount: nil, status: status,
        errorMessage: errorMessage)
    ])
  }

  /// `text` ending with a period
  private nonisolated static func sentence(_ text: String) -> String {
    text.hasSuffix(".") ? text : text + "."
  }

  private nonisolated static func commandCount(_ count: Int) -> String {
    count == 1 ? "1 command" : "\(count) commands"
  }

  /// The commands of `text` (of the selection, else the caret's line), checked off the main
  /// actor: any tokenize error, editor refusal or command `policy` blocks refuses them all
  @concurrent private nonisolated static func prepare(
    _ text: String, selection: NSRange?, policy: ProtectionPolicy, style: CommitStyle
  ) async -> Prepared {
    let (piece, firstLine) = selection.map { target(in: text, selection: $0) } ?? (text, 1)
    // Lines end at LF only, as `RedisTokenizer` splits them (a CR is whitespace)
    let lines = piece.utf8.split(separator: 0x0A, omittingEmptySubsequences: false)
    var commands: [PlannedCommand] = []
    for (offset, bytes) in lines.enumerated() {
      let line = firstLine + offset
      let tokenized: [[Data]]
      do {
        tokenized = try RedisTokenizer.tokenize(String(decoding: bytes, as: UTF8.self))
      } catch {
        let error = onLine(error, line)
        return .refused("\(error.localizedDescription) Nothing was sent.")
      }
      for args in tokenized {
        let classification = RedisCommandClassifier.classify(args)
        let statement = classification.statement
        if let refusal = classification.refusal {
          return .refused("Line \(line): \(sentence(refusal)) Nothing was sent.")
        }
        if case .blocked(_, _, let reason) = DatabaseConnectionManager.evaluate(
          [statement], policy: policy, dialect: .redis)
        {
          return .refused("Line \(line): \(sentence(reason)) Nothing was sent.")
        }
        commands.append(
          PlannedCommand(
            line: line, args: args, text: statement.text,
            needsConfirmation: statement.isDestructive
              || (style != .immediate && statement.kind != .read)))
      }
    }
    guard !commands.isEmpty else { return .refused("There is no command to run.") }
    return .commands(commands)
  }

  /// The selected text, else the caret's line, and the editor line it starts on
  private nonisolated static func target(
    in text: String, selection: NSRange
  ) -> (String, Int) {
    let units = Array(text.utf16)
    let lineFeed = UInt16(0x0A)
    let location = min(max(selection.location, 0), units.count)
    let start: Int
    let end: Int
    if selection.length > 0 {
      start = location
      end = min(location + selection.length, units.count)
    } else {
      start = units[..<location].lastIndex(of: lineFeed).map { $0 + 1 } ?? 0
      end = units[location...].firstIndex(of: lineFeed) ?? units.count
    }
    let firstLine = units[..<start].count(where: { $0 == lineFeed }) + 1
    return (String(decoding: units[start..<end], as: UTF16.self), firstLine)
  }

  /// `error` with its line counted in the editor
  private nonisolated static func onLine(
    _ error: RedisTokenizer.TokenizeError, _ line: Int
  ) -> RedisTokenizer.TokenizeError {
    switch error {
    case .unterminatedQuote: .unterminatedQuote(line: line)
    case .quoteNotFollowedBySpace: .quoteNotFollowedBySpace(line: line)
    case .invalidHexEscape: .invalidHexEscape(line: line)
    }
  }

  /// The reply of `result`, decoded off the main actor; a cut reply as flat rows
  @concurrent private nonisolated static func outcome(of result: QueryResult) async -> Outcome {
    do {
      guard result.truncated else { return .reply(try RedisReply(rows: result.rows)) }
      return .truncated(try flatRows(result.rows))
    } catch {
      return .failed(error.localizedDescription)
    }
  }

  /// One display row per reply row, without rebuilding the (cut) tree: an aggregate shows the
  /// child count the server announced, a leaf its value as the Grid shows it
  private nonisolated static func flatRows(
    _ rows: [[CellValue]]
  ) throws -> [RedisReplyDisplayRow] {
    var mapPaths = Set<String>()
    return try rows.enumerated().map { index, row in
      guard row.count == 3, case .string(let path) = row[0], case .string(let type) = row[1]
      else {
        throw RedisReplyDecodingError(message: "row \(index + 1) is not a path, type and value")
      }
      let parts = path.split(separator: ".")
      let parent = parts.dropLast().joined(separator: ".")
      let role: RedisReplyDisplayRow.Role? =
        mapPaths.contains(parent)
        ? (Int(parts.last ?? "").map { $0 % 2 == 0 } == true ? .key : .value) : nil
      let value: String
      switch (type, row[2]) {
      case ("map", .int(let count)):
        mapPaths.insert(path)
        value = count == 2 ? "1 pair" : "\(count / 2) pairs"
      case ("array", .int(let count)), ("set", .int(let count)), ("push", .int(let count)):
        value = count == 1 ? "1 item" : "\(count) items"
      default:
        // A leaf alone is a whole reply: its Grid value, escaped and cut as everywhere
        let leaf = try RedisReply(rows: [[.string("0"), .string(type), row[2]]])
        value = leaf.displayRows().first?.value ?? ""
      }
      return RedisReplyDisplayRow(
        path: path, depth: parts.count - 1, role: role, type: type, value: value)
    }
  }
}
