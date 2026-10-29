// SchemaDiagramPreviewSheet.swift
// Preview SQL of the diagram's staged changes: the exact SQL Apply sends (`SQLCodeWell`), a
// build error, MySQL's statement-by-statement warning, the result of the last Apply and the
// Safe Mode step (this sheet also opens for it when Apply was clicked on the diagram's bar).
// Toasts show in the sheet's own overlay while it is open (the diagram's overlay hides them).

import SwiftUI

struct SchemaDiagramPreviewSheet: View {
  @Bindable var model: SchemaDiagramEditModel
  /// For the Safe Mode "Forgot Password?" fallback
  let databasePassword: String?
  let isConnected: Bool
  /// False once the sheet was closed or replaced (a late Touch ID answer then sends nothing)
  let isShown: () -> Bool
  let onApply: () -> Void
  let onClose: () -> Void

  @State private var showsSpinner = false
  @State private var spinnerTask: Task<Void, Never>?

  var body: some View {
    VStack(spacing: 0) {
      GenericModalHeader(
        title: "Diagram Changes", titleIcon: "point.3.connected.trianglepath.dotted",
        titleIconColor: .accent, titleBadge: model.databaseType.rawValue, onClose: onClose)
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.lg) {
          banners
          previewSection
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: .infinity)
      .overlay { ToastOverlay().environment(\.hidesToastOverlay, false) }
      if let statements = model.confirmation.pendingConfirmation {
        SafeModeConfirmationPanel(
          requiresPassword: model.confirmation.requiresPassword,
          confirmTitle: "Apply Changes",
          biometricReason: "Authorize the diagram's schema changes in Safe Mode",
          databasePassword: databasePassword, isConnected: isConnected,
          isPending: { [model] in model.confirmation.pendingConfirmation != nil && isShown() },
          onCancel: { [model] in model.cancelConfirmation() },
          onConfirm: { [model] in await model.confirmApply() }
        ) {
          SafeModeStatementList(statements: statements)
        }
      }
      footer
    }
    .frame(width: 720, height: 560)
    .background(Color.cardBackground)
    .interactiveDismissDisabled(model.isApplying)
    // The button says Applying at once; the spinner fades in only after 150 ms
    .onChange(of: model.isApplying) { _, applying in
      spinnerTask?.cancel()
      showsSpinner = false
      guard applying else { return }
      spinnerTask = Task {
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled, model.isApplying else { return }
        showsSpinner = true
      }
    }
  }

  // MARK: - Sections

  @ViewBuilder
  private var banners: some View {
    if let reason = model.disabledReason {
      StructureBanner(text: reason, systemImage: "lock", color: .warning)
    }
    if let warning = model.applyWarning {
      StructureBanner(text: warning, systemImage: "exclamationmark.triangle", color: .warning)
    }
    if let error = model.applyError {
      StructureBanner(
        text: error, systemImage: "exclamationmark.triangle",
        color: model.applyPartiallyFailed ? .warning : .destructive)
    } else if let result = model.resultMessage {
      StructureBanner(
        text: result, systemImage: "checkmark.circle",
        color: result == SchemaDiagramEditModel.appliedMessage ? .success : .warning)
    }
  }

  private var previewSection: some View {
    SettingsGroupCard(title: "SQL Preview") {
      Text("Apply sends exactly this SQL")
        .font(.small)
        .foregroundColor(.foregroundSubtle)
    } content: {
      // A builder error leaves no statements: it takes the placeholder's place in the well
      SQLCodeWell(
        sql: model.previewStatements.map { $0 + ";" }.joined(separator: "\n"),
        placeholder: model.previewError == nil ? "No changes" : nil,
        dialect: model.databaseType.dialect
      )
      .overlay(alignment: .topLeading) {
        if let error = model.previewError {
          Label(error, systemImage: "exclamationmark.triangle")
            .font(.small)
            .foregroundColor(.destructive)
            .textSelection(.enabled)
            .padding(Spacing.md)
        }
      }
      .frame(height: 240)
    }
  }

  private var footer: some View {
    GenericModalFooter {
      Text(SchemaDiagramEditBar.countText(model.changeCount))
        .font(.small)
        .foregroundColor(.foregroundMuted)
      Spacer()
      ProgressView()
        .controlSize(.small)
        .opacity(showsSpinner ? 1 : 0)
        .animation(.easeIn(duration: 0.15), value: showsSpinner)
        .accessibilityHidden(!showsSpinner)
      Button("Discard") { model.discardChanges() }
        .buttonStyle(FilledSecondaryButtonStyle())
        .disabled(model.changeCount == 0 || model.isApplying)
      Button("Close", action: onClose)
        .buttonStyle(FilledSecondaryButtonStyle())
        .disabled(model.isApplying)
        .keyboardShortcut(.cancelAction)
      Button(model.isApplying ? "Applying..." : "Apply", action: onApply)
        .buttonStyle(PrimaryButtonStyle())
        .disabled(!model.canApply || model.confirmation.pendingConfirmation != nil)
        .help(SchemaDiagramEditBar.applyHelp(model))
    }
  }
}

