//
//  SQLEditorDocument.swift
//  Dblore
//

import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Document for SQL editor mode - handles plain .sql files
final class SQLEditorDocument: NSObject, ReferenceFileDocument, NSFilePresenter, ObservableObject,
  @unchecked Sendable
{
  @Published var content: String
  @Published var metadata: NotebookMetadata

  // MARK: - File Presenter Properties

  /// State for external file conflict dialog
  @Published var fileConflictState = FileConflictState()

  /// URL of the presented file (for NSFilePresenter)
  private var _presentedItemURL: URL?

  /// Last known modification date of the file
  private var lastKnownModificationDate: Date?

  /// This app's last rewrite of the file over a change not shown yet (Lock Workspace, Remove
  /// Lock): Keep My Version over that change takes it as seen too
  private var ownRewriteDate: Date?

  /// Debounce timer for rapid file changes
  private var changeDebounceTask: Task<Void, Never>?

  /// Flag to ignore changes triggered by our own save operation
  private var isIgnoringChanges = false

  /// Callback to notify view that external reload happened
  var onExternalReload: (() -> Void)?

  /// The id of the workspace whose key sealed this file (nil: plaintext); writes seal with it
  var lockKeyId: UUID?

  // MARK: - NSFilePresenter Protocol

  var presentedItemURL: URL? { _presentedItemURL }

  var presentedItemOperationQueue: OperationQueue { .main }

  // MARK: - ReferenceFileDocument Protocol

  nonisolated static var readableContentTypes: [UTType] {
    [.sql, .plainText]
  }

  nonisolated var writableContentTypes: [UTType] {
    [.sql]
  }

  init(
    content: String = "", metadata: NotebookMetadata = NotebookMetadata(title: "Untitled")
  ) {
    self.content = content
    self.metadata = metadata
    super.init()
  }

  required init(configuration: ReadConfiguration) throws {
    guard let data = configuration.file.regularFileContents,
      let sqlContent = String(data: data, encoding: .utf8)
    else {
      throw CocoaError(.fileReadCorruptFile)
    }

    self.content = sqlContent

    // Extract filename for title
    let filename = configuration.file.filename ?? "Untitled"
    let title = (filename as NSString).deletingPathExtension
    self.metadata = NotebookMetadata(title: title)

    // Store file URL for monitoring (will be set properly by setFileURL)
    _presentedItemURL = nil
    lastKnownModificationDate = Date()

    super.init()
  }

  // MARK: - File URL Management

  /// Set the file URL for monitoring. Call this after document is opened.
  func setFileURL(_ url: URL?) {
    // Remove from old presenter if URL changes. Both calls are queued (`SQLiteFileAccess`), so
    // a stalled file arbiter never blocks the main thread.
    if _presentedItemURL != nil {
      SQLiteFileAccess.removeFilePresenter(self)
    }

    _presentedItemURL = url

    // Register as file presenter if we have a valid URL
    if url != nil {
      SQLiteFileAccess.addFilePresenter(self)
      updateLastKnownModificationDate()
    }
  }

  /// Update the last known modification date from the file (also after this app writes it: the
  /// file conflict alert only asks about a newer change)
  func updateLastKnownModificationDate() {
    guard let url = _presentedItemURL else { return }
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      lastKnownModificationDate = attributes[.modificationDate] as? Date
      ownRewriteDate = nil
    } catch {
      // Ignore errors - file might not exist yet
    }
  }

  /// Keep My Version of the file conflict alert: only a change newer than the one the alert
  /// showed, or than this app's own rewrite since, asks again (a change made while it was up
  /// still does)
  func keepVersionOverShownChange() {
    let shown = fileConflictState.externalModificationDate ?? lastKnownModificationDate
    lastKnownModificationDate = [shown, ownRewriteDate].compactMap { $0 }.max()
    ownRewriteDate = nil
  }

  func noteOwnRewrite() {
    ownRewriteDate = modificationDateOnDisk()
  }

  /// The file's date on disk when it changed since this document last read or wrote it (nil: no
  /// newer change, or no file)
  func unseenChangeDate() -> Date? {
    guard let date = modificationDateOnDisk() else { return nil }
    guard let lastDate = lastKnownModificationDate else { return date }
    return date > lastDate ? date : nil
  }

  /// The file's modification date on disk (nil: no file, or it cannot be read)
  private func modificationDateOnDisk() -> Date? {
    guard let url = _presentedItemURL else { return nil }
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return attributes?[.modificationDate] as? Date
  }

  // MARK: - NSFilePresenter Callbacks

  /// Called when the file is modified externally
  func presentedItemDidChange() {
    // Skip if we're ignoring changes (our own save triggered this)
    guard !isIgnoringChanges else { return }

    // Debounce rapid changes (e.g., editors that save multiple times)
    changeDebounceTask?.cancel()
    changeDebounceTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(500))
      guard !Task.isCancelled else { return }
      await self.handleExternalChange()
    }
  }

  /// Called when the file is about to be deleted
  func accommodatePresentedItemDeletion(completionHandler: @escaping @Sendable (Error?) -> Void) {
    Task { @MainActor in
      self.fileConflictState.show(type: .deleted)
      completionHandler(nil)
    }
  }

  /// Called when the file is moved or renamed
  func presentedItemDidMove(to newURL: URL) {
    _presentedItemURL = newURL
    updateLastKnownModificationDate()
  }

  // MARK: - External Change Handling

  /// Handle external file modification
  @MainActor
  private func handleExternalChange() async {
    guard let url = _presentedItemURL else { return }

    // Check if file still exists
    guard FileManager.default.fileExists(atPath: url.path) else {
      fileConflictState.show(type: .deleted)
      return
    }

    // Check modification date
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      guard let newModDate = attributes[.modificationDate] as? Date else { return }

      // If modification date hasn't changed, ignore
      if let lastDate = lastKnownModificationDate, newModDate <= lastDate {
        return
      }

      // File was modified externally
      fileConflictState.show(type: .modified, modificationDate: newModDate)
    } catch {
      // If we can't read attributes, assume file was deleted
      fileConflictState.show(type: .deleted)
    }
  }

  // MARK: - Reload from Disk

  /// Reload the document content from disk. A sealed file is read and opened off the main
  /// actor (asking `unlock` when its workspace is not open); `holder` (the window's workspace
  /// id) holds the session that opened it. When `stillApplies` turns false during the read (the
  /// tab was edited meanwhile), nothing is replaced and the conflict alert asks again.
  /// - Returns: whether the document now holds the file's content.
  @MainActor @discardableResult
  func reloadFromDisk(
    holder: UUID, io: LockedFileIO = .shared, unlock: LockedFileIO.Unlock,
    stillApplies: () -> Bool = { true }
  ) async throws -> Bool {
    guard let url = _presentedItemURL else {
      throw CocoaError(.fileReadNoSuchFile)
    }

    // Dated before the read: a change landing during it is newer, so it still asks
    let dateBeforeRead = modificationDateOnDisk()
    let read = try await io.read(from: url, unlock: unlock)
    guard let reloadedContent = String(data: read.plaintext, encoding: .utf8) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    if let session = read.session { io.sessions.hold(session, by: holder) }
    guard stillApplies() else {
      fileConflictState.show(type: .modified, modificationDate: dateBeforeRead)
      return false
    }

    // Update content on main thread
    content = reloadedContent
    // A plaintext replacement of a sealed file keeps the key: the next save seals it again
    lockKeyId = read.session?.workspaceId ?? lockKeyId
    lastKnownModificationDate = dateBeforeRead ?? lastKnownModificationDate
    ownRewriteDate = nil

    // Notify view to update its state
    onExternalReload?()
    return true
  }

  // MARK: - Cleanup

  deinit {
    changeDebounceTask?.cancel()
    // No removal here: the arbiter retains a registered presenter, so deinit runs only once
    // it is off the arbiter (never registered, or removed by a later `setFileURL`)
  }

  // MARK: - Snapshot and FileWrapper

  func snapshot(contentType: UTType) throws -> String {
    // Temporarily ignore file changes triggered by our own save
    isIgnoringChanges = true

    // Schedule to re-enable change detection after save completes
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(1000))
      self.isIgnoringChanges = false
      self.updateLastKnownModificationDate()
    }

    return content
  }

  nonisolated func fileWrapper(
    snapshot: String, configuration: WriteConfiguration
  ) throws -> FileWrapper {
    guard let data = snapshot.data(using: .utf8) else {
      throw CocoaError(.fileWriteUnknown)
    }

    return FileWrapper(regularFileWithContents: data)
  }
}

// The tab's file conflict alert observes `fileConflictState`
extension SQLEditorDocument: FileConflictPresenting {}
