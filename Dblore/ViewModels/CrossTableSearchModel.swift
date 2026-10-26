// CrossTableSearchModel.swift
// Find a Value in Every Table: the sheet's state and the search. Tables are searched one at a
// time (at most `maxTables`), each with one `CrossTableSearchQueryBuilder` SELECT that passed
// `ReadOnlyQueryGuard` and is sent through the gate under a read-only policy
// (`DatabaseConnectionManager.execute`), on a separate single-use read-only connection
// (`makeReadOnlySideManager`), never on a tab's session: nothing joins, waits on or reads a
// tab's transaction. A table gets `tableTimeout`; then its statement is stopped by closing that
// connection (not awaited), the table is marked timed out, and the next table gets a new one.
// The server's statement timeout is capped too, as a backstop. Cancel stops the search at once
// and keeps the tables found so far, as does a lost connection (one error, not one per table).
// DuckDB is not searched (no second connection to its file).

import Foundation
import Observation

@MainActor
@Observable
final class CrossTableSearchModel: Identifiable {
  typealias Mode = CrossTableSearchQueryBuilder.Mode

  static let maxTables = 500
  nonisolated static let tableTimeoutSeconds = 10
  nonisolated static let tableTimeout: Duration = .seconds(tableTimeoutSeconds)
  /// The server ends a statement the search could not stop after this
  nonisolated static let serverTimeoutSeconds = 15

  /// One table to search, as the loaded schema lists it
  struct Target: Sendable {
    var schema: String
    var name: String
    var columns: [CrossTableSearchQueryBuilder.Column]
    var primaryKeys: [String] { columns.filter(\.isPrimaryKey).map(\.name) }
  }

  /// One matching row: the display columns' text and the searched column that matched
  struct Match: Identifiable {
    let id: Int
    let values: [String]
    let column: String
  }

  /// A table with matches, or one that timed out or failed
  struct TableResult: Identifiable {
    enum Status: Equatable {
      case matched
      case timedOut
      case failed(String)
    }

    let schema: String
    let name: String
    let primaryKeys: [String]
    let displayColumns: [String]
    let matches: [Match]
    let status: Status
    var id: String { "\(schema)\u{0}\(name)" }
  }

  enum Phase: Equatable {
    case ready
    case searching
    case finished
    case cancelled
    case failed(String)
  }

  /// What one statement returned
  nonisolated enum Outcome: Sendable {
    case rows([[CellValue]])
    case timedOut
    case cancelled
    case failed(String)
    /// The connection closed under the statement: the remaining tables would fail too
    case connectionLost(String)
  }

  var value = ""
  var mode: Mode = .contains
  private(set) var phase: Phase = .ready
  /// Tables searched so far in this run
  private(set) var completed = 0
  private(set) var results: [TableResult] = []
  /// The value and mode of the run the results belong to
  private(set) var searchedValue = ""
  private(set) var searchedMode: Mode = .contains

  /// The tables the next search covers (the first `maxTables`), read again at every start
  private(set) var targets: [Target]
  /// Tables in the schema before the `maxTables` cap
  private(set) var totalTableCount: Int
  /// The schema read the targets come from (`WorkspaceManager.schemaConnectionEpoch`)
  let schemaEpoch: UInt64

  /// Hides the sheet
  @ObservationIgnored var onClose: () -> Void = {}
  /// Opens `schema.table` filtered on `column`; a running search goes on
  @ObservationIgnored var onOpen: (_ result: TableResult, _ filter: TableFilter) -> Void = { _, _ in
  }
  /// The loaded schema's tables, before the cap
  @ObservationIgnored private let loadTargets: () -> [Target]
  @ObservationIgnored private let dialect: SQLDialect
  @ObservationIgnored private let connectionManager: DatabaseConnectionManager
  @ObservationIgnored private var task: Task<Void, Never>?
  /// Bumped by every start and cancel: an older run never writes
  @ObservationIgnored private var run = 0

  init(
    schemaEpoch: UInt64, dialect: SQLDialect, connectionManager: DatabaseConnectionManager,
    loadTargets: @escaping () -> [Target]
  ) {
    let all = loadTargets()
    targets = Array(all.prefix(Self.maxTables))
    totalTableCount = all.count
    self.schemaEpoch = schemaEpoch
    self.dialect = dialect
    self.connectionManager = connectionManager
    self.loadTargets = loadTargets
  }

  var isSearching: Bool { phase == .searching }

