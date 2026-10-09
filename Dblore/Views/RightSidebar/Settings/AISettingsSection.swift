//
//  AISettingsSection.swift
//  Dblore
//
//  AI settings: provider, base URL, API key, model and connection test
//

import AppKit
import SwiftUI

struct AISettingsSection: View {
  @Bindable var appSettings: AppSettings
  private let settings = AISettings.shared

  @State private var kind: AIProviderKind = .anthropic
  @State private var baseURL = ""
  @State private var model = ""
  @State private var keyInput = ""
  @State private var hasSavedKey = false
  @State private var keyError: String?
  @State private var fetchedModels: [AIProviderKind: [String]] = [:]
  @State private var status: Status = .idle
  @State private var runningTask: Task<Void, Never>?
  @State private var didLoad = false
  @State private var ollamaDetected = false
  @State private var signedInEmail: String?
  @State private var isSignedIn = false
  @State private var signingIn = false
  @State private var signInError: String?
  @State private var signInTask: Task<Void, Never>?
  @State private var signInServer: OAuthLoopbackServer?

  private enum Status: Equatable {
    case idle
    case running
    case success(String)
    case warning(String)
    case failure(String)
  }

  private var isRunning: Bool { status == .running }
  /// ChatGPT needs a sign-in before it can list models
  private var canRun: Bool { kind != .chatGPT || isSignedIn }
  private var isActive: Bool { settings.configuration.activeProvider == kind }

  /// Names returned by the last successful fetch for the selected provider.
  private var fetchedModelNames: [String] {
    fetchedModels[kind] ?? []
  }

  private var resolvedURL: Result<URL, AIEndpointError> {
    Result { () throws(AIEndpointError) -> URL in try AIEndpoint.normalize(baseURL) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      panelCard

      SettingsGroupCard(title: "Provider") {
        VStack(alignment: .leading, spacing: Spacing.md) {
          providerControls
          if ollamaDetected && kind == .ollama && !isActive {
            helpText("Ollama detected on this Mac. Click Set as active to use it.")
          }
        }
      }

      if kind != .localMLX {
        connectionCard
      }

      modelsCard
      privacyCard
    }
    .onAppear(perform: loadInitial)
    .task { await detectOllamaIfNeeded() }
    .onDisappear {
      runningTask?.cancel()
      cancelSignIn()
    }
    .onChange(of: kind) { _, _ in
      runningTask?.cancel()
      cancelSignIn()
      status = .idle
      loadFields()
    }
    .onChange(of: baseURL) { _, _ in commit() }
    .onChange(of: model) { _, _ in commit() }
  }

  // MARK: - Cards

  private var providerControls: some View {
    HStack(alignment: .center, spacing: Spacing.md) {
      CapsuleDropdown(
        title: kind.displayName,
        width: 300,
        accessibilityLabel: "Provider",
        options: Array(AIProviderKind.allCases),
        optionTitle: \.displayName,
        isSelected: { $0 == kind },
        onSelect: { kind = $0 }
      )

      if isActive {
        HStack(spacing: Spacing.xs) {
          Image(systemName: "checkmark.circle.fill")
          Text("Active")
        }
        .font(.small)
        .foregroundColor(.success)
      } else {
        Button("Set as active") {
          settings.configuration.activeProvider = kind
        }
        .buttonStyle(SecondaryButtonStyle())
        .linkPointer()
      }
    }
  }

  private var connectionCard: some View {
    SettingsGroupCard(title: kind == .chatGPT ? "Account" : "Connection") {
      VStack(alignment: .leading, spacing: Spacing.md) {
        if kind == .chatGPT {
          chatGPTBody
        } else {
          baseURLRow
          if kind.requiresAPIKey {
            apiKeyRow
          }
        }
        if let serviceNote {
          Divider()
          helpText(serviceNote)
        }
      }
    }
  }

