// ChatGPTCodexClient.swift
// Codex Responses client for "Sign in with ChatGPT" (unofficial endpoint) and its token provider

import Foundation

/// Single writer of the stored ChatGPT tokens: loads, refreshes, stores and wipes them.
/// Refreshes are coalesced into one request. Tokens are never logged and never appear in errors.
actor ChatGPTTokenProvider {
  static let shared = ChatGPTTokenProvider(store: AIKeyStoreFactory.shared, session: .shared)

  static let signedOutMessage = "Signed out of ChatGPT"
  static var signedOutError: AIClientError {
    .http(status: 401, message: signedOutMessage)
  }

  /// Refresh error codes after which the refresh token can never work again
  private static let terminalCodes: Set<String> = [
    "refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated",
  ]

  private let store: AIKeyStore
  private let session: URLSession
  private let now: @Sendable () -> Date
  private var refreshTask: Task<ChatGPTTokens, Error>?
  /// Bumped by every sign-out / sign-in so an in-flight refresh can tell it became stale
  private var generation = 0

  init(store: AIKeyStore, session: URLSession, now: @escaping @Sendable () -> Date = { Date() }) {
    self.store = store
    self.session = session
    self.now = now
  }

  /// Tokens valid for at least the refresh leeway; refreshes first when needed
  func validTokens() async throws -> ChatGPTTokens {
    guard let tokens = ChatGPTTokenStorage.load(from: store) else { throw Self.signedOutError }
    guard tokens.needsRefresh(now: now()) else { return tokens }
    return try await coalescedRefresh(tokens)
  }

  /// Forces one refresh after the endpoint rejected `rejected` (401), unless the stored tokens
  /// already moved on
  func refreshed(rejecting rejected: ChatGPTTokens) async throws -> ChatGPTTokens {
    guard let tokens = ChatGPTTokenStorage.load(from: store) else { throw Self.signedOutError }
    guard tokens.accessToken == rejected.accessToken else { return tokens }
    return try await coalescedRefresh(tokens)
  }

  /// Deletes the stored tokens and drops any in-flight refresh (sign out)
  func signOut() {
    invalidateInFlight()
    ChatGPTTokenStorage.delete(from: store)
  }

  /// Stores freshly signed-in tokens and drops any in-flight refresh. False when saving failed.
  func store(_ tokens: ChatGPTTokens) -> Bool {
    invalidateInFlight()
    return ChatGPTTokenStorage.save(tokens, to: store)
  }

  private func invalidateInFlight() {
    generation += 1
    refreshTask?.cancel()
    refreshTask = nil
  }

  private func coalescedRefresh(_ tokens: ChatGPTTokens) async throws -> ChatGPTTokens {
    if let refreshTask { return try await refreshTask.value }
    let started = generation
    let task = Task { try await self.refresh(tokens, generation: started) }
    refreshTask = task
    defer { if generation == started { refreshTask = nil } }
    return try await task.value
  }

  /// True while nothing signed out or in since the refresh began and the stored refresh token
  /// is still the one the refresh used
  private func isCurrent(_ tokens: ChatGPTTokens, generation started: Int) -> Bool {
    generation == started
      && ChatGPTTokenStorage.load(from: store)?.refreshToken == tokens.refreshToken
  }

  /// The result of a stale refresh is discarded: the newer stored tokens win
  private func staleResult() throws -> ChatGPTTokens {
    guard let current = ChatGPTTokenStorage.load(from: store) else { throw Self.signedOutError }
    return current
  }

  private func refresh(
    _ tokens: ChatGPTTokens, generation started: Int
  ) async throws
    -> ChatGPTTokens
  {
    let request = ChatGPTOAuth.refreshRequest(refreshToken: tokens.refreshToken)
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request, delegate: AIRedirectGuard())
    } catch {
      if !isCurrent(tokens, generation: started) { return try staleResult() }
      if error is CancellationError { throw CancellationError() }
      throw AIClientError.transport("Could not refresh the ChatGPT sign-in.")
    }
    if !isCurrent(tokens, generation: started) { return try staleResult() }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if status == 401 || (status == 400 && Self.isTerminal(data)) {
      ChatGPTTokenStorage.delete(from: store)
      throw Self.signedOutError
    }
    guard (200..<300).contains(status) else {
      throw AIClientError.http(status: status, message: "Could not refresh the ChatGPT sign-in.")
    }
    let refreshed: ChatGPTTokens
    do {
      refreshed = try ChatGPTOAuth.parseTokenResponse(data, now: now(), previous: tokens)
    } catch {
      throw AIClientError.transport("Could not refresh the ChatGPT sign-in.")
    }
    guard ChatGPTTokenStorage.save(refreshed, to: store) else {
      throw AIClientError.transport("Could not save the ChatGPT sign-in to the Keychain.")
    }
    return refreshed
  }

  /// Reads `error.code` (or an `error` / `code` string) from the JSON body
  private static func isTerminal(_ data: Data) -> Bool {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return false }
    let code: String?
    if let error = object["error"] as? [String: Any] {
      code = error["code"] as? String
    } else {
      code = (object["error"] as? String) ?? (object["code"] as? String)
    }
    return code.map(terminalCodes.contains) ?? false
  }
}

