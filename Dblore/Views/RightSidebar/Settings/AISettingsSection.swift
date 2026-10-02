//
//  AISettingsSection.swift
//  Dblore
//
//  AI settings: provider, base URL, API key, model and connection test
//

import SwiftUI

struct AISettingsSection: View {
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

  private var availableModels: [String] {
    fetchedModels[kind] ?? kind.fallbackModels
  }

  private var resolvedURL: Result<URL, AIEndpointError> {
    Result { () throws(AIEndpointError) -> URL in try AIEndpoint.normalize(baseURL) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
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
          if !availableModels.isEmpty {
            modelCards
          }
          testRow
        }
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
      TextField("Model name", text: $model)
        .textFieldStyle(.plain)
        .font(.bodyText)
        .autocorrectionDisabled()
        .inputStyle()

      if availableModels.count > Self.modelCardLimit {
        modelMenu
      }

      Button("Refresh") { run(reportSuccess: false) }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(isRunning || !canRun)
        .linkPointer()
    }
  }

  private static let modelCardLimit = 12

  private var modelMenu: some View {
    CapsuleDropdown(
      title: "Models",
      options: availableModels,
      optionTitle: { $0 },
      isSelected: { $0 == model },
      onSelect: { model = $0 }
    )
  }

  @ViewBuilder
  private var modelCards: some View {
    if availableModels.count > Self.modelCardLimit {
      currentModelCard
    } else {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        modelCardRows(availableModels)
      }
    }
  }

  @ViewBuilder
  private var currentModelCard: some View {
    let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
    if !name.isEmpty {
      AIRemoteModelButton(
        name: name,
        isCurrent: true,
        showsInUse: isActive
      ) {
        model = name
      }
    }
  }

  @ViewBuilder
  private func modelCardRows(_ names: [String]) -> some View {
    ForEach(names, id: \.self) { name in
      AIRemoteModelButton(
        name: name,
        isCurrent: model == name,
        showsInUse: isActive && model == name
      ) {
        model = name
      }
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
    if config.model.isEmpty { config.model = availableModels.first ?? "" }
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