  private var modelsCard: some View {
    SettingsGroupCard(title: kind == .localMLX ? "Local models" : "Models") {
      if kind == .localMLX {
        // No network probe: models are chosen from the catalog below.
        VStack(alignment: .leading, spacing: Spacing.md) {
          AILocalModelsSection()
          Divider()
          VStack(alignment: .leading, spacing: Spacing.xs) {
            helpText("Runs fully on this Mac (Apple Silicon). Nothing leaves your computer.")
            helpText(
              "Model downloads come from Hugging Face over HTTPS (the only network use) and are stored in the app's sandbox container."
            )
          }
        }
      } else {
        VStack(alignment: .leading, spacing: Spacing.md) {
          modelEditor
          testRow
        }
      }
    }
  }

  private var panelCard: some View {
    SettingsGroupCard(title: "Panel") {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        Text("Where the AI Assistant opens from the toolbar button and ⌘L")
          .font(.bodyText)
          .foregroundColor(.foregroundMuted)

        CapsuleDropdown(
          title: appSettings.aiPanelOpenMode.title,
          width: 200,
          accessibilityLabel: "AI Assistant panel",
          options: Array(AIPanelMode.allCases),
          optionTitle: \.title,
          isSelected: { $0 == appSettings.aiPanelOpenMode },
          onSelect: { appSettings.aiPanelOpenMode = $0 }
        )
      }
    }
  }

  private var privacyCard: some View {
    SettingsGroupCard(title: "Privacy") {
      helpText(
        "Only schema (table/column names, types, keys) is sent — never row data. AI never runs queries."
      )
    }
  }

  private var serviceNote: String? {
    switch kind {
    case .chatGPT:
      return
        "Experimental: uses the unofficial Codex endpoint with your ChatGPT plan's limits. OpenAI may change or block it at any time."
    case .anthropic:
      return
        "Claude Pro/Max subscriptions can't be used here — Anthropic's terms don't allow third-party apps to reuse them. Use an Anthropic API key."
    case .openAI, .openRouter, .ollama, .lmStudio, .mlxServer, .custom, .localMLX:
      return nil
    }
  }

  // MARK: - Fields

  private var baseURLRow: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      label("Base URL")
      TextField(
        kind.defaultBaseURL.isEmpty ? "https://host/v1" : kind.defaultBaseURL, text: $baseURL
      )
      .textFieldStyle(.plain)
      .font(.bodyText)
      .autocorrectionDisabled()
      .inputStyle()
      switch resolvedURL {
      case .success(let url):
        if !baseURL.isEmpty {
          Text("Resolved: \(url.absoluteString)")
            .font(.bodyText)
            .foregroundColor(.foregroundSubtle)
        }
      case .failure(let error):
        Text(error.localizedDescription)
          .font(.bodyText)
          .foregroundColor(.destructive)
      }
    }
  }

  private var chatGPTBody: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      if isSignedIn {
        HStack(spacing: Spacing.md) {
          Text(signedInEmail.map { "Signed in as \($0)" } ?? "Signed in")
            .font(.bodyText)
            .foregroundColor(.foregroundMuted)
          Button("Sign out") { signOut() }
            .buttonStyle(SecondaryButtonStyle())
            .linkPointer()
        }
      } else {
        HStack(spacing: Spacing.md) {
          Button("Sign in with ChatGPT") { signIn() }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(signingIn)
            .linkPointer()
          if signingIn {
            ProgressView()
              .controlSize(.small)
            Text("Waiting for the browser...")
              .font(.bodyText)
              .foregroundColor(.foregroundMuted)
            Button("Cancel") { cancelSignIn() }
              .buttonStyle(SecondaryButtonStyle())
              .linkPointer()
          }
        }
      }
      if let signInError {
        Text(signInError)
          .font(.bodyText)
          .foregroundColor(.destructive)
          .textSelection(.enabled)
      }
    }
  }

  private var apiKeyRow: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      label("API key")
      if hasSavedKey {
        HStack(spacing: Spacing.md) {
          Text("Saved ••••")
            .font(.bodyText)
            .foregroundColor(.foregroundMuted)
          Button("Remove") { removeKey() }
            .buttonStyle(SecondaryButtonStyle())
            .linkPointer()
        }
      } else {
        HStack(spacing: Spacing.sm) {
          SecureField("Paste API key", text: $keyInput)
            .textFieldStyle(.plain)
            .font(.bodyText)
            .inputStyle()
            .onSubmit(saveKey)
          Button("Save") { saveKey() }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(trimmedKey.isEmpty)
            .linkPointer()
        }
      }
      if let keyError {
        Text(keyError)
          .font(.bodyText)
          .foregroundColor(.destructive)
      }
    }
  }

  private var modelEditor: some View {
    HStack(alignment: .center, spacing: Spacing.sm) {
      ModelNameComboBox(text: $model, options: fetchedModelNames)

      Button("Refresh") { run(reportSuccess: false) }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(isRunning || !canRun)
        .linkPointer()
    }
  }

  private var testRow: some View {
    HStack(spacing: Spacing.md) {
      Button("Test connection") { run(reportSuccess: true) }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(isRunning || !canRun)
        .linkPointer()

      switch status {
      case .idle:
        EmptyView()
      case .running:
        ProgressView()
          .controlSize(.small)
      case .success(let message):
        Text(message)
          .font(.bodyText)
          .foregroundColor(.success)
      case .warning(let message):
        Text(verbatim: message)
          .font(.bodyText)
          .foregroundColor(.foregroundMuted)
      case .failure(let message):
        Text(message)
          .font(.bodyText)
          .foregroundColor(.destructive)
          .textSelection(.enabled)
      }
    }
  }

  private func label(_ text: String) -> some View {
    Text(text)
      .font(.bodyText)
      .fontWeight(.medium)
      .foregroundColor(.foreground)
  }

  private func helpText(_ text: String) -> some View {
    Text(verbatim: text)
      .font(.bodyText)
      .foregroundColor(.foregroundSubtle)
  }

  // MARK: - State

  private var trimmedKey: String {
    keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func loadInitial() {
    guard !didLoad else { return }
    didLoad = true
    kind = settings.configuration.activeProvider ?? .anthropic
    loadFields()
  }

  private func loadFields() {
    let config = settings.config(for: kind)
    baseURL = config.baseURL
    model = config.model
    keyInput = ""
    keyError = nil
    hasSavedKey = !(settings.apiKey(for: kind) ?? "").isEmpty
    refreshSignInState()
  }

  private func refreshSignInState() {
    let tokens = kind == .chatGPT ? settings.chatGPTTokens() : nil
    isSignedIn = tokens != nil
    signedInEmail = tokens?.email
    signInError = nil
  }

  /// Writes the edited fields back, only when they differ from what is stored
  private func commit() {
    guard didLoad else { return }
    let edited = AIProviderConfig(baseURL: baseURL, model: model)
    guard edited != settings.config(for: kind) else { return }
    settings.configuration.configs[kind] = edited
  }

  private func saveKey() {
    let key = trimmedKey
    guard !key.isEmpty else { return }
    if settings.setAPIKey(key, for: kind) {
      keyInput = ""
      keyError = nil
      hasSavedKey = true
    } else {
      keyError = "Could not save the API key to the Keychain."
    }
  }

  private func removeKey() {
    settings.setAPIKey("", for: kind)
    hasSavedKey = false
    keyError = nil
  }

  private func run(reportSuccess: Bool) {
    guard !isRunning else { return }
    let kind = kind
    let config = AIProviderConfig(baseURL: baseURL, model: model)
    let key = settings.apiKey(for: kind)
    status = .running
    runningTask = Task {
      do {
        let client = try AIClientFactory.make(kind: kind, config: config, apiKey: key)
        let result = try await client.listModelsResult()
        let models = result.models
        guard !Task.isCancelled else { return }
        fetchedModels[kind] = models.isEmpty ? nil : models
        if !reportSuccess {
          status = .idle
        } else if result.isFallback {
          status = .warning(
            "Models endpoint not found. Using the built-in model list; the connection was not verified."
          )
        } else {
          status = .success(
            "Connected. \(models.count) model\(models.count == 1 ? "" : "s") available.")
        }
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled else { return }
        status = .failure(error.localizedDescription)
        // A refresh that found the sign-in dead wiped the tokens: stop showing "Signed in as"
        if (error as? AIClientError) == ChatGPTTokenProvider.signedOutError {
          refreshSignInState()
        }
      }
    }
  }

  // MARK: - ChatGPT sign in

  private func cancelSignIn() {
    signInTask?.cancel()
    signInTask = nil
    signInServer?.cancel()
    signInServer = nil
    signingIn = false
  }

  private func signIn() {
    guard !signingIn else { return }
    signingIn = true
    signInError = nil
    let server = OAuthLoopbackServer()
    signInServer = server
    signInTask = Task {
      do {
        let pkce = PKCE.generate()
        let state = ChatGPTOAuth.generateState()
        let port = try await server.start()
        try Task.checkCancellation()
        NSWorkspace.shared.open(ChatGPTOAuth.authorizeURL(pkce: pkce, state: state, port: port))
        let code = try await server.waitForCallback(expectedState: state)
        let tokens = try await Self.exchange(code: code, verifier: pkce.verifier, port: port)
        guard !Task.isCancelled else { return }
        await finishSignIn(tokens)
      } catch is CancellationError {
        server.cancel()
      } catch {
        server.cancel()
        guard !Task.isCancelled else { return }
        signInError = error.localizedDescription
        signingIn = false
        signInServer = nil
      }
    }
  }

  private static func exchange(
    code: String, verifier: String, port: Int
  ) async throws
    -> ChatGPTTokens
  {
    let request = ChatGPTOAuth.tokenRequest(code: code, verifier: verifier, port: port)
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await URLSession.shared.data(
        for: request, delegate: AIRedirectGuard())
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw AIClientError.transport("Could not reach ChatGPT to finish signing in.")
    }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      throw AIClientError.http(status: status, message: "ChatGPT rejected the sign-in.")
    }
    return try ChatGPTOAuth.parseTokenResponse(data)
  }

  private func finishSignIn(_ tokens: ChatGPTTokens) async {
    signingIn = false
    signInServer = nil
    guard await ChatGPTTokenProvider.shared.store(tokens) else {
      signInError = "Could not save the ChatGPT sign-in to the Keychain."
      return
    }
    // Write the configuration so observers refresh; activeProvider stays unchanged
    var config = settings.config(for: .chatGPT)
    if config.baseURL.isEmpty { config.baseURL = AIProviderKind.chatGPT.defaultBaseURL }
    if config.model.isEmpty {
      config.model = fetchedModelNames.first ?? kind.fallbackModels.first ?? ""
    }
    settings.configuration.configs[.chatGPT] = config
    loadFields()
  }

  private func signOut() {
    cancelSignIn()
    Task {
      await ChatGPTTokenProvider.shared.signOut()
      if settings.configuration.activeProvider == .chatGPT {
        settings.configuration.activeProvider = nil
      } else {
        // Touch the configuration so observers refresh even when nothing else changed
        settings.configuration.configs[.chatGPT] = settings.config(for: .chatGPT)
      }
      refreshSignInState()
    }
  }

  private func detectOllamaIfNeeded() async {
    guard settings.configuration.activeProvider == nil else { return }
    guard let models = await OpenAICompatibleClient.detectOllama(), let first = models.first
    else { return }
    // The user may have picked a provider while the probe ran
    guard settings.configuration.activeProvider == nil else { return }
    // Detection only suggests: never activate, never overwrite a stored config
    if settings.configuration.configs[.ollama] == nil {
      settings.configuration.configs[.ollama] = AIProviderConfig(
        baseURL: AIProviderKind.ollama.defaultBaseURL, model: first)
    }
    fetchedModels[.ollama] = models
    ollamaDetected = true
    if kind == .ollama {
      loadFields()
    } else {
      kind = .ollama
    }
  }
}

