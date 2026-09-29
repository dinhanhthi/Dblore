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

  /// Debounce timer for rapid file changes
  private var changeDebounceTask: Task<Void, Never>?

  /// Flag to ignore changes triggered by our own save operation
  private var isIgnoringChanges = false

  /// Callback to notify view that external reload happened
  var onExternalReload: (() -> Void)?

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
    // Remove from old presenter if URL changes
    if _presentedItemURL != nil {
      NSFileCoordinator.removeFilePresenter(self)
    }

    _presentedItemURL = url

    // Register as file presenter if we have a valid URL
    if url != nil {
      NSFileCoordinator.addFilePresenter(self)
      updateLastKnownModificationDate()
    }
  }

  /// Update the last known modification date from the file
  private func updateLastKnownModificationDate() {
    guard let url = _presentedItemURL else { return }
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      lastKnownModificationDate = attributes[.modificationDate] as? Date
    } catch {
      // Ignore errors - file might not exist yet
    }
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

  /// Reload the document content from disk
  func reloadFromDisk() throws {
    guard let url = _presentedItemURL else {
      throw CocoaError(.fileReadNoSuchFile)
    }

    let data = try Data(contentsOf: url)
    guard let reloadedContent = String(data: data, encoding: .utf8) else {
      throw CocoaError(.fileReadCorruptFile)
    }

    // Update content on main thread
    content = reloadedContent
    updateLastKnownModificationDate()

    // Notify view to update its state
    onExternalReload?()
  }

  // MARK: - Cleanup

  deinit {
    changeDebounceTask?.cancel()
    if _presentedItemURL != nil {
      NSFileCoordinator.removeFilePresenter(self)
    }
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
