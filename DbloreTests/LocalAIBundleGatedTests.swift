// LocalAIBundleGatedTests.swift
// The On-device AI plugin, end to end in the sandboxed test host: the shipped catalog's local-ai
// entry pins the notarized zip, which installs with that entry through PluginManager with the
// production verifier (so the sandbox quarantines the files it writes). LocalAIRuntime's
// production loader loads that installed bundle, a chat through LocalAIChatClient gets the
// plugin's own model load error, and the bundle exports its two C entry points and answers hello
// and gpuProbe through the C callback.

import Darwin
import Foundation
import Testing

@testable import Dblore

/// The loaded bundle stays in the test process until it exits, and loading it from a second path
/// would load a second copy of its code, so only one case loads it, once, from the path its
/// manager installed; the install case installs and verifies another copy but never loads it.
@Suite(.serialized, .requiresLocalAIPlugin) struct LocalAIBundleGatedTests {
  private typealias ProtocolFunction = @convention(c) () -> Int32
  private typealias Emit = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>) -> Void
  private typealias RequestFunction =
    @convention(c) (UnsafePointer<CChar>, UnsafeMutableRawPointer?, Emit) -> Void

  private struct TestFailure: Error, CustomStringConvertible { let description: String }

  private struct DevCatalog: Decodable {
    let version: String
    let sha256: String
    let cdhash: String
    let bundleName: String
    let notarized: Bool
  }

  /// The event JSON strings the plugin emits, from any thread.
  private final class EventCollector: @unchecked Sendable {
    private let condition = NSCondition()
    private var events: [String] = []

    func append(_ event: String) {
      condition.lock()
      events.append(event)
      condition.broadcast()
      condition.unlock()
    }

    var all: [String] {
      condition.lock()
      defer { condition.unlock() }
      return events
    }

    /// The first event object that echoes `id`, waiting up to `timeout` for it.
    func event(id: String, timeout: TimeInterval) -> [String: Any]? {
      let deadline = Date(timeIntervalSinceNow: timeout)
      condition.lock()
      defer { condition.unlock() }
      while true {
        let match = events.lazy
          .compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
          .first { $0["id"] as? String == id }
        if let match { return match }
        if !condition.wait(until: deadline) { return nil }
      }
    }
  }

  /// Constant; the dev catalog does not carry it.
  private static let bundleIdentifier = "ace.thi.Dblore.LocalAI"

  /// A catalog model, so the chat client looks for its folder.
  private static let modelID = "qwen3.5-2b"

  private static let pluginDev = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent(".plugin-dev/local-ai", isDirectory: true)

  private static func devCatalog() throws -> DevCatalog {
    let data = try Data(contentsOf: pluginDev.appendingPathComponent("dev-catalog.json"))
    let catalog = try JSONDecoder().decode(DevCatalog.self, from: data)
    // A non-notarized bundle is never loaded: Gatekeeper would refuse it.
    guard catalog.notarized else { throw TestFailure(description: "dev plugin not notarized") }
    return catalog
  }

  private static func quarantine(of url: URL) -> String {
    var buffer = [UInt8](repeating: 0, count: 256)
    let length = getxattr(url.path, "com.apple.quarantine", &buffer, buffer.count, 0, 0)
    if length < 0 {
      let code = errno
      return code == ENOATTR ? "absent" : "getxattr failed: \(String(cString: strerror(code)))"
    }
    return "present (\(String(decoding: buffer[..<length], as: UTF8.self)))"
  }

  /// A per-run plugin root in the container's Application Support, where the real one lives.
  private static func makePluginRoot() throws -> URL {
    let support = try #require(
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
    return support.appendingPathComponent(
      "Dblore/Plugins/local-ai-test/\(UUID().uuidString)", isDirectory: true)
  }

  /// Removes `root`, then its `local-ai-test` parent only when no other run's root is left in it.
  private static func removePluginRoot(_ root: URL) {
    try? FileManager.default.removeItem(at: root)
    rmdir(root.deletingLastPathComponent().path)
  }

  /// Installs the notarized dev zip with `entry` into `root` through a dedicated PluginManager
  /// with the production verifier; the download comes from the stub.
  @MainActor private static func install(
    entry: PluginCatalogEntry, root: URL
  ) async throws -> PluginManager {
    let zip = try Data(contentsOf: pluginDev.appendingPathComponent("DbloreLocalAI.zip"))
    PluginStubURLProtocol.respond(with: zip)
    let manager = PluginManager(
      entry: entry, root: root, session: PluginStubURLProtocol.makeSession())
    await manager.refresh()
    #expect(manager.state == .notInstalled)
    await manager.install()
    try #require(manager.isInstalled, "\(manager.state)")
    return manager
  }

  /// Guards the on-device chat path through the real plugin, and its load in the sandbox. The
  /// plugin installed with the shipped entry (quarantined by the sandbox) is loaded by a fresh
  /// LocalAIRuntime's production loader (Team ID, cdhash, handshake); a chat for a model folder
  /// whose config is empty reaches the plugin's engine and fails with the plugin's load error,
  /// not pluginMissing; unload then answers true. The same installed path, loaded again (Bundle
  /// keeps the image it loaded), exports the C entry points, answers hello and gpuProbe, and is
  /// among the bundles MLX searches for its metallib.
  @MainActor @Test func installedPluginRunsAChatThroughTheRuntimeAndAnswersHelloAndGPUProbe()
    async throws
  {
    let catalog = try Self.devCatalog()
    let entry = try #require(PluginCatalog.bundled().entry(id: "local-ai"))
    let pluginRoot = try Self.makePluginRoot()
    let modelsRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("LocalAIBundleGatedTests-\(UUID().uuidString)", isDirectory: true)
    defer {
      Self.removePluginRoot(pluginRoot)
      try? FileManager.default.removeItem(at: modelsRoot)
    }
    // Counts as installed (config.json plus a .safetensors file); the empty config fails to load.
    let model = modelsRoot.appendingPathComponent(Self.modelID, isDirectory: true)
    try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: model.appendingPathComponent("config.json"))
    try Data().write(to: model.appendingPathComponent("model.safetensors"))

    let manager = try await Self.install(entry: entry, root: pluginRoot)
    let url = try #require(manager.installedURL)
    print(
      "LocalAIBundleGatedTests quarantine: executable \(Self.quarantine(of: url.appendingPathComponent("Contents/MacOS/DbloreLocalAI")))"
    )
    let runtime = LocalAIRuntime(loader: LocalAIRuntime.pluginLoader(manager: manager))
    defer { await runtime.stop() }

    let client = LocalAIChatClient(root: modelsRoot, runtime: runtime)
    let chat = AIChatRequest(
      model: Self.modelID, system: "", messages: [AIChatMessage(role: .user, text: "hi")])
    var events: [AIStreamEvent] = []
    do {
      for try await event in client.stream(chat) { events.append(event) }
      Issue.record("the chat ended without the plugin's load error: \(events)")
    } catch let error as AIClientError {
      print("LocalAIBundleGatedTests chat error: \(error)")
      #expect(error != .pluginMissing)
      // The plugin's message names the config it could not parse; the app's own messages
      // (download first, busy, timeout, unreadable) never mention it.
      let message: String? = if case .transport(let message) = error { message } else { nil }
      #expect(message?.localizedCaseInsensitiveContains("config") == true, "\(error)")
    }
    // The plugin's loading event came first, so the request reached its engine.
    #expect(events == [.loadingModel])
    let unloaded = await runtime.unload(modelID: Self.modelID)
    #expect(unloaded)

    let bundle = try PluginLoader.loadBundle(
      at: url, expectedTeamID: PluginLoader.teamIdentifier, expectedCDHash: catalog.cdhash)
    #expect(bundle.isLoaded)
    // MLX loads default.metallib from the first of these bundles (Bundle.allBundles order).
    let metallibBundles = Bundle.allBundles.compactMap { candidate -> String? in
      guard
        let resources = candidate.resourceURL,
        FileManager.default.fileExists(
          atPath: resources.appendingPathComponent("mlx-swift_Cmlx.bundle").path)
      else { return nil }
      return candidate.bundleURL.resolvingSymlinksInPath().path
    }
    print("LocalAIBundleGatedTests bundles with mlx-swift_Cmlx.bundle: \(metallibBundles)")
    // Bundle.load, not a bare dlopen, puts the plugin bundle among them.
    #expect(metallibBundles.contains(bundle.bundleURL.resolvingSymlinksInPath().path))

    // RTLD_NOLOAD: a handle only for the image loadBundle already loaded.
    let executable = try #require(bundle.executableURL)
    let handle = try #require(dlopen(executable.path, RTLD_NOW | RTLD_LOCAL | RTLD_NOLOAD))
    defer { dlclose(handle) }
    let protocolVersion = unsafeBitCast(
      try #require(dlsym(handle, "dblore_localai_protocol")), to: ProtocolFunction.self)
    let request = unsafeBitCast(
      try #require(dlsym(handle, "dblore_localai_request")), to: RequestFunction.self)
    #expect(protocolVersion() == 1)

    let collector = EventCollector()
    // The string is valid only during the call, so it is copied here.
    let emit: Emit = { context, json in
      guard let context else { return }
      Unmanaged<EventCollector>.fromOpaque(context).takeUnretainedValue()
        .append(String(cString: json))
    }
    // Both answer on this thread, before the call returns.
    let (hello, gpu) = withExtendedLifetime(collector) {
      let context = Unmanaged.passUnretained(collector).toOpaque()
      request(#"{"id":"1","type":"hello"}"#, context, emit)
      let hello = collector.event(id: "1", timeout: 30)
      request(#"{"id":"2","type":"gpuProbe"}"#, context, emit)
      return (hello, collector.event(id: "2", timeout: 60))
    }
    for line in collector.all { print("LocalAIBundleGatedTests event: \(line)") }

    let helloEvent = try #require(hello)
    #expect(helloEvent["event"] as? String == "hello")
    #expect((helloEvent["protocol"] as? NSNumber)?.intValue == 1)
    #expect(helloEvent["version"] as? String == catalog.version)
    let gpuEvent = try #require(gpu)
    #expect(gpuEvent["event"] as? String == "gpu")
    #expect(gpuEvent["ok"] as? Bool == true)
    #expect((gpuEvent["value"] as? NSNumber)?.doubleValue == 12)
  }

  /// Guards the shipped pins and the real install path: the local-ai entry of the bundled
  /// PluginCatalog.json pins the notarized artifact (its version, zip SHA-256, bundle name,
  /// identifier and cdhash), and with that entry the notarized zip installs through PluginManager
  /// with the production verifier (Team ID, pinned cdhash, sealed resources) at
  /// `local-ai/<version>/<bundleName>`, and a fresh manager's launch check reads it as installed.
  /// The root is a per-run folder in the container's Application Support, where the real one lives.
  @MainActor @Test func notarizedZipInstallsWithTheProductionVerifier() async throws {
    let catalog = try Self.devCatalog()
    let root = try Self.makePluginRoot()
    defer { Self.removePluginRoot(root) }
    // The shipped entry itself, not one rebuilt from the dev catalog: a stale or mistyped pin
    // fails here rather than in every user's install.
    let entry = try #require(PluginCatalog.bundled().entry(id: "local-ai"))
    #expect(entry.sha256 == catalog.sha256)
    #expect(entry.version == catalog.version)
    #expect(
      entry.kind
        == .bundle(
          name: catalog.bundleName, identifier: Self.bundleIdentifier, cdhash: catalog.cdhash))
    let manager = try await Self.install(entry: entry, root: root)

    #expect(
      manager.installedURL?.path
        == root.path + "/local-ai/\(catalog.version)/\(catalog.bundleName)")
    let fresh = PluginManager(
      entry: entry, root: root, session: PluginStubURLProtocol.makeSession())
    await fresh.refresh()
    #expect(fresh.isInstalled, "\(fresh.state)")
  }
}
