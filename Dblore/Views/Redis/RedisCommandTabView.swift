//
//  RedisCommandTabView.swift
//  Dblore
//
//  The command tab of a Redis workspace: the editor (Redis highlighting and autocomplete), the
//  db index the commands run in, Run (the selection, else the caret's line; Cmd+Return through
//  the Query menu), Run All and Cancel, and one reply card per command sent. The runner checks
//  everything before anything is sent; its confirmation shows here: a plain dialog under the
//  Immediate commit style (destructive commands), else the Safe Mode panel (password or Touch ID)
//  in a sheet. Both list the commands as the runner redacted them, never their raw arguments.
//  Notebooks, data viewers and SQL editors have no Redis form: `RedisUnavailableTabView`.
//

import AppKit
import SwiftUI

struct RedisCommandTabView: View {
  @Bindable var viewModel: NotebookViewModel
  let runner: RedisCommandRunner
  let workspaceManager: WorkspaceManager
  /// This tab is the active one of the key window: the Query menu's Run reaches it then
  let isActiveTab: () -> Bool

  @Bindable private var appSettings = AppSettings.shared
  @State private var textViewRef: SQLTextView?
  @State private var isFocused = false
  @State private var dividerPosition: CGFloat = 0.45
  /// The plain confirmation on screen (Immediate commit style); the runner's own stays pending
  /// until a button answers it
  @State private var dialogConfirmation: RedisCommandRunner.Confirmation?

  /// The most commands a confirmation lists; the rest are counted
  static let maxListedCommands = 20
  private static let minPaneHeight: CGFloat = 120

  private var isConnected: Bool { viewModel.connectionState.isConnected }

  private var canRun: Bool {
    isConnected && !runner.isRunning
      && !viewModel.editorContent.allSatisfy(\.isWhitespace)
  }

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Rectangle().fill(Color.border).frame(height: 1)
      GeometryReader { geometry in
        let total = max(geometry.size.height, 1)
        let maxEditor = max(total - Self.minPaneHeight, Self.minPaneHeight)
        let editorHeight = max(Self.minPaneHeight, min(maxEditor, total * dividerPosition))
        VStack(spacing: 0) {
          editor(height: editorHeight)
          ResizableDivider(
            position: $dividerPosition, axis: .vertical, totalHeight: total,
            minTopHeight: Self.minPaneHeight, minBottomHeight: Self.minPaneHeight)
          results
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }
    .background(Color.appBackground)
    .onChange(of: textViewRef) { _, newValue in
      viewModel.editorTextView = newValue
    }
    .onReceive(NotificationCenter.default.publisher(for: .runEditorQuery)) { _ in
      guard isActiveTab() else { return }
      run()
    }
    .onChange(of: runner.pendingConfirmation?.id, initial: true) {
      dialogConfirmation = runner.pendingConfirmation.flatMap { $0.needsSafeModePanel ? nil : $0 }
    }
    .confirmationDialog(
      dialogConfirmation.map(Self.title(of:)) ?? "",
      isPresented: Binding(
        get: { dialogConfirmation != nil },
        set: { if !$0 { dialogConfirmation = nil } }),
      titleVisibility: .visible,
      presenting: dialogConfirmation
    ) { pending in
      Button("Run", role: .destructive) {
        Task { await runner.confirm(pending) }
      }
      Button("Cancel", role: .cancel) {
        runner.cancelConfirmation()
      }
    } message: { pending in
      Text(verbatim: Self.listedText(of: pending))
    }
    .sheet(
      isPresented: Binding(
        get: { runner.pendingConfirmation?.needsSafeModePanel == true },
        set: { if !$0 { runner.cancelConfirmation() } })
    ) {
      if let pending = runner.pendingConfirmation, pending.needsSafeModePanel {
        RedisConfirmSheet(
          runner: runner, confirmation: pending,
          databasePassword: workspaceManager.workspace.connectionConfig?.password,
          isConnected: isConnected)
      }
    }
  }

  // MARK: - Toolbar

