import Foundation
import Testing

@testable import Dblore

@MainActor
struct LocalModelManagerTests {
  private let model = LocalModelCatalog.all[0]

  private func makeRoot() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("LocalModelManagerTests-\(UUID().uuidString)", isDirectory: true)
  }

  private func write(_ names: [String], in dir: URL) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for n in names { try Data("x".utf8).write(to: dir.appendingPathComponent(n)) }
  }

  @Test func installedNeedsConfigAndSafetensors() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let noConfig = root.appendingPathComponent("a")
    try write(["model.safetensors"], in: noConfig)
    let noWeights = root.appendingPathComponent("b")
    try write(["config.json", "tokenizer.json"], in: noWeights)
    let both = root.appendingPathComponent("c")
    try write(["config.json", "model.safetensors"], in: both)
    #expect(!LocalModelManager.isInstalled(at: noConfig))
    #expect(!LocalModelManager.isInstalled(at: noWeights))
    #expect(LocalModelManager.isInstalled(at: both))
    #expect(!LocalModelManager.isInstalled(at: root.appendingPathComponent("missing")))
  }

  @Test func progressClampsAndIsMonotonic() {
    #expect(LocalModelManager.progress(downloadedBytes: 50, expected: 100, previous: 0) == 0.5)
    #expect(LocalModelManager.progress(downloadedBytes: 10, expected: 100, previous: 0.5) == 0.5)
    #expect(LocalModelManager.progress(downloadedBytes: 500, expected: 100, previous: 0) == 1)
    #expect(LocalModelManager.progress(downloadedBytes: -5, expected: 100, previous: 0) == 0)
    #expect(LocalModelManager.progress(downloadedBytes: 5, expected: 0, previous: 0) == 0)
  }

  @Test func successfulDownloadMovesStagingIntoPlace() async throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = LocalModelManager(root: root) { _, staging, _ in
      try self.write(["config.json", "model.safetensors"], in: staging)
    }
    await manager.run(model)
    #expect(manager.isInstalled(model))
    #expect(manager.state[model.id] == nil)
    let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
    #expect(names == [model.id])
  }

  @Test func failedDownloadLeavesNothingInstalled() async throws {
    struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = LocalModelManager(root: root) { _, staging, _ in
      try self.write(["config.json", "model.safetensors"], in: staging)
      throw Boom()
    }
    await manager.run(model)
    #expect(!manager.isInstalled(model))
    #expect(manager.state[model.id] == .failed("boom"))
    #expect(
      !FileManager.default.fileExists(
        atPath: root.appendingPathComponent(".staging-\(model.id)").path))
  }

  @Test func incompleteDownloadIsNotInstalled() async throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = LocalModelManager(root: root) { _, staging, _ in
      try self.write(["config.json"], in: staging)
    }
    await manager.run(model)
    #expect(!manager.isInstalled(model))
    if case .failed = manager.state[model.id] {} else { Issue.record("expected failed state") }
  }

  @Test func cancelledDownloadLeavesNothingAndResetsState() async throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = LocalModelManager(root: root) { _, staging, _ in
      try self.write(["config.json", "model.safetensors"], in: staging)
      try await Task.sleep(for: .seconds(30))
    }
    manager.download(model)
    #expect(manager.isDownloading)
    try await Task.sleep(for: .milliseconds(100))
    manager.cancel()
    for _ in 0..<300 where manager.isDownloading { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!manager.isDownloading, "download did not stop after cancel")
    #expect(!manager.isInstalled(model))
    #expect(manager.state[model.id] == nil)
    #expect(
      !FileManager.default.fileExists(
        atPath: root.appendingPathComponent(".staging-\(model.id)").path))
    #expect(!FileManager.default.fileExists(atPath: manager.directory(for: model).path))
  }

  @Test func busyManagerIgnoresSecondDownloadAndRemove() async throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var calls = 0
    // Cancellable sleep: cancelling the manager always releases the downloader
    let manager = LocalModelManager(
      root: root,
      downloader: { _, _, _ in
        calls += 1
        try await Task.sleep(for: .seconds(30))
      }, unloader: { _ in true })
    defer { manager.cancel() }
    let other = LocalModelCatalog.all[1]
    try write(["config.json", "model.safetensors"], in: manager.directory(for: other))
    manager.download(model)
    for _ in 0..<300 where calls < 1 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(calls == 1)
    manager.download(model)
    manager.download(other)
    await manager.remove(other)
    #expect(calls == 1)
    #expect(manager.state[other.id] == nil)
    #expect(
      FileManager.default.fileExists(
        atPath: manager.directory(for: other).appendingPathComponent("config.json").path))
    manager.cancel()
    for _ in 0..<300 where manager.isDownloading { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!manager.isDownloading, "download did not stop after cancel")
  }

  @Test func deleteRemovesOnlyModelDirectory() async throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = LocalModelManager(root: root, downloader: { _, _, _ in }, unloader: { _ in true })
    let other = LocalModelCatalog.all[1]
    try write(["config.json", "model.safetensors"], in: manager.directory(for: model))
    try write(["config.json", "model.safetensors"], in: manager.directory(for: other))
    await manager.refreshInstalled()
    #expect(manager.isInstalled(model))
    await manager.remove(model)
    #expect(!manager.isInstalled(model))
    #expect(manager.isInstalled(other))
    #expect(manager.state[model.id] == nil)
  }

  @Test func deleteUnloadsResidentModelFirst() async throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let unloaded = IDRecorder()
    let manager = LocalModelManager(
      root: root, downloader: { _, _, _ in },
      unloader: { id in
        await unloaded.add(id)
        return true
      })
    try write(["config.json", "model.safetensors"], in: manager.directory(for: model))
    await manager.remove(model)
    #expect(await unloaded.ids == [model.id])
  }

  @Test func deleteIsRefusedAndKeepsFilesWhenModelIsInUse() async throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = LocalModelManager(
      root: root, downloader: { _, _, _ in }, unloader: { _ in false })
    try write(["config.json", "model.safetensors"], in: manager.directory(for: model))
    await manager.refreshInstalled()
    await manager.remove(model)
    #expect(manager.isInstalled(model))
    #expect(
      FileManager.default.fileExists(
        atPath: manager.directory(for: model).appendingPathComponent("config.json").path))
    if case .failed = manager.state[model.id] {} else { Issue.record("expected failed state") }
  }

  @Test func failedUpdateKeepsExistingInstall() async throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = LocalModelManager(root: root) { _, staging, _ in
      try self.write(["config.json"], in: staging)
    }
    try write(["config.json", "model.safetensors"], in: manager.directory(for: model))
    await manager.refreshInstalled()
    await manager.run(model)
    #expect(manager.isInstalled(model))
    #expect(
      FileManager.default.fileExists(
        atPath: manager.directory(for: model).appendingPathComponent("model.safetensors").path))
  }

  @Test func successfulUpdateReplacesExistingInstall() async throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = LocalModelManager(root: root) { _, staging, _ in
      try self.write(["config.json", "new.safetensors"], in: staging)
    }
    try write(["config.json", "old.safetensors"], in: manager.directory(for: model))
    await manager.run(model)
    let names = try FileManager.default.contentsOfDirectory(
      atPath: manager.directory(for: model).path)
    #expect(names.contains("new.safetensors") && !names.contains("old.safetensors"))
  }

  @Test func installedIsCachedUntilRefreshed() async throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = LocalModelManager(root: root) { _, _, _ in }
    try write(["config.json", "model.safetensors"], in: manager.directory(for: model))
    #expect(!manager.isInstalled(model))
    await manager.refreshInstalled()
    #expect(manager.isInstalled(model))
  }

  @Test func nonCatalogModelIsRejected() async throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var called = false
    let manager = LocalModelManager(root: root) { _, _, _ in called = true }
    let fake = LocalModel(
      id: "../evil", repoID: "evil/repo", revision: String(repeating: "0", count: 40),
      displayName: "x", tier: .tiny,
      approxSizeBytes: 1, minRAMBytes: 1, license: "x", note: "x")
    await manager.run(fake)
    #expect(!called)
    #expect(manager.state[fake.id] == nil)
  }

  @Test func downloaderReceivesCatalogRevision() async throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var received: String?
    let manager = LocalModelManager(root: root) { model, staging, _ in
      received = model.revision
      try self.write(["config.json", "model.safetensors"], in: staging)
    }
    await manager.run(model)
    #expect(received == model.revision)
  }

  @Test func sizeLimitIsOnePointFiveTimesExpected() {
    #expect(!LocalModelManager.exceedsSizeLimit(downloadedBytes: 150, expected: 100))
    #expect(LocalModelManager.exceedsSizeLimit(downloadedBytes: 151, expected: 100))
  }

  @Test func oversizeDownloadFailsAndIsCleanedUp() async throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = LocalModelManager(root: root, sampleInterval: .milliseconds(20)) {
      model, staging, _ in
      try self.write(["config.json"], in: staging)
      let big = staging.appendingPathComponent("model.safetensors")
      FileManager.default.createFile(atPath: big.path, contents: nil)
      let handle = try FileHandle(forWritingTo: big)
      try handle.truncate(atOffset: UInt64(Double(model.approxSizeBytes) * 1.6))
      try handle.close()
      try await Task.sleep(for: .seconds(30))
    }
    await manager.run(model)
    #expect(manager.state[model.id] == .failed("Download larger than expected"))
    #expect(!manager.isInstalled(model))
    #expect(
      !FileManager.default.fileExists(
        atPath: root.appendingPathComponent(".staging-\(model.id)").path))
  }

  @Test func olderScanNeverOverwritesNewerOne() async throws {
    final class Gate: @unchecked Sendable {
      private let lock = NSLock()
      private var calls = 0
      private var isOpen = false
      private var waiter: CheckedContinuation<Void, Never>?
      func nextCall() -> Int {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return calls
      }
      var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
      }
      func wait() async {
        await withCheckedContinuation { c in
          lock.lock()
          if isOpen {
            lock.unlock()
            c.resume()
          } else {
            waiter = c
            lock.unlock()
          }
        }
      }
      func open() {
        lock.lock()
        isOpen = true
        let c = waiter
        waiter = nil
        lock.unlock()
        c?.resume()
      }
    }
    let gate = Gate()
    // Call 1 (the init scan) is slow and stale; call 2 is fast and newer
    let manager = LocalModelManager(
      root: makeRoot(), downloader: { _, _, _ in }, unloader: { _ in true },
      scanner: { _ in
        if gate.nextCall() == 1 {
          await gate.wait()
          return ["old"]
        }
        return ["new"]
      })
    for _ in 0..<300 where gate.callCount < 1 { try await Task.sleep(for: .milliseconds(10)) }
    await manager.refreshInstalled()
    #expect(manager.installedIDs == ["new"])
    gate.open()
    try await Task.sleep(for: .milliseconds(100))
    #expect(manager.installedIDs == ["new"])
  }
}

private actor IDRecorder {
  private(set) var ids: [String] = []
  func add(_ id: String) { ids.append(id) }
}
