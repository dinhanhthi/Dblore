//
//  PendingTransactionBanner.swift
//  Dblore
//
//  Workspace-level banner for the pending Protected transaction: summary, open timer, the
//  pending statements, Commit (prominent) and Rollback. Aborted: warning style, reason, only
//  Rollback. Also hosts the Commit confirmation and the Safe Mode unlock for Commit.
//

import SwiftUI

struct PendingTransactionBanner: View {
  @Bindable var workspaceManager: WorkspaceManager

  @State private var isExpanded = false
  @State private var isWorking = false
  /// When Commit / Rollback started being awaited (nil when not ending)
  @State private var endingSince: Date?

  private var state: TransactionState { workspaceManager.pendingTransaction }
  private var summary: PendingTransactionSummary { PendingTransactionSummary(state: state) }
  private var tint: Color { summary.isAborted ? .destructive : .warning }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      header
      if summary.isAborted, let reason = summary.abortReason {
        Text("A statement failed, so only Rollback is possible: \(reason)")
          .font(.small)
          .foregroundColor(.destructive)
          .lineLimit(3)
          .textSelection(.enabled)
      }
      if isExpanded {
        statementList
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .tintedChromeGlass(tint)
    .overlay(alignment: .bottom) {
      Rectangle().fill(tint.opacity(0.4)).frame(height: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(summary.isAborted ? "Failed pending transaction" : "Pending transaction")
    .onChange(of: summary.ending, initial: true) { _, ending in
      endingSince = ending == nil ? nil : Date()
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: summary.isAborted ? "exclamationmark.octagon.fill" : "clock.badge")
        .foregroundColor(tint)
        .accessibilityHidden(true)

      Button {
        isExpanded.toggle()
      } label: {
        HStack(spacing: Spacing.xs) {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 10, weight: .semibold))
          Text(summary.headline)
            .font(.labelText.weight(.medium))
            .foregroundColor(.foreground)
          openTimer
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .linkPointer()
      .accessibilityLabel(summary.headline)
      .accessibilityHint(isExpanded ? "Hide pending statements" : "Show pending statements")

      Spacer(minLength: Spacing.sm)

      slowEndingDisconnect

      Button("Roll Back") {
        run { await workspaceManager.rollback() }
      }
      .glassButtonStyle()
      .linkPointer()
      .controlSize(.small)
      .disabled(isWorking || isBusy)
      .accessibilityLabel("Roll back \(summary.statementCount) pending statements")

      Button("Commit") {
        workspaceManager.requestCommit()
      }
      .glassButtonStyle(prominent: true)
      .linkPointer()
      .tint(tint)
      .controlSize(.small)
      .disabled(summary.isAborted || isWorking || isBusy)
      .help(commitHelp)
      .accessibilityLabel("Commit \(summary.statementCount) pending statements")
    }
  }

  /// Commit / Rollback is being sent, or the origin tab is still running statements
  private var isBusy: Bool {
    summary.ending != nil || workspaceManager.isTransactionOriginRunning
  }

  private var commitHelp: String {
    if summary.ending != nil { return "Wait until Commit / Rollback finishes" }
    if summary.isAborted { return "A statement failed: only Rollback is possible" }
    if workspaceManager.isTransactionOriginRunning {
      return "Wait until the running statements finish, then review and commit"
    }
    return ""
  }

  /// COMMIT / ROLLBACK may never answer: after a few seconds offer the way out. Not routed
  /// through `run` (a hung Rollback keeps `isWorking` set); the prompt explains the outcome.
  @ViewBuilder
  private var slowEndingDisconnect: some View {
    if let since = endingSince {
      TimelineView(.periodic(from: .now, by: 1)) { context in
        if let title = PendingTransactionSummary.slowEndingPrompt(
          summary.ending, elapsed: context.date.timeIntervalSince(since))
        {
          Button(title) {
            Task { await workspaceManager.disconnect() }
          }
          .glassButtonStyle(prominent: true)
          .linkPointer()
          .tint(.destructive)
          .controlSize(.small)
          .accessibilityHint("Closes the connection; asks first")
        }
      }
    }
  }

  @ViewBuilder
  private var openTimer: some View {
    if let openedAt = workspaceManager.transactionOpenedAt {
      TimelineView(.periodic(from: .now, by: 1)) { context in
        Text(
          "· open for "
            + PendingTransactionSummary.openDuration(context.date.timeIntervalSince(openedAt))
        )
        .font(.labelText.monospacedDigit())
        .foregroundColor(.foregroundMuted)
      }
    }
  }

  // MARK: - Statement list

  private var statementList: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.xs) {
        ForEach(Array(state.pending.enumerated()), id: \.offset) { _, statement in
          PendingStatementRow(statement: statement)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxHeight: 160)
    .fixedSize(horizontal: false, vertical: true)
  }

  private func run(_ action: @escaping @MainActor () async -> Bool) {
    guard !isWorking else { return }
    isWorking = true
    Task { @MainActor in
      _ = await action()
      isWorking = false
    }
  }
}

/// One pending statement: kind label, SQL preview, affected rows
private struct PendingStatementRow: View {
  let statement: StatementSummary

  private var rowsText: String { statement.rowsText }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
      Text(statement.kindLabel)
        .font(.smallest.weight(.semibold))
        .foregroundColor(.foregroundMuted)
        .frame(minWidth: 56, alignment: .leading)
      Text(statement.sqlPreview)
        .font(.monoSmall)
        .foregroundColor(.foreground)
        .lineLimit(1)
        .truncationMode(.tail)
        .textSelection(.enabled)
      Spacer(minLength: Spacing.sm)
      Text(rowsText)
        .font(.small.monospacedDigit())
        .foregroundColor(.foregroundMuted)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(statement.kindLabel): \(statement.sqlPreview)\(rowsText.isEmpty ? "" : ", \(rowsText)")")
  }
}

// MARK: - Commit confirmation and unlock

extension View {
  /// Commit confirmation ("Commit N statements · M rows?") and the Safe Mode unlock for Commit
  func pendingTransactionDialogs(workspaceManager: WorkspaceManager) -> some View {
    modifier(PendingTransactionDialogs(workspaceManager: workspaceManager))
  }
}

private struct PendingTransactionDialogs: ViewModifier {
  @Bindable var workspaceManager: WorkspaceManager

  private var summary: PendingTransactionSummary {
    PendingTransactionSummary(state: workspaceManager.pendingTransaction)
  }

  func body(content: Content) -> some View {
    content
      .confirmationDialog(
        summary.commitPrompt,
        isPresented: $workspaceManager.isCommitConfirmationVisible,
        titleVisibility: .visible
      ) {
        // Return maps to Cancel, never to Commit (as in the NSAlert prompt)
        Button("Commit") {
          Task { await workspaceManager.confirmCommit() }
        }
        Button("Cancel", role: .cancel) {
          workspaceManager.cancelCommitConfirmation()
        }
        .keyboardShortcut(.defaultAction)
      } message: {
        // The title already counts statements and rows; the banner lists the statements
        if let warning = summary.earlierChangesWarning {
          Text(warning)
        }
      }
      .sheet(isPresented: $workspaceManager.isCommitUnlockVisible) {
        SafeModeUnlockSheet(
          message: "Safe Mode requires verification to commit: \(summary.commitPrompt)",
          biometricReason: "Commit pending changes",
          storedDatabasePassword: workspaceManager.workspace.connectionConfig?.password,
          onUnlock: { Task { await workspaceManager.completeCommitUnlock() } },
          onCancel: { workspaceManager.cancelCommitUnlock() })
      }
  }
}