nonisolated struct ChatGPTCodexClient: AIChatClient {
  let tokenProvider: ChatGPTTokenProvider
  var session: URLSession = .shared

  /// Fixed: bearer and account headers are only ever sent to this host
  static let baseURL = URL(string: "https://chatgpt.com/backend-api/codex")!
  static let originator = "dblore"
  static let clientVersion = "1.0.0"

  static func makeRequest(
    _ request: AIChatRequest, baseURL: URL, accessToken: String, accountID: String?
  ) -> URLRequest {
    var urlRequest = URLRequest(url: AIEndpoint.chatURL(base: baseURL, wire: .responses))
    urlRequest.httpMethod = "POST"
    applyHeaders(&urlRequest, accessToken: accessToken, accountID: accountID)
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    let input: [[String: Any]] = request.messages.map { message in
      let contentType = message.role == .user ? "input_text" : "output_text"
      return [
        "type": "message", "role": message.role.rawValue,
        "content": [["type": contentType, "text": message.text]],
      ]
    }
    // No temperature / max_output_tokens: the Codex endpoint rejects them
    let body: [String: Any] = [
      "model": request.model,
      "instructions": request.system,
      "input": input,
      "stream": true,
      "store": false,
    ]
    urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)
    return urlRequest
  }

  private static func applyHeaders(
    _ request: inout URLRequest, accessToken: String, accountID: String?
  ) {
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    if let accountID, !accountID.isEmpty {
      request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
    }
    request.setValue("responses=v1", forHTTPHeaderField: "OpenAI-Beta")
    request.setValue(originator, forHTTPHeaderField: "originator")
  }

  func stream(_ request: AIChatRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          try await withAuthRetry { tokens in
            let urlRequest = Self.makeRequest(
              request, baseURL: Self.baseURL, accessToken: tokens.accessToken,
              accountID: tokens.accountID)
            let inner = AIClientFactory.streamLines(
              urlRequest, session: session, parser: AISSEParser(wire: .responses))
            for try await event in inner { continuation.yield(event) }
          }
          continuation.finish()
        } catch is CancellationError {
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Runs `operation`; on a 401 forces ONE token refresh and retries once. Tokens are wiped only
  /// when the refresh itself reports they are dead (the provider throws signed out).
  private func withAuthRetry<T>(_ operation: (ChatGPTTokens) async throws -> T) async throws -> T {
    let tokens = try await tokenProvider.validTokens()
    do {
      return try await operation(tokens)
    } catch AIClientError.http(let status, _) where status == 401 {
      let fresh = try await tokenProvider.refreshed(rejecting: tokens)
      return try await operation(fresh)
    }
  }

  /// `GET /models?client_version=...` -> `{"models":[{"slug","visibility"}]}`, `list` only
  func listModels() async throws -> [String] {
    try await listModelsResult().models
  }

  func listModelsResult() async throws -> AIModelListResult {
    try await withAuthRetry { tokens in try await fetchModels(tokens) }
  }

  /// Non-auth failures fall back to the built-in list; 401/403 throw the server error
  private func fetchModels(_ tokens: ChatGPTTokens) async throws -> AIModelListResult {
    let fallback = AIModelListResult(
      models: AIProviderKind.chatGPT.fallbackModels, isFallback: true)
    var components = URLComponents(
      url: AIEndpoint.modelsURL(base: Self.baseURL), resolvingAgainstBaseURL: false)!
    components.queryItems = [URLQueryItem(name: "client_version", value: Self.clientVersion)]
    var urlRequest = URLRequest(url: components.url!)
    Self.applyHeaders(&urlRequest, accessToken: tokens.accessToken, accountID: tokens.accountID)
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: urlRequest, delegate: AIRedirectGuard())
    } catch {
      return fallback
    }
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      if http.statusCode == 401 || http.statusCode == 403 {
        throw AIClientError.http(
          status: http.statusCode,
          message: AIClientFactory.errorMessage(
            from: data.prefix(AIClientFactory.errorBodyLimit)))
      }
      return fallback
    }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let items = object["models"] as? [[String: Any]]
    else { return fallback }
    let models = items.compactMap { item -> String? in
      guard item["visibility"] as? String == "list" else { return nil }
      return item["slug"] as? String
    }
    return models.isEmpty ? fallback : AIModelListResult(models: models, isFallback: false)
  }
}
