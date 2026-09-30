import Foundation
import Testing

@testable import Dblore

@Suite("ChatGPTCodexClient", .serialized, AIStubScope())
struct ChatGPTCodexClientTests {

  private let base = ChatGPTCodexClient.baseURL

  private func makeTokens(
    expiresIn: TimeInterval = 3600, access: String = "access-1", refresh: String = "refresh-1"
  ) -> ChatGPTTokens {
    ChatGPTTokens(
      accessToken: access, refreshToken: refresh, idToken: "a.b.c",
      expiresAt: Date().addingTimeInterval(expiresIn), accountID: "acct-1", email: "a@b.c")
  }

  private func setup(
    tokens: ChatGPTTokens?
  ) -> (
    client: ChatGPTCodexClient, store: InMemoryAIKeyStore
  ) {
    let store = InMemoryAIKeyStore()
    if let tokens { ChatGPTTokenStorage.save(tokens, to: store) }
    let session = AIStubURLProtocol.makeSession()
    let provider = ChatGPTTokenProvider(store: store, session: session)
    return (ChatGPTCodexClient(tokenProvider: provider, session: session), store)
  }

  private func request() -> AIChatRequest {
    AIChatRequest(
      model: "gpt-5.1", system: "Be brief.",
      messages: [
        AIChatMessage(role: .user, text: "hi"), AIChatMessage(role: .assistant, text: "hello"),
      ])
  }

  private func collect(_ stream: AsyncThrowingStream<AIStreamEvent, Error>) async throws -> String {
    var text = ""
    for try await case .text(let piece) in stream { text += piece }
    return text
  }

  @Test("makeRequest sets url, headers and body without temperature, store false")
  func makeRequestShape() throws {
    let urlRequest = ChatGPTCodexClient.makeRequest(
      request(), baseURL: base, accessToken: "tok", accountID: "acct-1")
    #expect(urlRequest.httpMethod == "POST")
    #expect(urlRequest.url?.absoluteString == "https://chatgpt.com/backend-api/codex/responses")
    #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    #expect(urlRequest.value(forHTTPHeaderField: "ChatGPT-Account-ID") == "acct-1")
    #expect(urlRequest.value(forHTTPHeaderField: "OpenAI-Beta") == "responses=v1")
    #expect(urlRequest.value(forHTTPHeaderField: "originator") == "dblore")
    #expect(urlRequest.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let body = try #require(urlRequest.httpBody)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["model"] as? String == "gpt-5.1")
    #expect(json["instructions"] as? String == "Be brief.")
    #expect(json["stream"] as? Bool == true)
    #expect(json["store"] as? Bool == false)
    #expect(json["temperature"] == nil)
    #expect(json["max_output_tokens"] == nil)
    let input = try #require(json["input"] as? [[String: Any]])
    #expect(input.count == 2)
    #expect(input[0]["type"] as? String == "message")
    #expect(input[0]["role"] as? String == "user")
    let first = try #require((input[0]["content"] as? [[String: String]])?.first)
    #expect(first == ["type": "input_text", "text": "hi"])
    let second = try #require((input[1]["content"] as? [[String: String]])?.first)
    #expect(second == ["type": "output_text", "text": "hello"])
  }

  @Test("account header is omitted when the account id is unknown")
  func noAccountHeader() {
    let urlRequest = ChatGPTCodexClient.makeRequest(
      request(), baseURL: base, accessToken: "tok", accountID: nil)
    #expect(urlRequest.value(forHTTPHeaderField: "ChatGPT-Account-ID") == nil)
  }