  private var toolbar: some View {
    HStack(spacing: Spacing.sm) {
      CapsuleDropdown(
        title: "db \(workspaceManager.redisDatabase)",
        accessibilityLabel: "Database index",
        options: databaseOptions,
        optionTitle: { "db \($0)" },
        isSelected: { $0 == workspaceManager.redisDatabase },
        onSelect: { workspaceManager.redisDatabaseChoice = $0 }
      )
      .help("The database index the commands run in")

      Button(action: run) {
        Label("Run", systemImage: "play.fill")
      }
      .buttonStyle(PrimaryButtonStyle(vPadding: Spacing.xs))
      .disabled(!canRun)
      .help("Run the selected commands, else the caret's line (⌘↩)")

      Button(action: runAll) {
        Label("Run All", systemImage: "forward.fill")
      }
      .buttonStyle(SecondaryButtonStyle(vPadding: Spacing.xs))
      .disabled(!canRun)
      .help("Run every command")

      Button(action: { Task { await runner.cancel() } }) {
        Label("Cancel", systemImage: "stop.fill")
      }
      .buttonStyle(SecondaryButtonStyle(vPadding: Spacing.xs))
      .disabled(!runner.isRunning)
      .help("Stop the command in flight; the commands after it are not sent")

      Spacer(minLength: Spacing.sm)
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
  }

  /// 0–15, plus the current index when the connection's own is outside them
  private var databaseOptions: [Int] {
    var options = Array(ConnectionFormContent.redisDatabaseIndexes)
    if !options.contains(workspaceManager.redisDatabase) {
      options.append(workspaceManager.redisDatabase)
    }
    return options
  }

  // MARK: - Editor

  /// Width of the line number gutter, as in the SQL editor
  private var gutterWidth: CGFloat {
    let lineCount = viewModel.editorContent.utf8.reduce(1) { $1 == 10 ? $0 + 1 : $0 }
    let digits = max(String(lineCount).count, 2)
    let font = NSFont.monospacedSystemFont(
      ofSize: AppSettings.editorGutterFontSize(for: appSettings.editorFontSize), weight: .regular)
    let digitWidth = ceil(("0" as NSString).size(withAttributes: [.font: font]).width)
    return CGFloat(digits) * digitWidth + 16
  }

  private func editor(height: CGFloat) -> some View {
    HStack(spacing: 0) {
      if appSettings.showLineNumbers {
        LineNumberGutterView(
          text: viewModel.editorContent, textView: textViewRef, gutterWidth: gutterWidth,
          editorFontSize: appSettings.editorFontSize
        )
        .frame(width: gutterWidth, height: height)
      }
      SQLEditorView(
        content: $viewModel.editorContent,
        isSelected: true,
        isFocused: isFocused,
        onFocus: { isFocused = true },
        onTextChanged: { viewModel.onDocumentChanged?() },
        textViewRef: $textViewRef,
        autocompleteProvider: viewModel.autocompleteProvider,
        viewModelId: viewModel.id,
        maxHeight: height - Spacing.sm * 2,
        isEditorMode: true,
        wordWrapEnabled: appSettings.wordWrapEnabled,
        dialect: .redis,
        inlineCompletion: nil
      )
    }
    .background(Color.inputBackground)
    .frame(height: height)
  }

  // MARK: - Results

  @ViewBuilder
  private var results: some View {
    VStack(spacing: 0) {
      if let message = runner.message {
        RedisRunMessage(message: message)
      }
      if runner.results.isEmpty {
        if runner.isRunning {
          RedisRunningPlaceholder()
        } else {
          Text("Run a command to see its reply")
            .font(.small)
            .foregroundColor(.foregroundMuted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      } else if runner.results.count == 1, let only = runner.results.first {
        RedisResultCard(result: only, fillsHeight: true)
          .padding(Spacing.sm)
      } else {
        ScrollView {
          LazyVStack(spacing: Spacing.sm) {
            ForEach(runner.results) { result in
              RedisResultCard(result: result, fillsHeight: false)
            }
            if runner.isRunning {
              RedisRunningPlaceholder().frame(height: 60)
            }
          }
          .padding(Spacing.sm)
        }
      }
    }
  }

  // MARK: - Actions

  private func run() {
    guard canRun else { return }
    let text = viewModel.editorContent
    let selection = textViewRef?.selectedRange() ?? NSRange(location: 0, length: 0)
    Task { await runner.run(text: text, selection: selection) }
  }

  private func runAll() {
    guard canRun else { return }
    let text = viewModel.editorContent
    Task { await runner.runAll(text: text) }
  }

  // MARK: - Confirmation text

  static func title(of confirmation: RedisCommandRunner.Confirmation) -> String {
    let count = confirmation.commands.count
    let commands = count == 1 ? "1 command" : "\(count) commands"
    return "Run \(commands) in db \(confirmation.database)?"
  }

  /// The commands that asked, redacted, one per line, at most `maxListedCommands`
  static func listedText(of confirmation: RedisCommandRunner.Confirmation) -> String {
    let listed = confirmation.listed
    var lines = listed.prefix(maxListedCommands).map { "Line \($0.line): \($0.text)" }
    if listed.count > maxListedCommands {
      lines.append("and \(listed.count - maxListedCommands) more")
    }
    return lines.joined(separator: "\n")
  }
}

// MARK: - Confirm sheet

/// The Safe Mode panel (password or Touch ID, as the commit style asks) over the commands that
/// asked. A late Touch ID answer after the sheet closed sends nothing (`isPending`).
private struct RedisConfirmSheet: View {
  let runner: RedisCommandRunner
  let confirmation: RedisCommandRunner.Confirmation
  /// For the Safe Mode "Forgot Password?" fallback
  let databasePassword: String?
  let isConnected: Bool

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: Spacing.sm) {
        Text(verbatim: RedisCommandTabView.title(of: confirmation))
          .font(.subheading)
          .foregroundColor(.foreground)
        Spacer()
        Button(action: close) {
          Image(systemName: "xmark")
            .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(GhostButtonStyle(iconOnly: true))
        .keyboardShortcut(.cancelAction)
        .help("Close")
      }
      .modalBarPadding(vertical: Spacing.sm)
      Divider()
      SafeModeConfirmationPanel(
        requiresPassword: confirmation.requiresPassword, confirmTitle: "Run",
        biometricReason: "Authorize the Redis commands in Safe Mode",
        databasePassword: databasePassword, isConnected: isConnected,
        isPending: { [runner, confirmation] in runner.pendingConfirmation?.id == confirmation.id },
        onCancel: close,
        onConfirm: { [runner, confirmation] in await runner.confirm(confirmation) },
        details: {
          Text(verbatim: RedisCommandTabView.listedText(of: confirmation))
            .font(.mono)
            .foregroundColor(.foreground)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        })
    }
    .frame(width: 520)
    .background(Color.appBackground)
    // Closed any other way: nothing is sent
    .onDisappear {
      if runner.pendingConfirmation?.id == confirmation.id { runner.cancelConfirmation() }
    }
  }

  private func close() {
    runner.cancelConfirmation()
    dismiss()
  }
}

// MARK: - Result card

/// One sent command: its line, redacted text and time, then its reply (Grid / Raw), the rows of
/// a reply cut short under the banner, or why it failed
private struct RedisResultCard: View {
  let result: RedisCommandRunner.CommandResult
  /// The only result: the reply takes the whole pane; stacked cards get a height from the reply
  let fillsHeight: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Rectangle().fill(Color.border).frame(height: 1)
      content
    }
    .frame(maxHeight: fillsHeight ? .infinity : nil, alignment: .top)
    .background(Color.appBackground)
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
    .overlay(HairlineBorder(shape: RoundedRectangle(cornerRadius: CornerRadius.md)))
  }

  private var header: some View {
    HStack(spacing: Spacing.sm) {
      Text(verbatim: "Line \(result.line)")
        .font(.small)
        .foregroundColor(.foregroundMuted)
      Text(verbatim: result.text)
        .font(.monoMedium)
        .foregroundColor(.foreground)
        .lineLimit(1)
        .truncationMode(.tail)
        .help(result.text)
      Spacer(minLength: Spacing.sm)
      Text(verbatim: Self.elapsedText(result.elapsed))
        .font(.small)
        .foregroundColor(.foregroundMuted)
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.xs)
    .background(Color.controlBackground)
  }

  @ViewBuilder
  private var content: some View {
    switch result.outcome {
    case .reply(let reply):
      RedisReplyView(input: .reply(reply), stamp: result.id)
        .equatable()
        .frame(height: fillsHeight ? nil : Self.height(of: reply))
    case .truncated(let rows):
      RedisReplyView(
        input: .rows(rows), stamp: result.id,
        truncatedMessage: RedisCommandRunner.truncatedMessage
      )
      .equatable()
      .frame(height: fillsHeight ? nil : Self.aggregateHeight)
    case .failed(let reason):
      Text(verbatim: RedisDisplayText.lines(reason))
        .font(.monoMedium)
        .foregroundColor(.destructive)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.md)
    case .cancelled:
      Text("Cancelled")
        .font(.small)
        .foregroundColor(.foregroundMuted)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.md)
    }
  }

  /// Stacked card heights: a single value is one Grid row, a nested reply a scrolling list
  private static let leafHeight: CGFloat = 110
  private static let aggregateHeight: CGFloat = 300

  private static func height(of reply: RedisReply) -> CGFloat {
    switch reply {
    case .array, .set, .map, .push: aggregateHeight
    default: leafHeight
    }
  }

  private static func elapsedText(_ elapsed: TimeInterval) -> String {
    elapsed < 1
      ? "\(Int((elapsed * 1_000).rounded())) ms" : String(format: "%.2f s", elapsed)
  }
}

