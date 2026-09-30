//
//  AIAssistantPanel.swift
//  Dblore
//
//  Right-side chat panel for the AI SQL assistant
//

import AppKit
import SwiftUI

struct AIAssistantPanel: View {
  @Bindable var assistant: AIAssistantViewModel
  let activeTab: NotebookViewModel?
  let tables: [DatabaseTable]

  @FocusState private var composerFocused: Bool
  @State private var showHistory = false

  private static let examples = [
    "Top 10 customers by order total",
    "Which tables reference the users table?",
    "Rows created in the last 7 days",
  ]

  private static var isComposing: Bool {
    (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
  }

  private var currentSQL: String? { activeTab?.aiCurrentSQL }
  private var lastError: String? { activeTab?.aiLastError }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if assistant.needsSetup {
        setupState
      } else if assistant.messages.isEmpty {
        emptyState
      } else {
        messageList
      }
      Divider()
      footer
    }
    .frame(width: ComponentSize.sidebarWidth)
    .background(Color.appBackground)
    .overlay(alignment: .leading) {
      Rectangle().fill(Color.borderSubtle).frame(width: 1)
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: Spacing.xs) {
      Text("AI Assistant")
        .font(.subheading)
        .foregroundColor(.foreground)
      Spacer(minLength: Spacing.xs)
      Button {
        showHistory.toggle()
      } label: {
        Image(systemName: "clock.arrow.circlepath").foregroundColor(.foregroundMuted)
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .controlSize(.small)
      .help("Chat history")
      .popover(isPresented: $showHistory, arrowEdge: .bottom) {
        AIChatHistoryPopover(assistant: assistant)
      }
      Button {
        assistant.newChat()
        composerFocused = true
      } label: {
        Image(systemName: "square.and.pencil").foregroundColor(.foregroundMuted)
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .controlSize(.small)
      .disabled(assistant.messages.isEmpty)
      .help("New chat")
      Button {
        assistant.isVisible = false
      } label: {
        Image(systemName: "xmark").foregroundColor(.foregroundMuted)
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .controlSize(.small)
      .help("Close")
    }
    .padding(.horizontal, Spacing.md)
    .frame(height: ComponentSize.headerHeight)
  }

  private var configuredProviders: [AIProviderKind] {
    AIProviderKind.allCases.filter { assistant.settings.isConfigured($0) }
  }

  private func models(for kind: AIProviderKind) -> [String] {
    var list = kind.fallbackModels
    let current = assistant.settings.config(for: kind).model
    if !current.isEmpty, !list.contains(current) { list.insert(current, at: 0) }
    return list
  }

  private var modelMenu: some View {
    Menu {
      ForEach(configuredProviders, id: \.self) { kind in
        Section(kind.displayName) {
          ForEach(models(for: kind), id: \.self) { model in
            Button {
              assistant.providerOverride = kind
              assistant.modelOverride = model
            } label: {
              if kind == assistant.activeProvider && model == assistant.activeModel {
                Label(model, systemImage: "checkmark")
              } else {
                Text(model)
              }
            }
          }
        }
      }
    } label: {
      AIDropdownLabel(title: modelLabel, systemImage: "sparkles")
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    .disabled(configuredProviders.isEmpty)
    .linkPointer()
    .help("Model")
  }

  /// Model name only. Provider names stay inside the menu so a long label cannot overflow the sidebar.
  private var modelLabel: String {
    guard !assistant.needsSetup else { return "No provider" }
    let model = assistant.activeModel
    return model.isEmpty ? "Select model" : model
  }

  // MARK: - States

  private var setupState: some View {
    VStack(spacing: Spacing.md) {
      Image(systemName: "sparkles")
        .font(.heading)
        .foregroundColor(.foregroundMuted)
      Text("Set up an AI provider to ask questions about your database.")
        .font(.labelText)
        .foregroundColor(.foregroundMuted)
        .multilineTextAlignment(.center)
      Button("Set up a provider") {
        NotificationCenter.default.post(
          name: .openSettings,
          object: nil,
          userInfo: [SettingsPage.userInfoKey: SettingsPage.ai.rawValue]
        )
      }
      .buttonStyle(PrimaryButtonStyle())
    }
    .padding(Spacing.lg)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("Ask about your schema or describe a query. Suggestions are never run automatically.")
        .font(.labelText)
        .foregroundColor(.foregroundMuted)
      ForEach(Self.examples, id: \.self) { example in
        Button {
          assistant.draft = example
          composerFocused = true
        } label: {
          Text(example)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(AIChipButtonStyle())
      }
    }
    .padding(Spacing.md)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var messageList: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: Spacing.sm) {
          ForEach(assistant.messages) { entry in
            AIMessageView(
              entry: entry, placeholder: assistant.isLoadingModel ? "Loading model…" : "Thinking…",
              onInsert: insertHandler)
          }
          Color.clear.frame(height: 1).id(Self.bottomID)
        }
        .padding(Spacing.md)
      }
      .onAppear { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
      .onChange(of: assistant.messages.count) { _, _ in
        proxy.scrollTo(Self.bottomID, anchor: .bottom)
      }
      .onChange(of: assistant.messages.last?.text) { _, _ in
        proxy.scrollTo(Self.bottomID, anchor: .bottom)
      }
    }
  }

  private static let bottomID = "ai-bottom"

  private var insertHandler: ((String) -> Void)? {
    guard let activeTab else { return nil }
    return { activeTab.insertAISQL($0) }
  }

  // MARK: - Footer

  private var canExplain: Bool {
    currentSQL != nil && !assistant.needsSetup
  }

  private var canFixError: Bool {
    currentSQL != nil && lastError != nil && !assistant.needsSetup
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      if canExplain || canFixError {
        quickActions
      }
      AIContextPicker(
        selected: $assistant.selectedTableNames,
        tables: tables,
        onColumn: { column in
          let separator = assistant.draft.isEmpty || assistant.draft.hasSuffix(" ") ? "" : " "
          assistant.draft += separator + column + " "
          composerFocused = true
        }
      ) {
        modelMenu
      }
      inputRow
    }
    .padding(Spacing.md)
  }

