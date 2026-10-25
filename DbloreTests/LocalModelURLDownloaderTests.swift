import CryptoKit
import Foundation
import Testing

@testable import Dblore

/// The default model downloader over `ModelDownloadStubURLProtocol`. Serialized: the stub state
/// is static.
@MainActor
@Suite(.serialized)
struct LocalModelURLDownloaderTests {
  private typealias Stub = ModelDownloadStubURLProtocol

  private func makeRoot() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "LocalModelURLDownloaderTests-\(UUID().uuidString)", isDirectory: true)
  }

  private func pin(_ name: String, _ body: Data) -> LocalModel.File {
    LocalModel.File(
      name: name, size: Int64(body.count),
      sha256: SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined())
  }

  /// Downloads the first catalog model with the stub over a temp root that already holds an
  /// install of it; expects the install byte-identical and staging gone, returns the final state.
  private func runOverExistingInstall() async throws -> LocalModelDownloadState? {
    let model = LocalModelCatalog.all[0]
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = LocalModelManager(
      root: root, downloader: LocalModelManager.urlDownloader(session: Stub.makeSession()),
      unloader: { _ in true })
    let installed = manager.directory(for: model)
    let markers = [
      "config.json": Data("old config".utf8), "model.safetensors": Data("old weights".utf8),
    ]
    try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
    for (name, data) in markers { try data.write(to: installed.appendingPathComponent(name)) }
    await manager.refreshInstalled()
    await manager.run(model)
    for (name, data) in markers {
      #expect(try Data(contentsOf: installed.appendingPathComponent(name)) == data)
    }
    #expect(
      Set(try FileManager.default.contentsOfDirectory(atPath: installed.path)) == Set(markers.keys))
    #expect(
      !FileManager.default.fileExists(
        atPath: root.appendingPathComponent(".staging-\(model.id)").path))
    return manager.state[model.id]
  }

  @Test func downloadsExactlyThePinnedFilesOfThePinnedRevision() async throws {
    let bodies = [
      "config.json": Data(#"{"model_type":"stub"}"#.utf8),
      "model.safetensors": Data((0..<3_000).map { UInt8($0 % 251) }),
    ]
    let model = LocalModel(
      id: "stub", repoID: "org/stub-model", revision: String(repeating: "a", count: 40),
      displayName: "Stub", tier: .tiny, approxSizeBytes: 3_100, minRAMBytes: 1, license: "x",
      note: "x",
      files: ["config.json", "model.safetensors"].map { pin($0, bodies[$0]!) })
    Stub.reset()
    defer { Stub.reset() }
    Stub.handler = { url in .respond(status: 200, body: bodies[url.lastPathComponent] ?? Data()) }
    let staging = makeRoot()
    defer { try? FileManager.default.removeItem(at: staging) }
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

    try await LocalModelManager.urlDownloader(session: Stub.makeSession())(model, staging) { _ in }

    for (name, body) in bodies {
      #expect(try Data(contentsOf: staging.appendingPathComponent(name)) == body)
    }
    #expect(
      Set(try FileManager.default.contentsOfDirectory(atPath: staging.path)) == Set(bodies.keys))
    #expect(
      Stub.requestedURLs.map(\.absoluteString) == [
        "https://huggingface.co/org/stub-model/resolve/\(model.revision)/config.json",
        "https://huggingface.co/org/stub-model/resolve/\(model.revision)/model.safetensors",
      ])
  }

  @Test func checksumMismatchFailsAndKeepsExistingInstall() async throws {
    let first = LocalModelCatalog.all[0].files[0]
    Stub.reset()
    defer { Stub.reset() }
    // Right size, wrong bytes: only the SHA-256 check catches it
    Stub.handler = { url in
      url.lastPathComponent == first.name
        ? .respond(status: 200, body: Data(repeating: 0, count: Int(first.size)))
        : .respond(status: 404, body: Data())
    }
    let state = try await runOverExistingInstall()
    #expect(state == .failed("Download check failed for \(first.name)."))
  }

  @Test func plainHTTPRedirectIsRefusedAndKeepsExistingInstall() async throws {
    Stub.reset()
    defer { Stub.reset() }
    Stub.handler = { url in
      url.scheme == "https"
        ? .redirect(URL(string: "http://cdn.example.com/\(url.lastPathComponent)")!)
        : .respond(status: 200, body: Data())
    }
    let state = try await runOverExistingInstall()
    if case .failed = state {} else { Issue.record("expected failed state") }
    #expect(Stub.requestedURLs.count == 1)
    #expect(!Stub.requestedURLs.contains { $0.scheme == "http" })
  }
}
