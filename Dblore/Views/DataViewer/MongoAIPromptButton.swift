//
//  MongoAIPromptButton.swift
//  Dblore
//
//  Sparkles button opening a small AI prompt popover on MongoDB collection screens. The caller's
//  `generate` turns the prompt into a filter or pipeline; errors stay inline in the popover.
//  The connection's AI access is asked on open and on Apply: a connection that needs approval
//  shows Allow for this session / Not now, an off one says so, and nothing is sent.
//  `MongoAIPipelineButton` is the builder's preset (Aggregations section and builder sheet).
//

import SwiftUI

struct MongoAIPromptButton: View {
  let assistant: AIAssistantViewModel
  let placeholder: String
  let help: String
  let generate: @MainActor (String) async throws -> Void

  @State private var isPresented = false
  @State private var prompt = ""
  @State private var isBusy = false
  @State private var error: String?
  @State private var task: Task<Void, Never>?
  /// The gate's answer, read on open and on Apply (never from the body)
  @State private var access: AIAssistantViewModel.AccessCheck?

  var body: some View {
    Button(action: {
      if !isPresented { access = assistant.aiAccessCheck() }
      isPresented.toggle()
    }) {
      Image(systemName: "sparkles")
    }
    .buttonStyle(SecondaryButtonStyle(iconOnly: true))
    .help(help)
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      MongoAIPromptPopover(
        needsSetup: assistant.needsSetup,
        approvalName: access?.decision == .needsApproval
          ? access?.context.map { AIAssistantViewModel.connectionName($0.config) } : nil,
        isPrivate: access?.decision == .denied,
        placeholder: placeholder,
        prompt: $prompt,
        isBusy: isBusy,
        error: error,
        apply: apply,
        stop: stop,
        allow: allow,
        notNow: { isPresented = false },
        openSettings: openSettings
      )
      .onDisappear { stop() }
    }
  }

  private func apply() {
    let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !isBusy else { return }
    access = assistant.aiAccessCheck()
    guard access?.decision == .allowed else { return }
    isBusy = true
    error = nil
    task = Task {
      do {
        try await generate(text)
        try Task.checkCancellation()
        isPresented = false
        prompt = ""
      } catch {
        // A stop is not an error, even when the client throws its own error on cancel
        if !(error is CancellationError), !Task.isCancelled {
          self.error = error.localizedDescription
        }
      }
      // Stopped: `stop()` already reset the state, and a newer Apply may own `task` by now
      guard !Task.isCancelled else { return }
      isBusy = false
      task = nil
    }
  }

  private func allow() {
    guard let context = access?.context else { return }
    assistant.approveForSession(context)
    access = assistant.aiAccessCheck()
  }

  private func stop() {
    task?.cancel()
    task = nil
    isBusy = false
  }

  private func openSettings() {
    NotificationCenter.default.post(
      name: .openSettings,
      object: nil,
      userInfo: [SettingsPage.userInfoKey: SettingsPage.ai.rawValue]
    )
    isPresented = false
  }
}

/// Popover body: its own view so the prompt field's focus lives in the popover's hierarchy
private struct MongoAIPromptPopover: View {
  let needsSetup: Bool
  /// The connection waiting for "Allow for this session"; nil when none
  let approvalName: String?
  /// AI access is off for the connection
  let isPrivate: Bool
  let placeholder: String
  @Binding var prompt: String
  let isBusy: Bool
  let error: String?
  let apply: () -> Void
  let stop: () -> Void
  let allow: () -> Void
  let notNow: () -> Void
  let openSettings: () -> Void

  @FocusState private var promptFocused: Bool

  private var isBlank: Bool {
    prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      if needsSetup {
        Text("Set up an AI provider to use this.")
          .font(.small)
          .foregroundColor(.foregroundMuted)
        Button("Set up AI in Settings", action: openSettings)
          .buttonStyle(PrimaryButtonStyle())
      } else if isPrivate {
        Text("AI access is off for this connection.")
          .font(.small)
          .foregroundColor(.foregroundMuted)
      } else if let approvalName {
        Text("AI needs your approval to use \(approvalName).")
          .font(.small)
          .foregroundColor(.foreground)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: Spacing.xs) {
          Spacer()
          Button("Not now", action: notNow)
            .buttonStyle(GhostButtonStyle())
          Button("Allow for this session", action: allow)
            .buttonStyle(PrimaryButtonStyle())
        }
      } else {
        // A popover keeps the size it opened with: reserve the 3 lines up front, scroll past them
        TextField(placeholder, text: $prompt, axis: .vertical)
          .textFieldStyle(.plain)
          .lineLimit(3, reservesSpace: true)
          .focused($promptFocused)
          .onSubmit(apply)
          .inputStyle(onPopover: true)
        if let error {
          Text(error)
            .font(.small)
            .foregroundColor(.destructive)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: Spacing.xs) {
          Spacer()
          if isBusy {
            ProgressView().controlSize(.small)
            Button("Stop", action: stop)
              .buttonStyle(GhostButtonStyle())
          }
          Button("Apply", action: apply)
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isBlank || isBusy)
        }
      }
    }
    .popoverContentPadding()
    .frame(width: 360, alignment: .leading)
    .onAppear { promptFocused = true }
  }
}

/// The AI button of an aggregation builder: replaces its stages with the pipeline generated from
/// the prompt, its enabled stages sent as the current pipeline. Runs nothing (previews stay
/// manual).
struct MongoAIPipelineButton: View {
  let assistant: AIAssistantViewModel
  let builder: AggregationBuilderModel
  /// Database of the collection; nil matches the collection's schema by name only
  var database: String? = nil

  var body: some View {
    MongoAIPromptButton(
      assistant: assistant,
      placeholder: "Describe the pipeline, or paste a query (e.g. SQL)",
      help: "Build the pipeline with AI"
    ) { prompt in
      let current = AIMongoAssist.pipelineText(
        builder.stages.filter(\.isEnabled).map {
          AIMongoAssist.GeneratedStage(operator: $0.operator, body: $0.body)
        })
      let reply = try await assistant.mongoAssist(
        .pipeline, prompt: prompt, database: database, collection: builder.collection,
        current: current)
      builder.replaceStages(
        try AIMongoAssist.stages(fromReply: reply, collection: builder.collection))
    }
  }
}
