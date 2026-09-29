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

  private enum Status: Equatable {
    case idle
    case running
    case success(String)
    case warning(String)
    case failure(String)
  }

  private var isRunning: Bool { status == .running }
  private var isActive: Bool { settings.configuration.activeProvider == kind }

  private var availableModels: [String] {
    fetchedModels[kind] ?? kind.fallbackModels
  }

  private var resolvedURL: Result<URL, AIEndpointError> {
    Result { () throws(AIEndpointError) -> URL in try AIEndpoint.normalize(baseURL) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      providerRow
      baseURLRow
      if kind.requiresAPIKey { apiKeyRow }
      modelRow
      testRow
      if ollamaDetected && kind == .ollama && !isActive {
        helpText("Ollama detected on this Mac. Click Set as active to use it.")
      }

      VStack(alignment: .leading, spacing: Spacing.xs) {
        helpText(
          "Only schema (table/column names, types, keys) is sent — never row data. AI never runs queries."
        )
        if kind == .anthropic {
          helpText(
            "Claude Pro/Max subscriptions can't be used here — Anthropic's terms don't allow third-party apps to reuse them. Use an Anthropic API key."
          )
        }
      }
    }
    .onAppear(perform: loadInitial)
    .task { await detectOllamaIfNeeded() }
    .onDisappear { runningTask?.cancel() }
    .onChange(of: kind) { _, _ in
      runningTask?.cancel()
      status = .idle
      loadFields()
    }
    .onChange(of: baseURL) { _, _ in commit() }
    .onChange(of: model) { _, _ in commit() }
  }

  // MARK: - Rows

  private var providerRow: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      label("Provider")
      HStack(spacing: Spacing.md) {
        Picker("", selection: $kind) {
          ForEach(AIProviderKind.allCases, id: \.self) { kind in
            Text(kind.displayName).tag(kind)
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 240)

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
  }

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
            .font(.small)
            .foregroundColor(.foregroundSubtle)
        }
      case .failure(let error):
        Text(error.localizedDescription)
          .font(.small)
          .foregroundColor(.destructive)
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
          .font(.small)
          .foregroundColor(.destructive)
      }
    }
  }

  private var modelRow: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      label("Model")
      HStack(spacing: Spacing.sm) {
        TextField("Model name", text: $model)
          .textFieldStyle(.plain)
          .font(.bodyText)
          .autocorrectionDisabled()
          .inputStyle()

        if !availableModels.isEmpty {
          Menu("Models") {
            ForEach(availableModels, id: \.self) { name in
              Button(name) { model = name }
            }
          }
          .menuStyle(.button)
          .fixedSize()
        }

        Button("Refresh") { run(reportSuccess: false) }
          .buttonStyle(SecondaryButtonStyle())
          .disabled(isRunning)
          .linkPointer()
      }
    }
  }

  private var testRow: some View {
    HStack(spacing: Spacing.md) {
      Button("Test connection") { run(reportSuccess: true) }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(isRunning)
        .linkPointer()

      switch status {
      case .idle:
        EmptyView()
      case .running:
        ProgressView()
          .controlSize(.small)
      case .success(let message):
        Text(message)
          .font(.small)
          .foregroundColor(.success)
      case .warning(let message):
        Text(verbatim: message)
          .font(.small)
          .foregroundColor(.foregroundMuted)
      case .failure(let message):
        Text(message)
          .font(.small)
          .foregroundColor(.destructive)
          .textSelection(.enabled)
      }
    }
  }

  private func label(_ text: String) -> some View {
    Text(text)
      .font(.subheading)
      .foregroundColor(.foreground)
  }

  private func helpText(_ text: String) -> some View {
    Text(verbatim: text)
      .font(.small)
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
      }
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