// MARK: - Message and placeholders

/// Why nothing (or not everything) was sent
private struct RedisRunMessage: View {
  let message: String

  var body: some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: "exclamationmark.circle.fill")
        .foregroundColor(.warning)
        .accessibilityHidden(true)
      Text(verbatim: RedisDisplayText.lines(message))
        .font(.small)
        .foregroundColor(.foreground)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .background(Color.controlBackground)
  }
}

/// Fills the reply's place while the first command runs; its spinner fades in after 150 ms, so
/// a fast command never flashes it
private struct RedisRunningPlaceholder: View {
  @State private var showsSpinner = false

  var body: some View {
    ProgressView()
      .controlSize(.small)
      .tint(.accent)
      .opacity(showsSpinner ? 1 : 0)
      .animation(.easeIn(duration: 0.15), value: showsSpinner)
      // Opt out of the app-wide animation kill switch, only for the fade
      .transaction(value: showsSpinner) { $0.disablesAnimations = false }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .task {
        try? await Task.sleep(for: .milliseconds(150))
        showsSpinner = true
      }
  }
}

// MARK: - Unavailable tab

/// In place of a notebook, data viewer or SQL source tab of a Redis workspace (left over from a
/// connection switch, or restored): none of them runs on Redis, so none is shown
struct RedisUnavailableTabView: View {
  let onNewCommand: () -> Void

  var body: some View {
    VStack(spacing: Spacing.md) {
      Image(systemName: "nosign")
        .font(.system(size: 28))
        .foregroundColor(.foregroundMuted)
        .accessibilityHidden(true)
      Text("Not available for Redis")
        .font(.subheading)
        .foregroundColor(.foreground)
      Text("Notebooks, table viewers and SQL editors don't run on a Redis connection.")
        .font(.small)
        .foregroundColor(.foregroundMuted)
        .multilineTextAlignment(.center)
      Button("New Command", action: onNewCommand)
        .buttonStyle(PrimaryButtonStyle())
    }
    .padding(Spacing.lg)
    .frame(maxWidth: 420)
    .background(Color.controlBackground)
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
    .overlay(HairlineBorder(shape: RoundedRectangle(cornerRadius: CornerRadius.md)))
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.appBackground)
  }
}