/// Editable model name with a menu of names from the last fetch.
private struct ModelNameComboBox: View {
  @Binding var text: String
  let options: [String]

  var body: some View {
    HStack(spacing: Spacing.xs) {
      TextField("Model name", text: $text)
        .textFieldStyle(.plain)
        .font(.bodyText)
        .autocorrectionDisabled()

      Image(systemName: "chevron.down")
        .font(.system(size: 9, weight: .semibold))
        .foregroundColor(.foregroundMuted)
        .frame(width: 16)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .overlay {
          ModelMenuButton(options: options, selected: text) { text = $0 }
        }
        .accessibilityLabel("Models")
    }
    .padding(.leading, Spacing.md)
    .padding(.trailing, Spacing.sm)
    .frame(height: ButtonMetrics.regularHeight)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.inputBackground, in: Capsule())
    .overlay(Capsule().stroke(Color.border, lineWidth: 1))
    .accessibilityLabel("Model")
  }
}

/// Chevron that opens the model list with its right edge on the trigger.
private struct ModelMenuButton: NSViewRepresentable {
  var options: [String]
  var selected: String
  var onSelect: (String) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onSelect: onSelect)
  }

  func makeNSView(context: Context) -> MenuClickView {
    let view = MenuClickView()
    view.coordinator = context.coordinator
    return view
  }

  func updateNSView(_ nsView: MenuClickView, context: Context) {
    context.coordinator.options = options
    context.coordinator.selected = selected
    context.coordinator.onSelect = onSelect
    nsView.coordinator = context.coordinator
  }

  final class Coordinator: NSObject {
    var options: [String]
    var selected = ""
    var onSelect: (String) -> Void

    init(onSelect: @escaping (String) -> Void) {
      self.options = []
      self.onSelect = onSelect
    }

    @objc func pick(_ sender: NSMenuItem) {
      guard let name = sender.representedObject as? String else { return }
      onSelect(name)
    }

    func pop(from view: NSView) {
      let menu = NSMenu()
      menu.autoenablesItems = false
      if options.isEmpty {
        let item = NSMenuItem(title: "Refresh to load models", action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
      } else {
        for name in options {
          let item = NSMenuItem(title: name, action: #selector(pick(_:)), keyEquivalent: "")
          item.target = self
          item.representedObject = name
          item.state = name == selected ? .on : .off
          menu.addItem(item)
        }
      }
      // LTR places the menu's top-left at `at`. Shift left by the menu width so the
      // top-right sits on the trigger, just below the field.
      let width = menuWidth(menu)
      let origin = NSPoint(x: view.bounds.maxX - width, y: -2)
      menu.popUp(positioning: nil, at: origin, in: view)
    }

    private func menuWidth(_ menu: NSMenu) -> CGFloat {
      let measured = menu.size.width
      if measured > 1 { return measured }
      let font = NSFont.menuFont(ofSize: 0)
      let longest = menu.items.map(\.title).max { $0.count < $1.count } ?? ""
      return (longest as NSString).size(withAttributes: [.font: font]).width + 56
    }
  }
}

private final class MenuClickView: NSView {
  weak var coordinator: ModelMenuButton.Coordinator?

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
  }

  override func resetCursorRects() {
    discardCursorRects()
    addCursorRect(bounds, cursor: .pointingHand)
  }

  override func mouseDown(with event: NSEvent) {
    coordinator?.pop(from: self)
  }
}
