// AIInlineCompletionController.swift
// Ghost text of one SQL editor: debounced requests on typing pauses, cancelled by the next edit

import Foundation

@MainActor @Observable
final class AIInlineCompletionController {

  /// A suggestion for the text at `version` with the caret at `caret` (UTF-16 offset)
  struct Suggestion: Equatable {
    let text: String
    let caret: Int
    let version: Int
  }

  /// Shortest typing pause before a request, whatever the setting says
  static let minDebounceMs = 150
  /// UTF-8 bytes of a reply read before the stream is dropped; leaves room for an echoed prefix
  /// (4 bytes per character at most)
  static let maxReplyBytes =
    (AIInlineCompletion.maxPrefixChars + AIInlineCompletion.maxSuggestionChars) * 4

  private(set) var suggestion: Suggestion? {
    didSet { if suggestion != oldValue { onSuggestionChange?() } }
  }
  /// Called when `suggestion` changes; the editor redraws its ghost text
  @ObservationIgnored var onSuggestionChange: (() -> Void)?

  /// Bumped on every text change; a reply for an older version is dropped
  @ObservationIgnored private(set) var version = 0
  @ObservationIgnored private var text = ""
  @ObservationIgnored private var caret = 0
  /// The pending debounce and the request after it; one at a time
  @ObservationIgnored private(set) var task: Task<Void, Never>?

  @ObservationIgnored private let configuration: () -> AIConfiguration
  /// A client for the provider; nil when the provider is not configured
  @ObservationIgnored private let makeClient: (AIProviderKind) -> (any AIChatClient)?
  /// Bumped when an API key changes (see `AISettings.keyRevision`)
  @ObservationIgnored private let keyRevision: () -> Int
  @ObservationIgnored private let sleep: (Duration) async throws -> Void
  /// The last client built and what it was built for: building one reads the Keychain, so it
  /// is rebuilt only when the provider, its settings or an API key change. A missing client is
  /// never kept (signing in elsewhere configures the provider without a change seen here).
  @ObservationIgnored private var cachedClient: (key: ClientKey, client: any AIChatClient)?
  /// True only when the connection's AI access is allowed; needs approval and denied are false
  /// (ghost text never asks). Read before every request.
  @ObservationIgnored var isAllowed: () -> Bool = { false }
  /// Dialect of the editor and whether it shows a read-only source; nil sends nothing
  @ObservationIgnored var source: () -> (dialect: SQLDialect, isReadOnlySource: Bool)? = { nil }
  /// Compact schema for the text before the caret; read only after `isAllowed`. Async: the
  /// editor's closure builds it off the main actor.
  @ObservationIgnored var schema: @MainActor (_ prefix: String) async -> String? = { _ in nil }

  private struct ClientKey: Equatable {
    let provider: AIProviderKind
    let config: AIProviderConfig?
    let keyRevision: Int
  }

  init(
    configuration: @escaping () -> AIConfiguration = { AISettings.shared.configuration },
    makeClient: @escaping (AIProviderKind) -> (any AIChatClient)? = { kind in
      let settings = AISettings.shared
      guard settings.isConfigured(kind) else { return nil }
      return try? AIClientFactory.make(
        kind: kind, config: settings.config(for: kind), apiKey: settings.apiKey(for: kind))
    },
    keyRevision: @escaping () -> Int = { AISettings.shared.keyRevision },
    sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    registry: AIInlineCompletionRegistry = .shared
  ) {
    self.configuration = configuration
    self.makeClient = makeClient
    self.keyRevision = keyRevision
    self.sleep = sleep
    registry.add(self)
  }

  /// A chat turn, review or one-shot request is about to use the on-device model: drops the
  /// suggestion and the request, pending or in flight, when ghost text uses it too
  fileprivate func yieldOnDeviceModel() {
    guard configuration().inlineTarget?.provider == .localMLX else { return }
    cancel()
  }

  /// Ghost text is on and has a provider and model
  var isEnabled: Bool {
    let config = configuration()
    return config.inlineEnabled && config.inlineTarget != nil
  }

  // MARK: - Editor events