// MARK: - Bar

/// The bar under the diagram while changes are staged, applying, or an apply left a message:
/// "N changes", Discard, Preview SQL and Apply, with the last result or error
struct SchemaDiagramEditBar: View {
  @Bindable var model: SchemaDiagramEditModel
  let onPreview: () -> Void
  let onApply: () -> Void

  /// Something to show: staged or loading changes, an apply running, or a message that stays
  /// (an error, pending until Commit, inside the open transaction). "Applied" is a toast only.
  static func isShown(_ model: SchemaDiagramEditModel) -> Bool {
    model.changeCount > 0 || !model.loadingTables.isEmpty || model.isApplying
      || model.applyError != nil
      || (model.resultMessage.map { $0 != SchemaDiagramEditModel.appliedMessage } ?? false)
  }

  static func countText(_ count: Int) -> String {
    count == 1 ? "1 change" : "\(count) changes"
  }

  /// Why Apply is disabled, or what it does
  static func applyHelp(_ model: SchemaDiagramEditModel) -> String {
    if let reason = model.disabledReason { return reason }
    if let error = model.previewError { return error }
    if model.changeCount == 0 { return "No changes" }
    return model.applyWarning ?? "Apply the staged changes"
  }

  var body: some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: "square.and.pencil")
        .foregroundColor(.accent)
      Text(Self.countText(model.changeCount))
        .font(.small)
        .foregroundColor(.foreground)
        .monospacedDigit()
      if !model.loadingTables.isEmpty {
        Text("Reading \(model.loadingTables.count == 1 ? "table" : "tables")...")
          .font(.small)
          .foregroundColor(.foregroundMuted)
      }
      status
      Spacer()
      Button("Discard") { model.discardChanges() }
        .buttonStyle(GhostButtonStyle())
        .disabled(model.changeCount == 0 || model.isApplying)
      Button("Preview SQL", action: onPreview)
        .buttonStyle(SecondaryButtonStyle())
      Button(model.isApplying ? "Applying..." : "Apply", action: onApply)
        .buttonStyle(PrimaryButtonStyle())
        .disabled(!model.canApply || model.confirmation.pendingConfirmation != nil)
        .help(Self.applyHelp(model))
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.xs)
    .background(Color.cardHeaderBackground)
    .overlay(alignment: .top) { Divider() }
  }

  /// The last apply's error or lasting message, else a build error or MySQL's warning
  @ViewBuilder
  private var status: some View {
    if let error = model.applyError {
      statusLabel(error, color: model.applyPartiallyFailed ? .warning : .destructive)
    } else if let result = model.resultMessage, result != SchemaDiagramEditModel.appliedMessage {
      statusLabel(result, color: .warning)
    } else if let error = model.previewError {
      statusLabel(error, color: .destructive)
    } else if let warning = model.applyWarning {
      statusLabel(warning, color: .warning)
    }
  }

  private func statusLabel(_ text: String, color: Color) -> some View {
    Label(text, systemImage: "exclamationmark.triangle")
      .font(.small)
      .foregroundColor(color)
      .lineLimit(1)
      .truncationMode(.tail)
      .help(text)
  }
}