  var canStart: Bool {
    !isSearching && !value.isEmpty && !targets.isEmpty
  }

  /// Cancels any search; the sheet's results stay for the next time it opens
  func hide() {
    cancel()
    onClose()
  }

  /// Starts a new search over every target, dropping the last run's results
  func start() {
    guard canStart else { return }
    task?.cancel()
    run += 1
    let all = loadTargets()
    targets = Array(all.prefix(Self.maxTables))
    totalTableCount = all.count
    let current = run
    let targets = targets
    let value = value
    let mode = mode
    let dialect = dialect
    let manager = connectionManager
    searchedValue = value
    searchedMode = mode
    results = []
    completed = 0
    phase = .searching
    task = Task { [weak self] in
      // Read once: every reconnect of this run opens the same server, even after a switch
      guard let config = await Self.sideConfig(like: manager) else {
        self?.fail("The search's read-only connection could not be opened.", run: current)
        return
      }
      guard !Task.isCancelled else { return }
      let pinned = Self.fingerprint(config)
      var side: DatabaseConnectionManager?
      for target in targets {
        guard !Task.isCancelled else { break }
        let outcome: Outcome
        let statement: CrossTableSearchQueryBuilder.Statement?
        do {
          statement = try CrossTableSearchQueryBuilder.statement(
            schema: target.schema, table: target.name, columns: target.columns, value: value,
            mode: mode, dialect: dialect)
        } catch {
          self?.record(target, nil, .failed(error.localizedDescription), run: current)
          continue
        }
        guard let statement else {
          // No column with a text form: nothing to search
          self?.record(target, nil, .rows([]), run: current)
          continue
        }
        if side == nil {
          // A switch or disconnect since the start: the run ends rather than reopen a server
          // the workspace left (a drop has cancelled it already)
          guard let now = await manager.config, Self.fingerprint(now) == pinned else {
            self?.fail(
              "The search's read-only connection could not be opened.", run: current)
            return
          }
          guard !Task.isCancelled else { break }
          let fresh = manager.makeReadOnlySideManager()
          do {
            // `identity` too: only the pinned connection's own secrets
            try await manager.connectSideManager(fresh, config: config, identity: config)
          } catch {
            Task { await fresh.disconnect() }
            self?.fail(
              "The search's read-only connection could not be opened.", run: current)
            return
          }
          guard !Task.isCancelled else {
            Task { await fresh.disconnect() }
            break
          }
          side = fresh
        }
        guard let connected = side else { break }
        outcome = await Self.search(statement, on: connected)
        switch outcome {
        case .timedOut, .cancelled:
          // Closing the connection stops the statement; the next table gets a new one
          side = nil
          Task { await connected.disconnect() }
        case .connectionLost(let message):
          Task { await connected.disconnect() }
          self?.fail(
            "The search stopped: its read-only connection was lost (\(message)). Search again "
              + "to retry.", run: current)
          return
        case .rows, .failed:
          break
        }
        guard !Task.isCancelled else { break }
        self?.record(target, statement, outcome, run: current)
      }
      if let side { Task { await side.disconnect() } }
      self?.finish(run: current)
    }
  }

  /// Stops the search now and keeps what it found. The statement still running is stopped by
  /// closing its connection, not awaited.
  func cancel() {
    guard isSearching else { return }
    run += 1
    task?.cancel()
    task = nil
    phase = .cancelled
  }

  /// Opens `result`'s table filtered on the column `match` matched, with the searched value
  func open(_ result: TableResult, _ match: Match) {
    onOpen(result, Self.filter(column: match.column, value: searchedValue, mode: searchedMode))
  }

  /// LIKE on `column`'s text, as the search compared it (`=` on the raw column would not match
  /// every type the same way): the value escaped as the search binds it, with the same `ESCAPE`
  /// character, so `\`, `%` and `_` match themselves on every engine. Contains ignores case
  /// (ILIKE); Equals has no wildcard.
  static func filter(column: String, value: String, mode: Mode) -> TableFilter {
    let escaped = CrossTableSearchQueryBuilder.escapedLikeText(value)
    let condition = FilterCondition(
      column: column, op: mode == .contains ? .ilike : .like,
      value: mode == .contains ? "%\(escaped)%" : escaped,
      likeEscape: String(CrossTableSearchQueryBuilder.escapeCharacter))
    return TableFilter(conditions: [condition])
  }

  // MARK: - Run

