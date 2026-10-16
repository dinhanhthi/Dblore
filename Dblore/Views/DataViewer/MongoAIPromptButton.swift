//
//  MongoAIPromptButton.swift
//  Dblore
//
//  Sparkles button opening a small AI prompt popover on MongoDB collection screens. The caller's
//  `generate` turns the prompt into a filter or pipeline; errors stay inline in the popover.
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

  var body: some View {
    Button(action: { isPresented.toggle() }) {
      Image(systemName: "sparkles")
        .foregroundColor(.foregroundMuted)
    }
    .buttonStyle(GhostButtonStyle(iconOnly: true))
    .help(help)
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      MongoAIPromptPopover(
        needsSetup: assistant.needsSetup,
        placeholder: placeholder,
        prompt: $prompt,
        isBusy: isBusy,
        error: error,
        apply: apply,
        stop: stop,
        openSettings: openSettings
      )
      .onDisappear { stop() }
    }
  }

  private func apply() {
    let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !isBusy else { return }
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
  let placeholder: String
  @Binding var prompt: String
  let isBusy: Bool
  let error: String?
  let apply: () -> Void
  let stop: () -> Void
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
      } else {
        TextField(placeholder, text: $prompt, axis: .vertical)
          .textFieldStyle(.plain)
          .lineLimit(1...4)
          .focused($promptFocused)
          .onSubmit(apply)
          .inputStyle()
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
    .padding(Spacing.md)
    .frame(width: 360, alignment: .leading)
    .onAppear { promptFocused = true }
  }
}
