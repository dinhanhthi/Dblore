// QuerySentAsWrittenTests.swift
// C4: the SQL sent to PostgreSQL is the text of each split statement, unchanged: no LIMIT / ctid
// rewrite (the old wrapper appended "LIMIT n" after stripping comments, which broke
// FETCH FIRST) and no "SELECT COUNT(*) FROM (...)" second execution for pagination.
// Against the docker test database (TEST_DB_* env, port 5435 in CI/autopilot).

import Foundation
import Testing

@testable import Dblore

@Suite("Query Sent As Written - Integration (Requires PostgreSQL)", .requiresPostgres, .serialized)
@MainActor
struct QuerySentAsWrittenTests {
  private static func config() -> ConnectionConfig {
    return ConnectionConfig(
      host: TestDatabase.host,
      port: TestDatabase.port,
      database: TestDatabase.database,
      username: TestDatabase.username,
      password: TestDatabase.password,
      sslMode: .disable,
      timeoutSeconds: 30,
      safeMode: .silent,
      protectedMode: false,
      statementTimeoutSeconds: 45
    )
  }

  private let open = ProtectionPolicy(protectionLevel: .none)

  private func connected() async throws -> DatabaseConnectionManager {
    let manager = DatabaseConnectionManager()
    try await manager.connect(config: Self.config())
    return manager
  }

  /// A view model wired to `manager` like a connected tab
  private func viewModel(_ manager: DatabaseConnectionManager) -> NotebookViewModel {
    let viewModel = NotebookViewModel()
    viewModel.connectionManager = manager
    viewModel.connectionState = .connected
    return viewModel
  }

  /// Creates `sequence` fresh; each `nextval` call bumps `last_value` by one
  private func makeSequence(_ sequence: String, _ observer: DatabaseConnectionManager) async throws
  {
    _ = try await observer.executeInternal("DROP SEQUENCE IF EXISTS \(sequence)")
    _ = try await observer.executeInternal("CREATE SEQUENCE \(sequence)")
  }

  private func lastValue(
    _ sequence: String, _ observer: DatabaseConnectionManager
  ) async throws
    -> CellValue?
  {
    try await observer.executeInternal("SELECT last_value FROM \(sequence)").rows.first?.first
  }

  // MARK: - Actor

  @Test("FETCH FIRST with a trailing comment runs unchanged and returns 5 rows")
  func fetchFirstWithTrailingComment() async throws {
    let manager = try await connected()
    do {
      let sql = """
        SELECT g FROM generate_series(1, 1000) AS g ORDER BY g
        FETCH FIRST 5 ROWS ONLY -- only the first five
        """
      let result = try await manager.execute(userSQL: sql, policy: open, maxRows: 100)
      #expect(result.rows.count == 5)
      #expect(!result.truncated)
      #expect(result.rows.first?.first == .int(1))
    } catch {
      Issue.record(error)
    }
    await manager.disconnect()
  }

  @Test("The server receives exactly the statement text (comments kept, no LIMIT appended)")
  func serverReceivesStatementText() async throws {
    let manager = try await connected()
    do {
      let sql =
        "SELECT query FROM pg_stat_activity WHERE pid = pg_backend_pid() -- c4 sent as written"
      let result = try await manager.execute(userSQL: sql, policy: open, maxRows: 100)
      #expect(result.rows.first?.first == .string(sql))
    } catch {
      Issue.record(error)
    }
    await manager.disconnect()
  }

  // MARK: - ViewModel (no COUNT(*) second execution)

  @Test("A notebook cell with LIMIT runs its statement once (no COUNT(*) re-execution)")
  func cellRunsOnce() async throws {
    let sequence = "c4_sent_once_cell"
    let observer = try await connected()
    let manager = try await connected()
    do {
      try await makeSequence(sequence, observer)
      let sql = "SELECT nextval('\(sequence)') FROM generate_series(1, 3) LIMIT 3"
      let viewModel = viewModel(manager)
      let cell = NotebookCell(cellType: .sql, content: sql)
      viewModel.notebook.cells.append(cell)
      let result = await viewModel.executeTask(ExecutionTask(cellId: cell.id, query: sql))
      #expect(result?.error == nil)
      #expect(result?.rowCount == 3)
      #expect(try await lastValue(sequence, observer) == .int(3))
    } catch {
      Issue.record(error)
    }
    _ = try? await observer.executeInternal("DROP SEQUENCE IF EXISTS \(sequence)")
    await manager.disconnect()
    await observer.disconnect()
  }

  @Test("An editor query with LIMIT runs its statement once (no COUNT(*) re-execution)")
  func editorRunsOnce() async throws {
    let sequence = "c4_sent_once_editor"
    let observer = try await connected()
    let manager = try await connected()
    do {
      try await makeSequence(sequence, observer)
      let sql = "SELECT nextval('\(sequence)') FROM generate_series(1, 3) LIMIT 3"
      let viewModel = viewModel(manager)
      viewModel.queryConfirmationState.pendingQuery = sql
      await viewModel.executeConfirmedEditorQuery()
      #expect(viewModel.editorResult?.error == nil)
      #expect(viewModel.editorResult?.rowCount == 3)
      #expect(try await lastValue(sequence, observer) == .int(3))
    } catch {
      Issue.record(error)
    }
    _ = try? await observer.executeInternal("DROP SEQUENCE IF EXISTS \(sequence)")
    await manager.disconnect()
    await observer.disconnect()
  }
}
