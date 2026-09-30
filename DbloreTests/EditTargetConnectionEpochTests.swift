// EditTargetConnectionEpochTests.swift
// Inline edit targets are bound to the connection they were resolved on: the actor refuses an
// edit whose target epoch is not its current connection epoch, and a connect/disconnect clears
// every edit target shown in the workspace tabs. No database needed.

import Foundation
import Testing

@testable import Dblore

@Suite("Edit target - connection epoch")
@MainActor
struct EditTargetConnectionEpochTests {
  private func statement() throws -> CellUpdateStatement {
    try CellUpdateStatement.make(
      qualifiedName: "public.t", columnName: "a", newValue: "1", primaryKeyColumns: ["id"],
      rowData: ["id": .int(1)])
  }

  private func isNotEditable(_ body: () async throws -> Void) async -> Bool {
    do {
      try await body()
      return false
    } catch DatabaseError.notEditable {
      return true
    } catch {
      return false
    }
  }

  // MARK: - Actor enforcement

  @Test("Epoch mismatch is refused before the connection check (nothing sent)")
  func epochMismatchRefusedFirst() async throws {
    let manager = DatabaseConnectionManager()
    let update = try statement()
    #expect(await manager.connectionEpoch == 0)
    #expect(
      await isNotEditable {
        _ = try await manager.executeGatedUpdate(
          update, policy: ProtectionPolicy(protectionLevel: .none), connectionEpoch: 1)
      })
  }

  @Test("Matching epoch reaches the connection check")
  func matchingEpochReachesConnection() async throws {
    let manager = DatabaseConnectionManager()
    let update = try statement()
    do {
      _ = try await manager.executeGatedUpdate(
        update, policy: ProtectionPolicy(protectionLevel: .none), connectionEpoch: 0)
      Issue.record("Expected notConnected")
    } catch DatabaseError.notConnected {
      // expected
    }
  }

  @Test("A disconnect advances the epoch, so a target from before it is refused")
  func disconnectAdvancesEpoch() async throws {
    let manager = DatabaseConnectionManager()
    let update = try statement()
    await manager.disconnect()
    #expect(await manager.connectionEpoch == 1)
    #expect(
      await isNotEditable {
        _ = try await manager.executeGatedUpdate(
          update, policy: ProtectionPolicy(protectionLevel: .none), connectionEpoch: 0)
      })
  }

  // MARK: - ViewModel clearing

  private func target(
    tableID: TableRef = .postgresql(oid: 16_400)
  ) -> EditTarget {
    EditTarget(qualifiedName: "public.users", tableID: tableID, primaryKeyColumns: ["id"])
  }

  private func result(_ target: EditTarget) -> CellResult {
    CellResult(
      columns: [ColumnInfo(name: "id", type: "int4")], rows: [[.int(1)]], rowCount: 1,
      tableName: target.qualifiedName, primaryKeyColumns: ["id"], editTarget: target)
  }

  private func seed(_ viewModel: NotebookViewModel) {
    let target = target()
    var cell = NotebookCell(cellType: .sql, content: "SELECT * FROM users")
    cell.result = result(target)
    cell.statementResults = [
      StatementResult(queryText: "SELECT 1", result: result(target), statementIndex: 0)
    ]
    viewModel.notebook.cells = [cell]
    viewModel.editorResult = result(target)
    viewModel.editorStatementResults = [
      StatementResult(queryText: "SELECT 1", result: result(target), statementIndex: 0)
    ]
    viewModel.cellDetailEditTarget = target
  }

  private func hasNoEditTarget(_ viewModel: NotebookViewModel) -> Bool {
    let cellTargets = viewModel.notebook.cells.flatMap { cell in
      [cell.result?.editTarget] + cell.statementResults.map(\.result.editTarget)
    }
    let editorTargets =
      [viewModel.editorResult?.editTarget]
      + viewModel.editorStatementResults.map(\.result.editTarget)
    return (cellTargets + editorTargets).allSatisfy { $0 == nil }
      && viewModel.cellDetailEditTarget == nil
  }

  @Test("invalidateEditTargets clears every displayed result and the sidebar target")
  func invalidateClearsAll() {
    let viewModel = NotebookViewModel()
    seed(viewModel)
    #expect(!hasNoEditTarget(viewModel))
    viewModel.invalidateEditTargets()
    #expect(hasNoEditTarget(viewModel))
    // Results stay displayed, only read-only
    #expect(viewModel.notebook.cells.first?.result?.rows.count == 1)
    #expect(viewModel.editorResult?.rows.count == 1)
  }

  @Test("Workspace disconnect clears edit targets in every tab")
  func workspaceDisconnectClearsTabs() async throws {
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: ConnectionConfig()), restoreTabs: false)
    let first = try #require(manager.viewModel(for: manager.newNotebook()))
    let second = try #require(manager.viewModel(for: manager.newNotebook()))
    seed(first)
    seed(second)
    await manager.disconnect()
    #expect(hasNoEditTarget(first))
    #expect(hasNoEditTarget(second))
  }

  @Test("Refreshing the same table keeps the open sidebar edit target")
  func carryKeepsMatchingTableIdentity() {
    let tableID = TableRef.postgresql(oid: 16_400)
    let current = target(tableID: tableID)
    let refreshed = target(tableID: tableID)
    let viewModel = NotebookViewModel()
    viewModel.cellDetailEditTarget = current
    viewModel.carryCellDetailEditTarget(from: result(current), to: result(refreshed))
    #expect(viewModel.cellDetailEditTarget == refreshed)
  }

  @Test("Refreshing a different table drops the open sidebar edit target")
  func carryDropsDifferentTableIdentity() {
    let current = target()
    let refreshed = target(tableID: .postgresql(oid: 99))
    let viewModel = NotebookViewModel()
    viewModel.cellDetailEditTarget = current
    viewModel.carryCellDetailEditTarget(from: result(current), to: result(refreshed))
    #expect(viewModel.cellDetailEditTarget == nil)
  }

  @Test("A protection change does not clear edit targets (same connection)")
  func protectionChangeKeepsTargets() throws {
    let manager = WorkspaceManager(
      workspace: Workspace(connectionConfig: ConnectionConfig()), restoreTabs: false)
    let viewModel = try #require(manager.viewModel(for: manager.newNotebook()))
    seed(viewModel)
    var config = try #require(manager.workspace.connectionConfig)
    config.safeMode = .alertAll
    manager.updateConnectionProtection(from: config)
    #expect(viewModel.cellDetailEditTarget != nil)
    #expect(viewModel.notebook.cells.first?.result?.editTarget != nil)
  }
}
