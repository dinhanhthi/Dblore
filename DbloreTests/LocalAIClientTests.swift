// LocalAIClientTests.swift
// The app side of the On-device AI plugin against a fake entry point (no bundle is loaded):
// LocalAIRuntime's handshake, routing, timeout, unload and stop rules, and LocalAIChatClient's
// request building and event mapping.

import Foundation
import Testing

@testable import Dblore

@Suite struct LocalAIClientTests {
  typealias Request = LocalAIProtocol.Request

  private struct TestFailure: Error {}

  /// A fake plugin behind the C entry point shape: it answers `hello` during the call, as the
  /// plugin does, and keeps every other request with its callback for the test to answer later,
  /// from another thread.
  private final class FakePlugin: @unchecked Sendable {
    private struct Sink: @unchecked Sendable {
      let context: UnsafeMutableRawPointer?
      let emit: LocalAIEntryPoint.Emit
      func send(_ line: String) { line.withCString { emit(context, $0) } }
    }

    private let lock = NSLock()
    private var received: [(request: Request, sink: Sink)] = []
    private let protocolVersion: Int32
    private let helloProtocol: Int

    init(protocolVersion: Int32 = 1, helloProtocol: Int = 1) {
      self.protocolVersion = protocolVersion
      self.helloProtocol = helloProtocol
    }

    var entryPoint: LocalAIEntryPoint {
      LocalAIEntryPoint(
        protocolVersion: { self.protocolVersion },
        send: { json, context, emit in self.receive(json, Sink(context: context, emit: emit)) })
    }

    var requests: [Request] { lock.withLock { received.map(\.request) } }

    private func receive(_ json: String, _ sink: Sink) {
      guard let request = LocalAIProtocol.decodeRequest(Data(json.utf8)) else { return }
      if case .hello = request.kind {
        return sink.send(
          #"{"event":"hello","id":"\#(request.id)","protocol":\#(helloProtocol),"version":"1.0.0"}"#
        )
      }
      lock.withLock { received.append((request, sink)) }
    }

    /// The first request `match` accepts, waiting up to 5 s for it.
    func request(where match: (Request) -> Bool) async throws -> Request {
      for _ in 0..<500 {
        if let request = requests.first(where: match) { return request }
        try await Task.sleep(for: .milliseconds(10))
      }
      throw TestFailure()
    }

    /// Emits each line to the request `id`, with `$ID` replaced by that id.
    func reply(to id: String, _ lines: String...) {
      let sink = lock.withLock { received.first { $0.request.id == id }?.sink }
      for line in lines { sink?.send(line.replacingOccurrences(of: "$ID", with: id)) }
    }
  }