  private func record(
    _ target: Target, _ statement: CrossTableSearchQueryBuilder.Statement?, _ outcome: Outcome,
    run current: Int
  ) {
    guard current == run else { return }
    completed += 1
    let status: TableResult.Status
    var matches: [Match] = []
    switch outcome {
    case .rows(let rows):
      guard let statement, !rows.isEmpty else { return }
      matches = Self.matches(rows, statement: statement)
      status = .matched
    case .timedOut: status = .timedOut
    case .failed(let message): status = .failed(message)
    case .cancelled, .connectionLost: return
    }
    results.append(
      TableResult(
        schema: target.schema, name: target.name, primaryKeys: target.primaryKeys,
        displayColumns: statement?.displayColumns ?? [], matches: matches, status: status))
  }

  private func finish(run current: Int) {
    guard current == run else { return }
    task = nil
    phase = .finished
  }

  private func fail(_ message: String, run current: Int) {
    guard current == run else { return }
    task = nil
    phase = .failed(message)
  }

  /// The display texts and the matched column of each row (the last cell is the 1-based index
  /// of the first searched column that matched)
  private static func matches(
    _ rows: [[CellValue]], statement: CrossTableSearchQueryBuilder.Statement
  ) -> [Match] {
    let displayCount = statement.displayColumns.count
    return rows.enumerated().map { offset, row in
      let index = row.last.flatMap(Self.integer) ?? 1
      let column =
        statement.searchedColumns.indices.contains(index - 1)
        ? statement.searchedColumns[index - 1] : statement.searchedColumns[0]
      return Match(
        id: offset, values: row.prefix(displayCount).map(\.displayString), column: column)
    }
  }

  private static func integer(_ value: CellValue) -> Int? {
    switch value {
    case .int(let number): number
    case .string(let text): Int(text)
    case .double(let number): Int(exactly: number)
    default: nil
    }
  }

  // MARK: - Statements

  /// `manager`'s config for the side connections (`connectSideManager` adds its unremembered
  /// certificate and SSH secret), the server's statement timeout at most
  /// `serverTimeoutSeconds`. A SQLite file opens read-only. Nil when not connected.
  private nonisolated static func sideConfig(
    like manager: DatabaseConnectionManager
  ) async -> ConnectionConfig? {
    guard var config = await manager.config else { return nil }
    if config.databaseType == .sqlite { config.readOnlyFile = true }
    config.statementTimeoutSeconds = min(
      SessionBrakeLimits.clampStatementTimeout(
        config.statementTimeoutSeconds ?? serverTimeoutSeconds),
      serverTimeoutSeconds)
    return config
  }

  /// The connection `config` names, by the accounts its secrets are kept under
  private nonisolated static func fingerprint(_ config: ConnectionConfig) -> [String] {
    [
      config.databaseType.rawValue, ClientCertificateStoreFactory.account(for: config),
      SSHCredentialStoreFactory.account(for: config) ?? "",
    ]
  }

  /// `statement` through the read-only gate on `side`, or `.timedOut` after `timeout`, or
  /// `.cancelled` with the caller's task: the statement still running is not awaited.
  private nonisolated static func search(
    _ statement: CrossTableSearchQueryBuilder.Statement, on side: DatabaseConnectionManager,
    timeout: Duration = tableTimeout
  ) async -> Outcome {
    let (outcomes, continuation) = AsyncStream.makeStream(of: Outcome.self)
    let reading = Task {
      do {
        let result = try await side.execute(
          userSQL: statement.sql, parameters: statement.parameters,
          policy: ProtectionPolicy(protectionLevel: .readOnly),
          maxRows: CrossTableSearchQueryBuilder.rowLimit)
        continuation.yield(.rows(result.rows))
      } catch {
        // A lost session is forgotten (`markSessionLost`): the side is no longer connected
        let lost: Bool
        if case DatabaseError.connectionLost = error {
          lost = true
        } else {
          lost = await !side.isConnected
        }
        let message = error.localizedDescription
        continuation.yield(lost ? .connectionLost(message) : .failed(message))
      }
      continuation.finish()
    }
    let timer = Task {
      try? await Task.sleep(for: timeout)
      continuation.yield(.timedOut)
      continuation.finish()
    }
    let first = await withTaskCancellationHandler {
      var iterator = outcomes.makeAsyncIterator()
      return await iterator.next()
    } onCancel: {
      continuation.yield(.cancelled)
      continuation.finish()
    }
    reading.cancel()
    timer.cancel()
    return first ?? .cancelled
  }
}
