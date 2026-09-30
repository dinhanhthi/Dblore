// LocalModelManager.swift
// Downloads, tracks and deletes on-device MLX models (catalog models only)

import Foundation
import HuggingFace
import Observation

nonisolated enum LocalModelDownloadState: Equatable, Sendable {
  case idle
  case downloading(Double)
  /// Download done; verifying and moving the files into place
  case finalizing
  case deleting
  case failed(String)
}

@MainActor
@Observable
final class LocalModelManager {
  typealias DownloadState = LocalModelDownloadState
  /// Downloads the model's files into `staging`; reports Foundation progress.
  typealias Downloader =
    @MainActor (LocalModel, URL, @escaping @MainActor @Sendable (Progress) -> Void) async throws ->
    Void

  /// Frees a resident model before its files are deleted; false when it is in use.
  typealias Unloader = @Sendable (String) async -> Bool

  /// Returns the ids of the installed catalog models found under the root (runs off-main).
  typealias Scanner = @Sendable (URL) async -> Set<LocalModel.ID>

  static let shared = LocalModelManager(root: defaultRoot)

  nonisolated static var defaultRoot: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Dblore", isDirectory: true)
      .appendingPathComponent("Models", isDirectory: true)
  }

  nonisolated static let patterns = ["*.safetensors", "*.json", "*.jinja", "tokenizer*"]

  private(set) var state: [LocalModel.ID: DownloadState] = [:]
  /// Ids of installed models. Updated by background scans so views never touch the disk.
  private(set) var installedIDs: Set<LocalModel.ID> = []

  let root: URL
  private let downloader: Downloader
  private let sampleInterval: Duration
  private let unloader: Unloader
  private let scanner: Scanner
  private var scanSequence = 0
  private var appliedScanSequence = 0
  private var task: Task<Void, Never>?
  private var activeID: LocalModel.ID?

  init(
    root: URL,
    sampleInterval: Duration = .milliseconds(500),
    downloader: @escaping Downloader = LocalModelManager.hubDownload,
    unloader: @escaping Unloader = { MLXEngine.shared.unload(modelID: $0) },
    scanner: @escaping Scanner = LocalModelManager.diskScan
  ) {
    self.root = root
    self.sampleInterval = sampleInterval
    self.downloader = downloader
    self.unloader = unloader
    self.scanner = scanner
    Task { [weak self] in await self?.refreshInstalled() }
  }

  // MARK: - Queries

  func directory(for model: LocalModel) -> URL {
    root.appendingPathComponent(model.id, isDirectory: true)
  }

  /// Cached answer; call `refreshInstalled()` after changing files on disk.
  func isInstalled(_ model: LocalModel) -> Bool {
    installedIDs.contains(model.id)
  }

  /// Scans the models directory off the main thread and publishes the installed set.
  func refreshInstalled() async {
    scanSequence += 1
    let sequence = scanSequence
    let ids = await scanner(root)
    // A scan that started later already published; never overwrite it with older data
    guard sequence > appliedScanSequence else { return }
    appliedScanSequence = sequence
    if installedIDs != ids { installedIDs = ids }
  }

  static let diskScan: Scanner = { root in
    await Task.detached {
      Set(
        LocalModelCatalog.all.map(\.id).filter {
          isInstalled(at: root.appendingPathComponent($0, isDirectory: true))
        })
    }.value
  }

  var isDownloading: Bool { activeID != nil }

  /// True while a download, finalize or delete is in flight; conflicting actions are disabled.
  var isBusy: Bool {
    activeID != nil || state.values.contains { $0 == .deleting }
  }

  // MARK: - Actions

  /// Starts a download of a catalog model; ignored when one is already running.
  func download(_ model: LocalModel) {
    guard !isBusy, LocalModelCatalog.model(for: model.id) == model else { return }
    activeID = model.id
    state[model.id] = .downloading(0)
    task = Task { [weak self] in
      await self?.run(model)
    }
  }

  /// Runs a download to completion (used by `download` and by tests).
  func run(_ model: LocalModel) async {
    guard LocalModelCatalog.model(for: model.id) == model else { return }
    activeID = model.id
    state[model.id] = .downloading(0)
    let staging = stagingDirectory(for: model)
    let started = Date()
    let tracker = ProgressTracker()
    let sampler = Task { [weak self, sampleInterval] in
      while !Task.isCancelled {
        try? await Task.sleep(for: sampleInterval)
        guard let self, !Task.isCancelled else { return }
        let bytes = await Task.detached {
          Self.diskBytes(staging: staging, since: started)
        }.value
        if Self.exceedsSizeLimit(downloadedBytes: bytes, expected: model.approxSizeBytes) {
          tracker.oversize = true
          tracker.job?.cancel()
          return
        }
        self.report(model, downloadedBytes: bytes, tracker: tracker)
      }
    }
    defer {
      sampler.cancel()
      activeID = nil
      task = nil
    }
    do {
      try await Task.detached {
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
      }.value
      let downloader = self.downloader
      let job = Task { @MainActor [weak self] in
        try await downloader(model, staging) { progress in
          tracker.foundationFraction = progress.fractionCompleted
          self?.report(model, downloadedBytes: 0, tracker: tracker)
        }
      }
      tracker.job = job
      try await withTaskCancellationHandler {
        try await job.value
      } onCancel: {
        job.cancel()
      }
      try Task.checkCancellation()
      sampler.cancel()
      state[model.id] = .finalizing
      let final = directory(for: model)
      let oversize = tracker.oversize
      try await Task.detached {
        try Self.verifyAndInstall(
          staging: staging, final: final, expected: model.approxSizeBytes, oversize: oversize)
      }.value
      await refreshInstalled()
      state[model.id] = nil
    } catch {
      await Task.detached { try? FileManager.default.removeItem(at: staging) }.value
      if tracker.oversize {
        state[model.id] = .failed(ManagerError.oversize.errorDescription ?? "Download failed")
      } else if error is CancellationError || Task.isCancelled {
        state[model.id] = nil
      } else {
        state[model.id] = .failed(Self.message(for: error))
      }
    }
  }

  func cancel() {
    // Finalizing is a short non-cancellable move
    guard activeID.map({ state[$0] != .finalizing }) ?? false else { return }
    task?.cancel()
  }

  /// Removes a model in the background (unloading it first); ignored while it is downloading.
  func delete(_ model: LocalModel) {
    Task { [weak self] in await self?.remove(model) }
  }

  /// Runs a delete to completion (used by `delete` and by tests).
  func remove(_ model: LocalModel) async {
    guard LocalModelCatalog.model(for: model.id) == model, !isBusy else { return }
    state[model.id] = .deleting
    guard await unloader(model.id) else {
      state[model.id] = .failed("Model is in use. Try again when the response has finished.")
      return
    }
    let dir = directory(for: model)
    await Task.detached { try? FileManager.default.removeItem(at: dir) }.value
    await refreshInstalled()
    state[model.id] = nil
  }

  /// Runs on a background thread: checks size and completeness, then swaps `staging` into
  /// `final`. An existing install is only replaced by the atomic swap, so a failure keeps it.
  nonisolated private static func verifyAndInstall(
    staging: URL, final: URL, expected: Int64, oversize: Bool
  ) throws {
    let staged = sizeOfFiles(in: staging, since: nil, recursive: true)
    if oversize || exceedsSizeLimit(downloadedBytes: staged, expected: expected) {
      throw ManagerError.oversize
    }
    guard isInstalled(at: staging) else { throw ManagerError.incomplete }
    let fm = FileManager.default
    if fm.fileExists(atPath: final.path) {
      _ = try fm.replaceItemAt(final, withItemAt: staging)
    } else {
      try fm.moveItem(at: staging, to: final)
    }
  }

  // MARK: - Progress

  private final class ProgressTracker: @unchecked Sendable {
    var foundationFraction: Double = 0
    var previous: Double = 0
    var oversize = false
    var job: Task<Void, Error>?
  }

  /// Staged bytes above this multiple of the catalog size abort the download.
  nonisolated static let sizeLimitFactor = 1.5

  nonisolated static func exceedsSizeLimit(downloadedBytes: Int64, expected: Int64) -> Bool {
    Double(downloadedBytes) > Double(expected) * sizeLimitFactor
  }

  private func report(_ model: LocalModel, downloadedBytes: Int64, tracker: ProgressTracker) {
    guard case .downloading = state[model.id] else { return }
    let foundationBytes = Int64(
      (max(0, min(1, tracker.foundationFraction)) * Double(model.approxSizeBytes)).rounded())
    let value = Self.progress(
      downloadedBytes: max(foundationBytes, downloadedBytes),
      expected: model.approxSizeBytes,
      previous: tracker.previous
    )
    tracker.previous = value
    state[model.id] = .downloading(value)
  }

  /// Fraction in [0, 1] that never decreases; 0 when `expected` is not positive.
  nonisolated static func progress(
    downloadedBytes: Int64, expected: Int64, previous: Double
  )
    -> Double
  {
    let prev = previous.isFinite ? max(0, min(1, previous)) : 0
    guard expected > 0 else { return prev }
    let raw = Double(max(0, downloadedBytes)) / Double(expected)
    guard raw.isFinite else { return prev }
    return max(prev, min(1, raw))
  }

  // MARK: - Installed detection

  nonisolated static func isInstalled(at dir: URL) -> Bool {
    let fm = FileManager.default
    guard fm.fileExists(atPath: dir.appendingPathComponent("config.json").path),
      let names = try? fm.contentsOfDirectory(atPath: dir.path)
    else { return false }
    return names.contains { $0.hasSuffix(".safetensors") }
  }

  // MARK: - Helpers

  nonisolated private enum ManagerError: LocalizedError {
    case incomplete
    case oversize
    var errorDescription: String? {
      switch self {
      case .incomplete: "Download incomplete: model files are missing."
      case .oversize: "Download larger than expected"
      }
    }
  }

  private func stagingDirectory(for model: LocalModel) -> URL {
    root.appendingPathComponent(".staging-\(model.id)", isDirectory: true)
  }

  nonisolated private static func message(for error: Error) -> String {
    let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    return text.isEmpty ? "Download failed" : text
  }

  /// Bytes under the staging dir plus URLSession temp files created after `since`.
  nonisolated private static func diskBytes(staging: URL, since: Date) -> Int64 {
    sizeOfFiles(in: staging, since: nil, recursive: true)
      + sizeOfFiles(
        in: URL(fileURLWithPath: NSTemporaryDirectory()), since: since.addingTimeInterval(-2),
        recursive: false)
  }

  nonisolated private static func sizeOfFiles(in dir: URL, since: Date?, recursive: Bool) -> Int64 {
    let keys: [URLResourceKey] = [.fileSizeKey, .creationDateKey, .isRegularFileKey]
    let options: FileManager.DirectoryEnumerationOptions =
      recursive ? [] : [.skipsSubdirectoryDescendants]
    guard
      let enumerator = FileManager.default.enumerator(
        at: dir, includingPropertiesForKeys: keys, options: options)
    else { return 0 }
    var total: Int64 = 0
    for case let url as URL in enumerator {
      guard let values = try? url.resourceValues(forKeys: Set(keys)),
        values.isRegularFile == true, let size = values.fileSize
      else { continue }
      if let since, (values.creationDate ?? .distantPast) < since { continue }
      total += Int64(size)
    }
    return total
  }

  /// Default downloader: swift-huggingface snapshot of the catalog repo (HTTPS huggingface.co),
  /// straight into the staging dir with no shared cache copy.
  static let hubDownload: Downloader = { model, staging, onProgress in
    guard let repo = Repo.ID(rawValue: model.repoID) else {
      throw LocalModelManagerError.invalidRepo
    }
    let client = HubClient(cache: nil)
    _ = try await client.downloadSnapshot(
      of: repo, to: staging, revision: model.revision, matching: patterns,
      progressHandler: onProgress)
  }
}

nonisolated enum LocalModelManagerError: LocalizedError {
  case invalidRepo
  var errorDescription: String? { "Invalid model repository" }
}