  @Test("stream yields text from output_text deltas")
  func streamsText() async throws {
    AIStubURLProtocol.handler = { _ in
      let sse = """
        event: response.created
        data: {"type":"response.created","response":{"id":"r1"}}

        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"SELECT"}

        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":" 1"}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"r1"}}


        """
      return (200, [Data(sse.utf8)])
    }
    defer { AIStubURLProtocol.reset() }
    let (client, _) = setup(tokens: makeTokens())
    let text = try await collect(client.stream(request()))
    #expect(text == "SELECT 1")
    #expect(AIStubURLProtocol.lastRequest?.url?.path == "/backend-api/codex/responses")
    #expect(
      AIStubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization")
        == "Bearer access-1")
  }

  @Test("401 then a dead refresh wipes stored tokens and reports signed out")
  func unauthorizedWipes() async {
    AIStubURLProtocol.handler = { _ in (401, [Data(#"{"error":{"message":"nope"}}"#.utf8)]) }
    defer { AIStubURLProtocol.reset() }
    let (client, store) = setup(tokens: makeTokens())
    let stream = client.stream(request())
    await #expect(throws: AIClientError.http(status: 401, message: "Signed out of ChatGPT")) {
      _ = try await collect(stream)
    }
    #expect(ChatGPTTokenStorage.load(from: store) == nil)
  }

  @Test("403 keeps stored tokens and reports the server error")
  func forbiddenKeepsTokens() async {
    AIStubURLProtocol.handler = { _ in (403, [Data(#"{"error":{"message":"blocked"}}"#.utf8)]) }
    defer { AIStubURLProtocol.reset() }
    let (client, store) = setup(tokens: makeTokens())
    let stream = client.stream(request())
    await #expect(throws: AIClientError.http(status: 403, message: "blocked")) {
      _ = try await collect(stream)
    }
    #expect(ChatGPTTokenStorage.load(from: store)?.refreshToken == "refresh-1")
    #expect(AIStubURLProtocol.lastRequest?.url?.host == "chatgpt.com")
  }

  @Test("listModels 403 keeps stored tokens")
  func listModelsForbiddenKeepsTokens() async {
    AIStubURLProtocol.handler = { _ in (403, [Data("{}".utf8)]) }
    defer { AIStubURLProtocol.reset() }
    let (client, store) = setup(tokens: makeTokens())
    await #expect(throws: AIClientError.self) { _ = try await client.listModelsResult() }
    #expect(ChatGPTTokenStorage.load(from: store) != nil)
  }

  @Test("401 forces one refresh and one retry; success keeps the new tokens")
  func unauthorizedRefreshesAndRetries() async throws {
    let counter = RequestCounter()
    AIStubURLProtocol.handler = { req in
      counter.add(req.url?.host ?? "")
      if req.url?.host == "auth.openai.com" { return (200, [Self.refreshBody]) }
      if req.value(forHTTPHeaderField: "Authorization") == "Bearer access-1" {
        return (401, [Data("{}".utf8)])
      }
      return (
        200,
        [Data(#"data: {"type":"response.output_text.delta","delta":"ok"}"#.utf8 + [10, 10])]
      )
    }
    defer { AIStubURLProtocol.reset() }
    let (client, store) = setup(tokens: makeTokens())
    let text = try await collect(client.stream(request()))
    #expect(text == "ok")
    #expect(counter.hosts == ["chatgpt.com", "auth.openai.com", "chatgpt.com"])
    #expect(ChatGPTTokenStorage.load(from: store)?.accessToken == "access-2")
  }

  @Test("a second 401 after a good refresh does not wipe the tokens")
  func secondUnauthorizedKeepsTokens() async {
    AIStubURLProtocol.handler = { req in
      if req.url?.host == "auth.openai.com" { return (200, [Self.refreshBody]) }
      return (401, [Data(#"{"error":{"message":"nope"}}"#.utf8)])
    }
    defer { AIStubURLProtocol.reset() }
    let (client, store) = setup(tokens: makeTokens())
    let stream = client.stream(request())
    await #expect(throws: AIClientError.http(status: 401, message: "nope")) {
      _ = try await collect(stream)
    }
    #expect(ChatGPTTokenStorage.load(from: store)?.accessToken == "access-2")
  }

  @Test("missing tokens report signed out without a request")
  func noTokens() async {
    AIStubURLProtocol.handler = { _ in (200, []) }
    defer { AIStubURLProtocol.reset() }
    let (client, _) = setup(tokens: nil)
    let stream = client.stream(request())
    await #expect(throws: AIClientError.http(status: 401, message: "Signed out of ChatGPT")) {
      _ = try await collect(stream)
    }
    #expect(AIStubURLProtocol.lastRequest == nil)
  }

  private static let refreshBody = Data(
    #"{"access_token":"access-2","refresh_token":"refresh-2","id_token":"a.b.c","expires_in":3600}"#
      .utf8)

  @Test("expired tokens are refreshed before the request and saved")
  func refreshesWhenNeeded() async throws {
    AIStubURLProtocol.handler = { req in
      if req.url?.host == "auth.openai.com" { return (200, [Self.refreshBody]) }
      return (
        200,
        [Data(#"data: {"type":"response.output_text.delta","delta":"ok"}"#.utf8 + [10, 10])]
      )
    }
    defer { AIStubURLProtocol.reset() }
    let (client, store) = setup(tokens: makeTokens(expiresIn: 10))
    let text = try await collect(client.stream(request()))
    #expect(text == "ok")
    #expect(ChatGPTTokenStorage.load(from: store)?.accessToken == "access-2")
    #expect(
      AIStubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization")
        == "Bearer access-2")
  }

  @Test("valid tokens are not refreshed")
  func noRefreshWhenFresh() async throws {
    AIStubURLProtocol.handler = { _ in (200, []) }
    defer { AIStubURLProtocol.reset() }
    let (client, store) = setup(tokens: makeTokens())
    _ = try await collect(client.stream(request()))
    #expect(ChatGPTTokenStorage.load(from: store)?.accessToken == "access-1")
    #expect(AIStubURLProtocol.lastRequest?.url?.host == "chatgpt.com")
  }

  @Test("refresh 401 wipes tokens and reports signed out")
  func refreshUnauthorizedWipes() async {
    AIStubURLProtocol.handler = { _ in (401, [Data("{}".utf8)]) }
    defer { AIStubURLProtocol.reset() }
    let (client, store) = setup(tokens: makeTokens(expiresIn: 0))
    let stream = client.stream(request())
    await #expect(throws: AIClientError.http(status: 401, message: "Signed out of ChatGPT")) {
      _ = try await collect(stream)
    }
    #expect(ChatGPTTokenStorage.load(from: store) == nil)
  }

  @Test("refresh_token_reused wipes tokens")
  func refreshReusedWipes() async {
    AIStubURLProtocol.handler = { _ in
      (400, [Data(#"{"error":{"code":"refresh_token_reused"}}"#.utf8)])
    }
    defer { AIStubURLProtocol.reset() }
    let (client, store) = setup(tokens: makeTokens(expiresIn: 0))
    let stream = client.stream(request())
    await #expect(throws: AIClientError.http(status: 401, message: "Signed out of ChatGPT")) {
      _ = try await collect(stream)
    }
    #expect(ChatGPTTokenStorage.load(from: store) == nil)
  }

  @Test("5xx refresh response with a terminal-looking body does not wipe")
  func refreshServerErrorKeepsTokens() async {
    AIStubURLProtocol.handler = { _ in
      (503, [Data("upstream said refresh_token_reused".utf8)])
    }
    defer { AIStubURLProtocol.reset() }
    let (client, store) = setup(tokens: makeTokens(expiresIn: 0))
    let stream = client.stream(request())
    await #expect(throws: AIClientError.self) { _ = try await collect(stream) }
    #expect(ChatGPTTokenStorage.load(from: store)?.refreshToken == "refresh-1")
  }

  @Test("400 refresh with a non-terminal code does not wipe")
  func refreshOtherBadRequestKeepsTokens() async {
    AIStubURLProtocol.handler = { _ in
      (400, [Data(#"{"error":{"code":"invalid_request","message":"refresh_token_reused"}}"#.utf8)])
    }
    defer { AIStubURLProtocol.reset() }
    let (client, store) = setup(tokens: makeTokens(expiresIn: 0))
    let stream = client.stream(request())
    await #expect(throws: AIClientError.self) { _ = try await collect(stream) }
    #expect(ChatGPTTokenStorage.load(from: store) != nil)
  }

  // MARK: - Token provider lifecycle

  private func makeProvider(tokens: ChatGPTTokens?) -> (ChatGPTTokenProvider, InMemoryAIKeyStore) {
    let store = InMemoryAIKeyStore()
    if let tokens { ChatGPTTokenStorage.save(tokens, to: store) }
    return (ChatGPTTokenProvider(store: store, session: AIStubURLProtocol.makeSession()), store)
  }

  @Test("concurrent callers trigger exactly one refresh request")
  func concurrentRefreshCoalesces() async throws {
    let counter = RequestCounter()
    AIStubURLProtocol.handler = { req in
      counter.add(req.url?.host ?? "")
      Thread.sleep(forTimeInterval: 0.3)
      return (200, [Self.refreshBody])
    }
    defer { AIStubURLProtocol.reset() }
    let (provider, _) = makeProvider(tokens: makeTokens(expiresIn: 0))
    let results = try await withThrowingTaskGroup(of: String.self) { group in
      for _ in 0..<8 { group.addTask { try await provider.validTokens().accessToken } }
      var out: [String] = []
      for try await token in group { out.append(token) }
      return out
    }
    #expect(results == Array(repeating: "access-2", count: 8))
    #expect(counter.hosts.count == 1)
  }

  private func waitForRequest(_ counter: RequestCounter) async throws {
    for _ in 0..<200 where counter.hosts.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!counter.hosts.isEmpty)
  }

  @Test("sign out during an in-flight refresh does not resurrect tokens")
  func signOutDuringRefresh() async throws {
    let counter = RequestCounter()
    let gate = DispatchSemaphore(value: 0)
    AIStubURLProtocol.handler = { req in
      counter.add(req.url?.host ?? "")
      _ = gate.wait(timeout: .now() + 5)
      return (200, [Self.refreshBody])
    }
    defer { AIStubURLProtocol.reset() }
    let (provider, store) = makeProvider(tokens: makeTokens(expiresIn: 0))
    let pending = Task { try await provider.validTokens() }
    try await waitForRequest(counter)
    await provider.signOut()
    gate.signal()
    await #expect(throws: AIClientError.http(status: 401, message: "Signed out of ChatGPT")) {
      _ = try await pending.value
    }
    #expect(ChatGPTTokenStorage.load(from: store) == nil)
  }

  @Test("sign out then sign in during a refresh keeps the new tokens")
  func signInDuringRefreshKeepsNewTokens() async throws {
    let counter = RequestCounter()
    let gate = DispatchSemaphore(value: 0)
    AIStubURLProtocol.handler = { req in
      counter.add(req.url?.host ?? "")
      _ = gate.wait(timeout: .now() + 5)
      return (200, [Self.refreshBody])
    }
    defer { AIStubURLProtocol.reset() }
    let (provider, store) = makeProvider(tokens: makeTokens(expiresIn: 0))
    let pending = Task { try await provider.validTokens() }
    try await waitForRequest(counter)
    await provider.signOut()
    let saved = await provider.store(makeTokens(access: "access-B", refresh: "refresh-B"))
    #expect(saved)
    gate.signal()
    let result = try await pending.value
    #expect(result.accessToken == "access-B")
    #expect(ChatGPTTokenStorage.load(from: store)?.refreshToken == "refresh-B")
  }

  @Test("a stale 401 refresh response does not wipe newer tokens")
  func staleTerminalDoesNotWipeNewTokens() async throws {
    let counter = RequestCounter()
    let gate = DispatchSemaphore(value: 0)
    AIStubURLProtocol.handler = { req in
      counter.add(req.url?.host ?? "")
      _ = gate.wait(timeout: .now() + 5)
      return (401, [Data("{}".utf8)])
    }
    defer { AIStubURLProtocol.reset() }
    let (provider, store) = makeProvider(tokens: makeTokens(expiresIn: 0))
    let pending = Task { try await provider.validTokens() }
    try await waitForRequest(counter)
    _ = await provider.store(makeTokens(access: "access-B", refresh: "refresh-B"))
    gate.signal()
    _ = try? await pending.value
    #expect(ChatGPTTokenStorage.load(from: store)?.refreshToken == "refresh-B")
  }

  @Test("a failed save of rotated tokens surfaces an error")
  func failedSaveThrows() async {
    AIStubURLProtocol.handler = { _ in (200, [Self.refreshBody]) }
    defer { AIStubURLProtocol.reset() }
    let store = FailingSaveStore()
    ChatGPTTokenStorage.save(makeTokens(expiresIn: 0), to: store)
    store.failSaves = true
    let provider = ChatGPTTokenProvider(store: store, session: AIStubURLProtocol.makeSession())
    await #expect(throws: AIClientError.self) { _ = try await provider.validTokens() }
  }

  @Test("listModels keeps only visibility list and sends auth headers")
  func listModels() async throws {
    AIStubURLProtocol.handler = { _ in
      (
        200,
        [
          Data(
            #"{"models":[{"slug":"gpt-a","visibility":"list"},{"slug":"gpt-b","visibility":"hide"},{"slug":"gpt-c","visibility":"list"}]}"#
              .utf8)
        ]
      )
    }
    defer { AIStubURLProtocol.reset() }
    let (client, _) = setup(tokens: makeTokens())
    let result = try await client.listModelsResult()
    #expect(result.models == ["gpt-a", "gpt-c"])
    #expect(!result.isFallback)
    let last = AIStubURLProtocol.lastRequest
    #expect(last?.httpMethod == "GET")
    #expect(last?.url?.path == "/backend-api/codex/models")
    #expect(last?.url?.query == "client_version=1.0.0")
    #expect(last?.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
  }

  @Test("listModels falls back on server failure")
  func listModelsFallback() async throws {
    AIStubURLProtocol.handler = { _ in (500, [Data("{}".utf8)]) }
    defer { AIStubURLProtocol.reset() }
    let (client, _) = setup(tokens: makeTokens())
    let result = try await client.listModelsResult()
    #expect(result.isFallback)
    #expect(result.models == AIProviderKind.chatGPT.fallbackModels)
  }

  @Test("chatGPT kind is fixed, keyless and uses the responses wire")
  func kindProperties() {
    #expect(AIProviderKind.chatGPT.wire == .responses)
    #expect(!AIProviderKind.chatGPT.requiresAPIKey)
    #expect(AIProviderKind.chatGPT.defaultBaseURL == "https://chatgpt.com/backend-api/codex")
    #expect(AIProviderKind.chatGPT.displayName == "ChatGPT (subscription, experimental)")
  }

  @Test("factory builds a codex client ignoring the configured base URL")
  func factory() throws {
    let made = try AIClientFactory.make(
      kind: .chatGPT, config: AIProviderConfig(baseURL: "https://evil.example/v1", model: "m"),
      apiKey: nil, session: AIStubURLProtocol.makeSession())
    #expect(made is ChatGPTCodexClient)
  }

  // MARK: - Responses wire parser

  private func run(_ lines: [String]) throws -> [AIStreamDelta] {
    var parser = AISSEParser(wire: .responses)
    var out: [AIStreamDelta] = []
    for line in lines { out += try parser.consume(line: line) }
    return out
  }

  @Test("responses wire: text deltas then done on completed")
  func parserText() throws {
    let out = try run([
      #"data: {"type":"response.output_text.delta","delta":"a"}"#, "",
      #"data: {"type":"response.reasoning_summary_text.delta","delta":"ignored"}"#, "",
      #"data: {"type":"response.output_text.delta","delta":"b"}"#, "",
      #"data: {"type":"response.completed","response":{}}"#, "",
    ])
    #expect(out == [.text("a"), .text("b"), .done])
  }

  @Test("responses wire: event name is used when type is absent")
  func parserEventName() throws {
    let out = try run(["event: response.output_text.delta", #"data: {"delta":"x"}"#, ""])
    #expect(out == [.text("x")])
  }

  @Test("responses wire: failed throws the response error message")
  func parserFailed() {
    #expect(throws: AIStreamError.provider("Rate limited")) {
      _ = try run([
        #"data: {"type":"response.failed","response":{"error":{"code":"x","message":"Rate limited"}}}"#,
        "",
      ])
    }
  }

  @Test("responses wire: error event throws its message")
  func parserError() {
    #expect(throws: AIStreamError.provider("Boom")) {
      _ = try run([#"data: {"type":"error","message":"Boom"}"#, ""])
    }
    #expect(throws: AIStreamError.provider("Nested")) {
      _ = try run([#"data: {"type":"error","error":{"message":"Nested"}}"#, ""])
    }
  }
}

private final class RequestCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [String] = []
  var hosts: [String] { lock.withLock { stored } }
  func add(_ host: String) { lock.withLock { stored.append(host) } }
}

private final class FailingSaveStore: AIKeyStore, @unchecked Sendable {
  private let inner = InMemoryAIKeyStore()
  nonisolated(unsafe) var failSaves = false
  func load(account: String) -> String? { inner.load(account: account) }
  func save(_ value: String, account: String) -> Bool {
    failSaves ? false : inner.save(value, account: account)
  }
  func delete(account: String) { inner.delete(account: account) }
}
