// TableHealthSheet.swift
// File > Table Health...: opens at once on placeholder rows (the run starts with it); a spinner
// with the progress fades in only after 150 ms, so a fast run shows none. Then the notes, a
// filter (All / Keys / Indexes / Bloat) and a row per finding with Show Table, which hides the
// sheet and shows the table. Copy Report puts the whole report on the pasteboard as Markdown.

import AppKit
import SwiftUI

extension View {
  /// The sheet, and its File menu item's action (published here rather than in the container's
  /// body, whose chain is at the type checker's limit)
  func tableHealthSheet(workspaceManager: WorkspaceManager) -> some View {
    let menuAction: (() -> Void)? =
      workspaceManager.canOpenTableHealth
      ? { [workspaceManager] in workspaceManager.openTableHealth() } : nil
    return sheet(
      item: Binding(
        get: { workspaceManager.tableHealth },
        set: { if $0 == nil { workspaceManager.tableHealth?.cancel() } })
    ) { model in
      TableHealthSheet(model: model) { [workspaceManager] finding in
        workspaceManager.showTableHealthTable(finding)
      }
    }
    .bridgedFocusedSceneValue(\.openTableHealthAction, menuAction)
  }
}

private struct TableHealthSheet: View {
  @Bindable var model: TableHealthModel
  let onShowTable: (TableHealthFinding) -> Void

  @State private var showsSpinner = false

  private static let placeholderRows = 5
  private static let placeholder = TableHealthFinding(
    schema: "public", table: "table_name", kind: .foreignKeyWithoutIndex,
    reason: "A one-line reason that takes the place of the finding while it loads.")

  var body: some View {
    VStack(spacing: 0) {
      GenericModalHeader(
        title: "Table Health", titleIcon: "stethoscope", titleBadge: model.databaseName,
        onClose: { model.cancel() })
      filterBar
      Divider()
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      footer
    }
    .frame(width: 640, height: 520)
    .background(Color.cardBackground)
    .interactiveDismissDisabled()
    .onExitCommand { model.cancel() }
    // Placeholder rows at once; the spinner fades in only after 150 ms
    .task(id: model.isLoading) {
      showsSpinner = false
      guard model.isLoading else { return }
      try? await Task.sleep(for: .milliseconds(150))
      guard !Task.isCancelled, model.isLoading else { return }
      showsSpinner = true
    }
  }

  private var filterBar: some View {
    HStack(spacing: Spacing.sm) {
      CapsuleTabPicker(
        selection: $model.category, tabs: TableHealthModel.Category.allCases, height: 28
      ) { category in
        CapsuleTabLabel(text: category.title, isSelected: model.category == category)
      }
      .fitsContent()
      .disabled(model.phase != .loaded)
      Spacer(minLength: Spacing.sm)
      if model.phase == .loaded {
        Text(countText)
          .font(.small)
          .foregroundColor(.foregroundMuted)
          .monospacedDigit()
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
  }

  @ViewBuilder
  private var content: some View {
    switch model.phase {
    case .loading:
      placeholderList
    case .failed(let message):
      StructureBanner(text: message, systemImage: "exclamationmark.triangle", color: .destructive)
        .padding(Spacing.md)
    case .loaded:
      ScrollView {
        LazyVStack(alignment: .leading, spacing: Spacing.sm) {
          ForEach(model.report.notes, id: \.self) { note in
            StructureBanner(text: note, systemImage: "info.circle", color: .foregroundSubtle)
          }
          let findings = model.visibleFindings
          if findings.isEmpty {
            Text(model.report.findings.isEmpty ? "No findings." : "No findings in this category.")
              .font(.bodyText)
              .foregroundColor(.foregroundSubtle)
          }
          ForEach(Array(findings.enumerated()), id: \.offset) { _, finding in
            TableHealthFindingRow(finding: finding) { onShowTable(finding) }
          }
        }
        .padding(Spacing.md)
      }
    }
  }

  /// The rows' shape, redacted, under the delayed spinner
  private var placeholderList: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      ForEach(0..<Self.placeholderRows, id: \.self) { _ in
        TableHealthFindingRow(finding: Self.placeholder, onShowTable: {})
          .redacted(reason: .placeholder)
          .disabled(true)
      }
    }
    .padding(Spacing.md)
    .accessibilityHidden(true)
    .overlay {
      VStack(spacing: Spacing.sm) {
        ProgressView()
          .controlSize(.small)
        Text(progressText)
          .font(.small)
          .foregroundColor(.foregroundSubtle)
          .monospacedDigit()
      }
      .padding(Spacing.md)
      .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: CornerRadius.md))
      .opacity(showsSpinner ? 1 : 0)
      .animation(.easeIn(duration: 0.15), value: showsSpinner)
      .accessibilityHidden(!showsSpinner)
    }
  }

  private var footer: some View {
    GenericModalFooter {
      Spacer()
      Button("Copy Report") {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(model.markdown(), forType: .string)
      }
      .buttonStyle(SecondaryButtonStyle())
      .disabled(model.phase != .loaded)
      if model.isLoading {
        Button(model.isCancelling ? "Cancelling…" : "Cancel") { model.cancel() }
          .buttonStyle(SecondaryButtonStyle())
          .disabled(model.isCancelling)
          .keyboardShortcut(.cancelAction)
      } else {
        Button("Done") { model.cancel() }
          .buttonStyle(PrimaryButtonStyle())
          .keyboardShortcut(.defaultAction)
      }
    }
  }

  private var countText: String {
    let count = model.visibleFindings.count
    return count == 1 ? "1 finding" : "\(count.formatted()) findings"
  }

  private var progressText: String {
    if model.isCancelling { return "Stopping after the reads in progress…" }
    return "Checking tables (\(model.completed.formatted()) of "
      + "\(model.tables.count.formatted()))…"
  }
}

/// One finding: severity, kind, table, the reason, and Show Table
private struct TableHealthFindingRow: View {
  let finding: TableHealthFinding
  let onShowTable: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: Spacing.sm) {
      Image(
        systemName: finding.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle"
      )
      .foregroundColor(finding.severity == .warning ? .warning : .foregroundMuted)
      .frame(width: 16)
      .accessibilityLabel(finding.severity == .warning ? "Warning" : "Info")
      VStack(alignment: .leading, spacing: Spacing.xxs) {
        HStack(spacing: Spacing.xs) {
          Text(finding.kind.title)
            .font(.bodyText)
            .fontWeight(.semibold)
            .foregroundColor(.foreground)
          Text(TableHealthModel.displayName(finding))
            .font(.small)
            .foregroundColor(.foregroundMuted)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        Text(finding.reason)
          .font(.small)
          .foregroundColor(.foregroundSubtle)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }
      Spacer(minLength: Spacing.sm)
      Button("Show Table", action: onShowTable)
        .buttonStyle(SecondaryButtonStyle())
    }
    .padding(Spacing.sm)
    .background(Color.controlBackground, in: RoundedRectangle(cornerRadius: CornerRadius.md))
  }
}
