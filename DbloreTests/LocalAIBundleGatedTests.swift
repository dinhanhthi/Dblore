// LocalAIBundleGatedTests.swift
// The On-device AI plugin bundle loads in process from the sandboxed test host: the notarized
// bundle the host unpacks itself (so the sandbox quarantines it) passes PluginLoader.loadBundle,
// exports its two C entry points, and answers hello and gpuProbe through the C callback.

import Darwin
import Foundation
import Testing

@testable import Dblore

/// The loaded bundle stays in the test process until it exits, so this suite holds one test.
@Suite(.serialized, .requiresLocalAIPlugin) struct LocalAIBundleGatedTests {
  private typealias ProtocolFunction = @convention(c) () -> Int32
  private typealias Emit = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>) -> Void
  private typealias RequestFunction =
    @convention(c) (UnsafePointer<CChar>, UnsafeMutableRawPointer?, Emit) -> Void

  private struct TestFailure: Error, CustomStringConvertible { let description: String }

  private struct DevCatalog: Decodable {
    let version: String
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

  @Test func quarantinedNotarizedBundleLoadsAndAnswersHelloAndGPUProbe() throws {
    let catalog = try Self.devCatalog()
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("local-ai-bundle-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // The sandboxed host writes these files itself, so the sandbox may quarantine them.
    let ditto = Process()
    ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    ditto.arguments = [
      "-x", "-k", Self.pluginDev.appendingPathComponent("DbloreLocalAI.zip").path, dir.path,
    ]
    try ditto.run()
    ditto.waitUntilExit()
    try #require(ditto.terminationStatus == 0)
    let url = dir.appendingPathComponent(catalog.bundleName, isDirectory: true)
    print(
      "LocalAIBundleGatedTests quarantine: bundle \(Self.quarantine(of: url)), executable \(Self.quarantine(of: url.appendingPathComponent("Contents/MacOS/DbloreLocalAI")))"
    )

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
}