  private var quickActions: some View {
    HStack(spacing: Spacing.xs) {
      if canExplain {
        Button("Explain query") {
          if let sql = currentSQL { assistant.explain(sql: sql) }
        }
        .buttonStyle(AIChipButtonStyle())
        .disabled(assistant.isGenerating)
      }
      if canFixError {
        Button("Fix error") {
          if let sql = currentSQL, let error = lastError {
            assistant.fixError(sql: sql, error: error)
          }
        }
        .buttonStyle(AIChipButtonStyle())
        .disabled(assistant.isGenerating)
      }
    }
  }

  private var inputRow: some View {
    HStack(alignment: .bottom, spacing: Spacing.sm) {
      TextField("Ask about your database", text: $assistant.draft, axis: .vertical)
        .textFieldStyle(.plain)
        .font(.bodyText)
        .foregroundColor(.foreground)
        .lineLimit(1...6)
        .focused($composerFocused)
        .disabled(assistant.needsSetup)
        .onKeyPress(.return, phases: .down) { press in
          // Never send or insert while an IME composition is in progress
          guard !Self.isComposing else { return .ignored }
          if press.modifiers.contains(.shift) {
            insertComposerNewline()
            return .handled
          }
          assistant.send()
          return .handled
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xsm)
        .background(Color.inputBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
        .overlay(
          RoundedRectangle(cornerRadius: CornerRadius.md)
            .stroke(composerFocused ? Color.borderFocus : Color.borderSubtle, lineWidth: 1)
        )

      if assistant.isGenerating {
        Button {
          assistant.stop()
        } label: {
          Image(systemName: "stop.fill")
        }
        .buttonStyle(FilledSecondaryButtonStyle(iconOnly: true))
        .help("Stop")
      } else {
        Button {
          assistant.send()
        } label: {
          Image(systemName: "arrow.up")
        }
        .buttonStyle(PrimaryButtonStyle(iconOnly: true))
        .disabled(
          assistant.needsSetup
            || assistant.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        .help("Send (Return). New line (Shift+Return)")
      }
    }
  }

  /// Shift+Return does not insert a newline in the macOS text field, so place one at the caret.
  private func insertComposerNewline() {
    guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else {
      assistant.draft.append("\n")
      return
    }
    textView.insertText("\n", replacementRange: textView.selectedRange())
  }
}

#Preview("AIAssistantPanel") {
  let assistant = AIAssistantViewModel()
  assistant.messages = [
    AIChatEntry(id: UUID(), role: .user, text: "Top customers", isError: false),
    AIChatEntry(
      id: UUID(), role: .assistant,
      text: "Try:\n```sql\nSELECT * FROM customers LIMIT 10;\n```", isError: false),
  ]
  return AIAssistantPanel(
    assistant: assistant, activeTab: nil,
    tables: [DatabaseTable(schema: "public", name: "customers")]
  )
  .frame(height: 560)
}
