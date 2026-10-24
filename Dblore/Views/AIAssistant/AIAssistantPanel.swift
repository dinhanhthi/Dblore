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
  /// What the composer popup lists for the `/` or `@` token at the end of the draft
  @State private var suggestions: [AIComposerSuggestions.Item] = []
  @State private var selectedSuggestion = 0
  /// Start of the token Esc closed the popup on: it stays closed until another token starts
  @State private var dismissedSuggestionStart: Int?
  /// Why the last slash command did nothing or left placeholders empty, shown while the draft is
  /// the one it left
  @State private var commandNote: (text: String, draft: String)?

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
      VStack(spacing: 0) {
        if assistant.needsSetup {
          setupState
        } else if assistant.messages.isEmpty {
          emptyState
        } else {
          messageList
        }
      }
      // Pinned to the bottom of the messages, so it grows upward above the whole footer
      // (composer, chips and notes stay visible) and never leaves the panel
      .overlay(alignment: .bottom) {
        if showsSuggestions {
          AIComposerSuggestionPopup(
            items: suggestions, selected: selectedSuggestion, onPick: pickSuggestion(at:)
          )
          .frame(maxHeight: Self.suggestionsMaxHeight, alignment: .bottom)
          .padding(.horizontal, Spacing.md)
          .padding(.vertical, Spacing.xs)
        }
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
    .onDisappear {
      if !assistant.isVisible { assistant.attachViewerTable(nil) }
      assistant.composerSuggestionsShown = false
    }
    .onChange(of: showsSuggestions, initial: true) { _, shows in
      assistant.composerSuggestionsShown = shows
    }
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

  /// On-device is the provider in use and its plugin is missing. Read in `body`, so the setup
  /// card follows install and remove in Settings > Plugins.
  private var isOnDevicePluginMissing: Bool {
    assistant.activeProvider == .localMLX && !assistant.settings.localRuntimeInstalled()
  }

  private var setupState: some View {
    let pluginMissing = isOnDevicePluginMissing
    return VStack(spacing: Spacing.md) {
      Image(systemName: "sparkles")
        .font(.heading)
        .foregroundColor(.foregroundMuted)
      if pluginMissing {
        Text("On-device AI plugin not installed")
          .font(.labelText)
          .fontWeight(.medium)
          .foregroundColor(.foreground)
          .multilineTextAlignment(.center)
        Text("On-device models run through the On-device AI plugin. Install it to use them.")
          .font(.labelText)
          .foregroundColor(.foregroundMuted)
          .multilineTextAlignment(.center)
        // Same Install action as the DuckDB missing-plugin rows: opens Settings > Plugins
        Button("Install…", action: ConnectionErrorAction.postOpenPluginSettings)
          .buttonStyle(PrimaryButtonStyle())
      } else {
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
              onMongoAction: mongoActionHandler,
              isStreaming: assistant.isGenerating && index == messages.count - 1,
              onApplyReview: reviewApplyHandler,
              onRunProposal: assistant.proposalRunner,
              onDecideOutsideCall: assistant.isAwaitingOutsideApproval(entry.id)
                ? { assistant.decideOutsideCall(entry.id, approved: $0) } : nil,
              outsideRunEnabled: assistant.isOutsideRunEnabled(entry.id))
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

  private var reviewApplyHandler:
    ((AIReviewRequest, String) -> NotebookViewModel.AIReviewApplyResult)?
  {
    guard let activeTab else { return nil }
    return { activeTab.applyAIReview($0, sql: $1) }
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

  private var canReview: Bool {
    !assistant.needsSetup
      && AIAssistantViewModel.offersReview(in: activeTab, dialect: assistant.sqlDialect)
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      if let pending = assistant.pendingApproval {
        approvalPrompt(pending)
      } else if let note = assistant.privateNote {
        Label(Self.privateNoteText(note), systemImage: "lock")
          .font(.small)
          .foregroundColor(.foregroundMuted)
      } else if let commandNote, commandNote.draft == assistant.draft {
        Label(commandNote.text, systemImage: "info.circle")
          .font(.small)
          .foregroundColor(.foregroundMuted)
      }
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

  private static func privateNoteText(_ note: AIAssistantViewModel.PrivateNote) -> String {
    switch note {
    case .messageOnly:
      "This connection is private to AI: only your new message is sent, without schema or "
        + "earlier messages."
    case .draftHeld:
      "This draft holds query or error text from a connection that is private to AI. "
        + "Clear it to ask a general question."
    case .draftFromOtherConnection:
      "This draft holds query or error text from another connection, so it was not sent. "
        + "Clear it to ask about this connection."
    case .retryHeld:
      "Retry is off while this connection is private to AI. Type a new question instead."
    }
  }

  private var quickActions: some View {
    AIFlowLayout(spacing: Spacing.xs) {
      if canExplain {
        Button("Explain query") {
          if let sql = currentSQL {
            assistant.explain(sql: sql, sessionKey: activeTab?.aiSessionKey)
          }
        }
        .buttonStyle(AIChipButtonStyle())
        .disabled(assistant.isGenerating)
      }
      if canFixError {
        Button("Fix error") {
          if let sql = currentSQL, let error = lastError {
            // `aiLastError` only offers an error stamped with the tab's key
            assistant.fixError(sql: sql, error: error, sessionKey: activeTab?.aiSessionKey)
          }
        }
        .buttonStyle(AIChipButtonStyle())
        .disabled(assistant.isGenerating)
      }
      if canReview, let activeTab {
        Button("Review query") { assistant.review(.review, in: activeTab) }
          .buttonStyle(AIChipButtonStyle())
          .disabled(assistant.isGenerating)
        Button("Optimize query") { assistant.review(.optimize, in: activeTab) }
          .buttonStyle(AIChipButtonStyle())
          .disabled(assistant.isGenerating)
      }
    }
  }

  /// Nothing is sent until the user allows the connection for this session
  private func approvalPrompt(_ pending: AIAssistantViewModel.PendingApproval) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text("Allow AI for \(pending.connectionName) this session?")
        .font(.small)
        .foregroundColor(.foreground)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: Spacing.xs) {
        Spacer()
        Button("Not now") { assistant.dismissPendingTurn() }
          .buttonStyle(GhostButtonStyle())
        Button("Allow") { assistant.allowPendingTurn() }
          .buttonStyle(PrimaryButtonStyle())
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
            if showsSuggestions {
              pickSuggestion(at: selectedSuggestion)
            } else {
              submit()
            }
            return .handled
          }
          .onKeyPress(keys: [.upArrow, .downArrow, .tab, .escape], phases: .down) { press in
            guard showsSuggestions, !Self.isComposing else { return .ignored }
            let count = suggestions.count
            switch press.key {
            case .upArrow: selectedSuggestion = (selectedSuggestion + count - 1) % count
            case .downArrow: selectedSuggestion = (selectedSuggestion + 1) % count
            case .escape: dismissSuggestions()
            default: pickSuggestion(at: selectedSuggestion)
            }
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
      .onChange(of: assistant.draft, initial: true) { _, _ in refreshSuggestions() }

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
          submit()
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

  // MARK: - Composer suggestions and slash commands

  /// Past it the popup scrolls; the space above the footer can cut it shorter
  private static let suggestionsMaxHeight: CGFloat = 240

  private var showsSuggestions: Bool {
    composerFocused && !suggestions.isEmpty && !assistant.needsSetup
  }

  /// Reads the command, table and favorite lists only while a token needs them
  private func refreshSuggestions() {
    if commandNote?.draft != assistant.draft { commandNote = nil }
    let token = AIComposerSuggestions.token(in: assistant.draft)
    if token?.start != dismissedSuggestionStart { dismissedSuggestionStart = nil }
    var items: [AIComposerSuggestions.Item] = []
    if let token, dismissedSuggestionStart == nil {
      items = AIComposerSuggestions.items(
        for: token,
        commands: AISlashCommand.available(
          custom: assistant.settings.configuration.customCommands, dialect: assistant.sqlDialect),
        tables: assistant.schemaSource().tables,
        favorites: assistant.favoritesSource())
    }
    if items != suggestions { selectedSuggestion = 0 }
    suggestions = items
  }

  private func pickSuggestion(at index: Int) {
    guard suggestions.indices.contains(index),
      let token = AIComposerSuggestions.token(in: assistant.draft)
    else { return }
    assistant.draft = AIComposerSuggestions.draft(
      assistant.draft, picking: suggestions[index], at: token)
    composerFocused = true
  }

  private func dismissSuggestions() {
    dismissedSuggestionStart = AIComposerSuggestions.token(in: assistant.draft)?.start
    suggestions = []
  }

  /// Send, or run the slash command the draft starts with: it fills the draft for review or
  /// tells why it did nothing
  private func submit() {
    guard AISlashCommand.parse(assistant.draft) != nil else {
      assistant.send()
      return
    }
    let outcome = assistant.runSlashCommand(in: activeTab)
    commandNote = Self.commandNoteText(outcome).map { ($0, assistant.draft) }
  }

  private static func commandNoteText(_ outcome: AIAssistantViewModel.SlashOutcome) -> String? {
    switch outcome {
    case .unknown(let name):
      "Unknown command /\(name)"
    case .unavailable(.explain):
      "/explain needs a query in the active tab"
    case .unavailable(.fix):
      "No error to fix: /fix needs a query that failed"
    case .unavailable(let builtIn):
      "/\(builtIn.rawValue) needs a SQL query in the active tab"
    case .filled(withheld: true):
      "AI access is off for this connection; placeholders were left empty"
    case .notACommand, .filled(withheld: false), .awaitingApproval:
      nil
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