  /// A keystroke: drops the suggestion and any request, then waits for a typing pause
  func textDidChange(text: String, caret: Int) {
    cancel()
    self.text = text
    self.caret = caret
    version += 1
    let config = configuration()
    guard config.inlineEnabled, config.inlineTarget != nil else { return }
    let delay = Duration.milliseconds(max(Self.minDebounceMs, config.inlineDebounceMs))
    let version = version
    task = Task { [weak self, sleep] in
      do {
        try await sleep(delay)
        try Task.checkCancellation()
        try await self?.complete(version: version)
      } catch {
        // Errors and cancellation show nothing
      }
    }
  }

  /// The caret moved without an edit; the same caret (posted with every keystroke) is ignored
  func selectionDidChange(caret: Int) {
    guard caret != self.caret else { return }
    cancel()
    self.caret = caret
  }

  func focusLost() { cancel() }

  func dismiss() { cancel() }

  /// The suggestion, cleared; the editor inserts the part of it that shows
  func accept() -> String? {
    guard let suggestion else { return nil }
    cancel()
    return suggestion.text
  }

  // MARK: - Request

  private func cancel() {
    task?.cancel()
    task = nil
    suggestion = nil
  }

  private func complete(version: Int) async throws {
    let config = configuration()
    guard config.inlineEnabled, let target = config.inlineTarget, let source = source(),
      var context = AIInlineCompletion.context(
        text: text, caret: caret, dialect: source.dialect, schema: nil,
        isReadOnlySource: source.isReadOnlySource),
      isAllowed(), let client = client(for: target.provider, config: config)
    else { return }
    let schema = await self.schema(context.prefix)
    try Task.checkCancellation()
    guard version == self.version else { return }
    context.schema = schema
    let request = AIInlineCompletion.request(context, model: target.model)
    let caret = caret
    let reply = try await PerfSignpost.interval("ai.inline") {
      try await Self.collect(client.stream(request))
    }
    try Task.checkCancellation()
    // The access may have been revoked while the reply streamed
    guard version == self.version, caret == self.caret, isAllowed(),
      let text = AIInlineCompletion.sanitize(
        reply, prefix: context.prefix, maxLines: context.maxLines)
    else { return }
    suggestion = Suggestion(text: text, caret: caret, version: version)
  }

  private func client(
    for provider: AIProviderKind, config: AIConfiguration
  ) -> (any AIChatClient)? {
    let key = ClientKey(
      provider: provider, config: config.configs[provider], keyRevision: keyRevision())
    if let cachedClient, cachedClient.key == key { return cachedClient.client }
    cachedClient = nil
    guard let client = makeClient(provider) else { return nil }
    cachedClient = (key, client)
    return client
  }

  /// The streamed text, up to `maxReplyBytes`: a delta that would pass it is cut before it is
  /// appended
  static func collect(
    _ stream: AsyncThrowingStream<AIStreamEvent, Error>
  ) async throws
    -> String
  {
    var reply = ""
    var bytes = 0
    loop: for try await event in stream {
      switch event {
      case .text(let delta):
        let size = delta.utf8.count
        guard bytes + size < maxReplyBytes else {
          reply += String(decoding: delta.utf8.prefix(maxReplyBytes - bytes), as: UTF8.self)
          break loop
        }
        reply += delta
        bytes += size
      case .stop: break loop
      case .loadingModel, .toolCall: continue
      }
    }
    return reply
  }
}

/// The ghost text controllers alive, so a request the user asks for can stop theirs first
@MainActor final class AIInlineCompletionRegistry {
  static let shared = AIInlineCompletionRegistry()

  private let live = NSHashTable<AIInlineCompletionController>.weakObjects()

  fileprivate func add(_ controller: AIInlineCompletionController) { live.add(controller) }

  /// A chat turn, review or one-shot request is about to use `provider`. The on-device model
  /// serves one request at a time and refuses another while one runs, so the ghost requests of
  /// every editor bound for it are cancelled first (a cancelled request makes the next one wait
  /// instead). Other providers serve requests side by side.
  func yieldToForegroundRequest(on provider: AIProviderKind) {
    guard provider == .localMLX else { return }
    for controller in live.allObjects { controller.yieldOnDeviceModel() }
  }
}
