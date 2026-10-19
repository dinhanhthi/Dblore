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
  /// Shown as the bubble card instead of the docked sidebar column
  var isFloating = false
  /// Column width (sidebar) or card width (bubble)
  var width: CGFloat = ComponentSize.sidebarWidth

  @FocusState private var composerFocused: Bool
  @State private var composerIsMultiline = false
  @State private var composerTextHeight: CGFloat = 0
  @State private var showHistory = false
  @State private var retryEntryId: UUID?

  private var isMongo: Bool { assistant.sqlDialect == .mongodb }

  private static var isComposing: Bool {
    (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
  }

  private var currentSQL: String? { activeTab?.aiCurrentSQL }
  private var lastError: String? { activeTab?.aiLastError }

  /// Qualified name of the table shown in the active data viewer, if it is a known table
  private var viewerTableName: String? {
    guard let viewer = activeTab?.dataViewer else { return nil }
    return tables.first { $0.schema == viewer.schema && $0.name == viewer.name }?.qualifiedName
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      if isFloating {
        // Follows the foreground so it stays visible on the tinted bubble: lighter in dark, darker in light
        Rectangle().fill(Color.foreground.opacity(0.2)).frame(height: 1)
      }
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
    .frame(width: width)
    .background(background)
    .overlay(alignment: .leading) {
      if !isFloating {
        Rectangle()
          .fill(
            LinearGradient(
              colors: [Color.accent.opacity(0.7), Color.accent.opacity(0.25), Color.border],
              startPoint: .top, endPoint: .bottom)
          )
          .frame(width: 1)
      }
    }
    .onAppear { assistant.attachViewerTable(viewerTableName) }
    .onChange(of: viewerTableName) { _, name in assistant.attachViewerTable(name) }
    // Only detach when the assistant is hidden: on a mode switch the outgoing panel disappears
    // after the incoming one appeared (its onAppear was a no-op), so detaching would drop the table
    .onDisappear { if !assistant.isVisible { assistant.attachViewerTable(nil) } }
  }

  /// Accent glow from the top so the panel reads as the AI surface, fading out before the messages
  private var background: some View {
    ZStack {
      Color.appBackground
      LinearGradient(
        colors: [Color.accent.opacity(0.10), .clear],
        startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.45))
      RadialGradient(
        colors: [Color.accent.opacity(0.16), .clear],
        center: .topTrailing, startRadius: 0, endRadius: width * 1.1)
    }
  }

  // MARK: - Header

  private var isBubble: Bool { assistant.presentation == .bubble }

  private var header: some View {
    HStack(spacing: Spacing.xs) {
      Image(systemName: "sparkles")
        .font(.subheading)
        .foregroundStyle(
          LinearGradient(
            colors: [Color.accent, Color.accent.opacity(0.55)],
            startPoint: .topLeading, endPoint: .bottomTrailing))
      Text("AI Assistant")
        .font(.subheading)
        .foregroundColor(.foreground)
      Spacer(minLength: Spacing.xs)
      Button {
        NotificationCenter.default.post(
          name: .openSettings,
          object: nil,
          userInfo: [SettingsPage.userInfoKey: SettingsPage.ai.rawValue]
        )
      } label: {
        Image(systemName: "gearshape").foregroundColor(.foregroundMuted)
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .controlSize(.small)
      .help("AI settings")
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
        withSidebarAnimation(SidebarAnimation.bubble) { assistant.togglePresentation() }
      } label: {
        Image(systemName: isBubble ? "sidebar.right" : "pip.enter")
          .foregroundColor(.foregroundMuted)
          .contentTransition(.symbolEffect(.replace))
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .controlSize(.small)
      .help(isBubble ? "Attach to sidebar" : "Detach as bubble")
      Button {
        if isBubble {
          withSidebarAnimation(SidebarAnimation.bubble) { assistant.collapseBubble() }
        } else {
          withSidebarAnimation { assistant.hide() }
        }
      } label: {
        Image(systemName: "xmark").foregroundColor(.foregroundMuted)
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .controlSize(.small)
      .help(isBubble ? "Collapse" : "Close")
    }
    .padding(.horizontal, Spacing.md)
    // Matches the tab bar so the workspace's full-width tab bar border doubles as this divider
    .frame(height: ComponentSize.tabBarHeight)
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
            // Toggle renders the native menu checkmark on the active model
            Toggle(
              model,
              isOn: Binding(
                get: { kind == assistant.activeProvider && model == assistant.activeModel },
                set: { _ in
                  assistant.providerOverride = kind
                  assistant.modelOverride = model
                }))
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
    Text(emptyStateText)
      .font(.labelText)
      .foregroundColor(.foregroundMuted)
      .multilineTextAlignment(.center)
      .padding(Spacing.xl)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// Discloses whether read-only queries run
  private var emptyStateText: String {
    let intro =
      isMongo
      ? "Ask about your collections or describe a query."
      : "Ask about your schema or describe a query."
    guard assistant.settings.configuration.runsQueries else {
      return intro + " Suggestions are never run automatically."
    }
    return intro
      + " Read-only queries run automatically; results are shown only to you."
      + (isMongo
        ? " Ask for the command to get it without running."
        : " Ask for the SQL to get it without running.")
  }

  private var messageList: some View {
    let dialect = assistant.sqlDialect
    let messages = assistant.messages
    return ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: Spacing.sm) {
          ForEach(Array(messages.enumerated()), id: \.element.id) { index, entry in
            AIMessageView(
              entry: entry, placeholder: assistant.isLoadingModel ? "Loading model…" : "Thinking…",
              onInsert: insertHandler, dialect: dialect,
              onRetry: canRetry(entry) ? { retryEntryId = entry.id } : nil,
              onEdit: canRetry(entry)
                ? { assistant.retry(from: entry.id, editedText: $0) } : nil,
              firstRunLabel: firstRunLabel(after: index, in: messages),
              mongoCollection: activeTab?.mongoCollection?.collection,
              onMongoAction: mongoActionHandler)
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
      .alert(
        "Try again?",
        isPresented: Binding(
          get: { retryEntryId != nil }, set: { if !$0 { retryEntryId = nil } })
      ) {
        Button("Try again") {
          if let id = retryEntryId { assistant.retry(from: id) }
          retryEntryId = nil
        }
        Button("Cancel", role: .cancel) { retryEntryId = nil }
      } message: {
        Text(
          "Messages after this one will be removed and the answer regenerated with your current settings."
        )
      }
    }
  }

  private static let bottomID = "ai-bottom"

  /// Label of the first run block of the entry at `index`, from the next entry: "Ran" for its
  /// running placeholder or result, "Failed" for a database error, else "Not run". nil while
  /// that entry is still streaming (not decided yet).
  private func firstRunLabel(after index: Int, in messages: [AIChatEntry]) -> String? {
    let next = messages.indices.contains(index + 1) ? messages[index + 1] : nil
    if next == nil, assistant.isGenerating { return nil }
    if next?.queryResult != nil || next?.isRunning == true { return "Ran" }
    return next?.queryOutcome == .failed ? "Failed" : "Not run"
  }

  /// Only the user's own messages can be restarted from, and not while a reply is streaming
  private func canRetry(_ entry: AIChatEntry) -> Bool {
    entry.role == .user && !assistant.isGenerating
  }

  private var insertHandler: ((String) -> Void)? {
    guard let activeTab else { return nil }
    return { activeTab.insertAISQL($0) }
  }

  /// Fills the filter bar or the Aggregations builder of the viewed collection (never runs)
  private var mongoActionHandler: ((AIMongoAssist.BlockAction) -> Void)? {
    guard let model = activeTab?.mongoCollection else { return nil }
    return { action in
      switch action {
      case .insertFilter(let text): model.insertFilterDraft(text)
      case .generateAggregation(let stages): model.showGeneratedPipeline(stages)
      }
    }
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
      if activeTab?.isReadOnlySource == true, !assistant.needsSetup {
        readOnlySourceQuickActions
      } else if canExplain || canFixError {
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
        AIRunQueriesToggle(isOn: Bindable(assistant.settings).configuration.runsQueries)
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

  /// Source tab: its text comes from the server and never goes into a prompt
  private var readOnlySourceQuickActions: some View {
    VStack(alignment: .leading, spacing: Spacing.xxs) {
      HStack(spacing: Spacing.xs) {
        Button("Explain query") {}
          .buttonStyle(AIChipButtonStyle())
        Button("Fix error") {}
          .buttonStyle(AIChipButtonStyle())
      }
      .disabled(true)
      Text("Not available for read-only source — open an editable copy")
        .font(.small)
        .foregroundColor(.foregroundMuted)
    }
  }

  /// Full capsule for one line, a modest radius once the text wraps or grows
  private var composerShape: RoundedRectangle {
    RoundedRectangle(
      cornerRadius: composerIsMultiline ? CornerRadius.xl : 100, style: .continuous)
  }

  private static let composerSingleLineMaxHeight: CGFloat = 36
  /// About 6 lines of body text; beyond this the composer scrolls
  private static let composerMaxTextHeight: CGFloat = 110

  private var inputRow: some View {
    HStack(alignment: .bottom, spacing: Spacing.sm) {
      ScrollView(.vertical) {
        TextField("Ask about your database", text: $assistant.draft, axis: .vertical)
          .textFieldStyle(.plain)
          .font(.bodyText)
          .foregroundColor(.foreground)
          // Horizontal padding lives inside the scroll view so the scroller hugs the border
          .padding(.horizontal, Spacing.md)
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
          .background(
            GeometryReader { proxy in
              Color.clear.onChange(of: proxy.size.height, initial: true) { _, height in
                composerTextHeight = height
              }
            }
          )
      }
      .scrollIndicators(.hidden)
      .frame(height: min(composerTextHeight, Self.composerMaxTextHeight))
      .padding(.vertical, Spacing.xsm)
      .background(
        GeometryReader { proxy in
          Color.clear.onChange(of: proxy.size.height, initial: true) { _, height in
            composerIsMultiline = height > Self.composerSingleLineMaxHeight
          }
        }
      )
      .background(Color.inputBackground)
      .clipShape(composerShape)
      .overlay(
        HairlineBorder(shape: composerShape, color: composerFocused ? .borderFocus : .border)
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

/// "Run read-only queries" on/off, an icon chip of the chat input row: accent-tinted when on
struct AIRunQueriesToggle: View {
  @Binding var isOn: Bool

  var body: some View {
    Button {
      isOn.toggle()
    } label: {
      Image(systemName: isOn ? "bolt.fill" : "bolt.slash")
        .font(.system(size: 11))
        .foregroundColor(isOn ? .accent : .foregroundSubtle)
        // Same width on and off, so the row does not shift when it is toggled
        .frame(width: 30, height: 26)
        .background(isOn ? Color.selectionFill : Color.inputBackground)
        .clipShape(Capsule())
        .overlay(HairlineBorder(shape: Capsule(), color: isOn ? .accent : .border))
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .fixedSize()
    .linkPointer()
    .help("Run read-only queries: \(isOn ? "On" : "Off") — results are shown only to you")
    .accessibilityLabel("Run read-only queries")
    .accessibilityValue(isOn ? "On" : "Off")
    .accessibilityAddTraits(.isToggle)
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