  private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
  }

  private static let modelID = "qwen3.5-2b"

  /// A per-run Models root in the container tmp folder holding one installed (stub) model.
  private static func makeModelsRoot(installing id: String = modelID) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("LocalAIClientTests-\(UUID().uuidString)", isDirectory: true)
    let model = root.appendingPathComponent(id, isDirectory: true)
    try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: model.appendingPathComponent("config.json"))
    try Data().write(to: model.appendingPathComponent("model.safetensors"))
    return root
  }

  private static let chat = AIChatRequest(
    model: modelID, system: "", messages: [AIChatMessage(role: .user, text: "count?")])

  private static func collect(
    _ stream: AsyncThrowingStream<AIStreamEvent, Error>
  ) async throws -> [AIStreamEvent] {
    var events: [AIStreamEvent] = []
    for try await event in stream { events.append(event) }
    return events
  }

  private static func isGenerate(_ request: Request) -> Bool {
    if case .generate = request.kind { return true }
    return false
  }

  /// Loads the runtime through one chat that the plugin answers with `done`.
  private static func load(_ client: LocalAIChatClient, _ plugin: FakePlugin) async throws {
    let consumer = Task { try await collect(client.stream(chat)) }
    let generate = try await plugin.request(where: isGenerate)
    plugin.reply(to: generate.id, #"{"event":"done","id":"$ID"}"#)
    _ = try await consumer.value
  }

  /// Guards the core chat path: the generate request carries today's MLX settings (clamped
  /// maxTokens, temperature 0, thinking off for qwen3 only, text blocks only, never tools), and
  /// the plugin's events reach the caller as loadingModel and text until done.
  @Test(arguments: [("qwen3.5-2b", false as Bool?), ("gemma-4-12b", nil)])
  func chatSendsGenerateAndMapsEventsUntilDone(modelID: String, thinking: Bool?) async throws {
    let root = try Self.makeModelsRoot(installing: modelID)
    defer { try? FileManager.default.removeItem(at: root) }
    let plugin = FakePlugin()
    let client = LocalAIChatClient(
      root: root, runtime: LocalAIRuntime(loader: { plugin.entryPoint }, timeout: .seconds(10)))
    let call = AIToolCall(id: "c1", name: "run_read_query", inputJSON: #"{"sql":"SELECT 1"}"#)
    var request = AIChatRequest(
      model: modelID, system: "be brief",
      messages: [
        AIChatMessage(role: .user, text: "count?"),
        AIChatMessage(role: .assistant, blocks: [.text("Checking."), .toolUse(call)]),
        AIChatMessage(
          role: .user,
          blocks: [
            .toolResult(AIToolResult(id: "c1", content: "42 rows", isError: false)),
            .text("thanks"),
          ]),
      ],
      maxTokens: 100_000)
    request.tools = [
      AIToolSpec(
        name: "run_read_query", description: "Run one read-only query",
        parameters: .object(["type": .string("object")]))
    ]
    let consumer = Task { try await Self.collect(client.stream(request)) }

    let generate = try await plugin.request(where: Self.isGenerate)
    let expected = Request.Generate(
      modelID: modelID,
      modelPath: root.appendingPathComponent(modelID, isDirectory: true).path,
      system: "be brief",
      messages: [
        .init(role: .user, text: "count?"), .init(role: .assistant, text: "Checking."),
        .init(role: .user, text: "thanks"),
      ],
      maxTokens: 4096, temperature: 0, context: thinking.map { .init(enableThinking: $0) })
    #expect(generate.kind == .generate(expected))
    plugin.reply(
      to: generate.id, #"{"event":"loading","id":"$ID"}"#, #"{"event":"loaded","id":"$ID"}"#,
      #"{"chunk":"SELECT ","event":"text","id":"$ID"}"#,
      #"{"chunk":"1","event":"text","id":"$ID"}"#, #"{"event":"done","id":"$ID"}"#)
    #expect(try await consumer.value == [.loadingModel, .text("SELECT "), .text("1")])
  }

  /// Guards how a request ends when the plugin fails it: `busy` keeps the app's own message, a
  /// load error carries the plugin's text, and an event the app cannot decode (here an error code
  /// from a newer plugin) still ends that request instead of leaving it hanging.
  @Test(arguments: [
    (
      #"{"code":"busy","event":"error","id":"$ID","message":"engine busy"}"#,
      AIClientError.transport("Local model is busy")
    ),
    (
      #"{"code":"load","event":"error","id":"$ID","message":"No weights in qwen3.5-2b"}"#,
      .transport("No weights in qwen3.5-2b")
    ),
    (
      #"{"code":"overheated","event":"error","id":"$ID","message":"hot"}"#,
      .transport("The On-device AI plugin sent an answer Dblore cannot read.")
    ),
  ])
  func pluginFailureEndsTheChat(event: String, expected: AIClientError) async throws {
    let root = try Self.makeModelsRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let plugin = FakePlugin()
    let client = LocalAIChatClient(
      root: root, runtime: LocalAIRuntime(loader: { plugin.entryPoint }, timeout: .seconds(10)))
    let consumer = Task { try await Self.collect(client.stream(Self.chat)) }

    let generate = try await plugin.request(where: Self.isGenerate)
    plugin.reply(to: generate.id, event)
    await #expect(throws: expected) { try await consumer.value }
  }

  /// Guards that nothing can hang: a request the plugin never answers fails with transport, and
  /// the plugin is told to stop it (`cancel`), so its engine is not left busy for the next chat.
  @Test func unansweredRequestTimesOut() async throws {
    let root = try Self.makeModelsRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let plugin = FakePlugin()
    let client = LocalAIChatClient(
      root: root,
      runtime: LocalAIRuntime(loader: { plugin.entryPoint }, timeout: .milliseconds(200)))
    let consumer = Task { try await Self.collect(client.stream(Self.chat)) }
    let generate = try await plugin.request(where: Self.isGenerate)

    await #expect(
      throws: AIClientError.transport("The On-device AI plugin did not answer in time.")
    ) {
      try await consumer.value
    }
    let cancel = try await plugin.request { $0.kind == .cancel(target: generate.id) }
    #expect(cancel.id != generate.id)
  }

  /// Guards Stop and yielding the on-device model to a foreground chat: cancelling the stream
  /// sends `cancel` for that request's id, under its own id, so a chat started after it comes
  /// second and the engine waits behind the cancelled request instead of answering busy.
  @Test func cancelReachesThePluginBeforeTheNextChat() async throws {
    let root = try Self.makeModelsRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let plugin = FakePlugin()
    let client = LocalAIChatClient(
      root: root, runtime: LocalAIRuntime(loader: { plugin.entryPoint }, timeout: .seconds(10)))
    let first = Task { try await Self.collect(client.stream(Self.chat)) }
    let generate = try await plugin.request(where: Self.isGenerate)

    first.cancel()
    let second = Task { try await Self.collect(client.stream(Self.chat)) }
    let next = try await plugin.request { Self.isGenerate($0) && $0.id != generate.id }
    let cancel = try await plugin.request { $0.kind == .cancel(target: generate.id) }
    #expect(cancel.id != generate.id)
    let requests = plugin.requests
    let cancelIndex = try #require(requests.firstIndex { $0.id == cancel.id })
    let nextIndex = try #require(requests.firstIndex { $0.id == next.id })
    #expect(cancelIndex < nextIndex)
    plugin.reply(to: next.id, #"{"event":"done","id":"$ID"}"#)
    _ = try await second.value
  }

  /// Guards the unloader rules model deletion relies on: before the plugin was ever loaded no
  /// model can be resident (true, and the plugin is not loaded for it); afterwards the plugin's
  /// answer is returned (false while the model is in use).
  @Test func unloadIsTrueBeforeAnyLoadThenForwardsThePluginAnswer() async throws {
    let root = try Self.makeModelsRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let plugin = FakePlugin()
    let loads = Counter()
    let runtime = LocalAIRuntime(
      loader: {
        loads.increment()
        return plugin.entryPoint
      }, timeout: .seconds(10))

    #expect(await runtime.unload(modelID: Self.modelID))
    #expect(loads.value == 0)

    try await Self.load(LocalAIChatClient(root: root, runtime: runtime), plugin)
    async let answer = runtime.unload(modelID: Self.modelID)
    let unload = try await plugin.request { $0.kind == .unload(modelID: Self.modelID) }
    plugin.reply(to: unload.id, #"{"event":"unloaded","id":"$ID","ok":false}"#)
    #expect(await answer == false)
  }

  enum LoadFailure: String, CaseIterable, Sendable {
    case loaderThrows, loaderThrowsAfterLoadingCode, protocolFunctionIs2, helloReports2
  }

  /// Guards the load and handshake: a loader failure, or a plugin speaking another protocol,
  /// gives pluginMissing and sends no generate. Only a load that loaded nothing is retried; code
  /// already loaded (or possibly mapped) is never loaded again in this process.
  @Test(arguments: [
    (LoadFailure.loaderThrows, 2), (.loaderThrowsAfterLoadingCode, 1), (.protocolFunctionIs2, 1),
    (.helloReports2, 1),
  ])
  func unusablePluginGivesPluginMissing(
    failure: LoadFailure, expectedLoads: Int
  )
    async throws
  {
    let root = try Self.makeModelsRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let plugin =
      switch failure {
      case .loaderThrows, .loaderThrowsAfterLoadingCode: FakePlugin()
      case .protocolFunctionIs2: FakePlugin(protocolVersion: 2)
      case .helloReports2: FakePlugin(helloProtocol: 2)
      }
    let loads = Counter()
    let runtime = LocalAIRuntime(
      loader: {
        loads.increment()
        if failure == .loaderThrows { throw TestFailure() }
        if failure == .loaderThrowsAfterLoadingCode {
          throw LocalAIRuntime.LoadFailure(description: "code mapped", codeLoaded: true)
        }
        return plugin.entryPoint
      }, timeout: .seconds(10))
    let client = LocalAIChatClient(root: root, runtime: runtime)

    for _ in 0..<2 {
      await #expect(throws: AIClientError.pluginMissing) {
        try await Self.collect(client.stream(Self.chat))
      }
    }
    #expect(loads.value == expectedLoads)
    #expect(!plugin.requests.contains(where: Self.isGenerate))
  }

  /// Guards Remove (`stop()` is the manager's beforeRemove hook): it unloads every model once,
  /// a second call made meanwhile waits for that same work instead of sending another unload, and
  /// afterwards chats give pluginMissing without reaching the plugin.
  @Test func stopUnloadsOnceThenChatsGivePluginMissing() async throws {
    let root = try Self.makeModelsRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let plugin = FakePlugin()
    let runtime = LocalAIRuntime(loader: { plugin.entryPoint }, timeout: .seconds(10))
    let client = LocalAIChatClient(root: root, runtime: runtime)
    try await Self.load(client, plugin)

    let first = Task { await runtime.stop() }
    let unload = try await plugin.request { $0.kind == .unload(modelID: nil) }
    let secondDone = Counter()
    let second = Task {
      await runtime.stop()
      secondDone.increment()
    }
    try await Task.sleep(for: .milliseconds(50))
    #expect(secondDone.value == 0)
    plugin.reply(to: unload.id, #"{"event":"unloaded","id":"$ID","ok":true}"#)
    await first.value
    await second.value

    #expect(plugin.requests.filter { $0.kind == .unload(modelID: nil) }.count == 1)
    await #expect(throws: AIClientError.pluginMissing) {
      try await Self.collect(client.stream(Self.chat))
    }
    #expect(plugin.requests.filter(Self.isGenerate).count == 1)
  }
}
