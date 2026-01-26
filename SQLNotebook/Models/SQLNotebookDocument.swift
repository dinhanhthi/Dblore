//
//  SQLNotebookDocument.swift
//  SQLNotebook
//
//  Document wrapper for SQL Notebook files
//
//  NOTE: This file has been split into focused modules:
//  - SQLNotebookDocument+Coding.swift (JSON encoding/decoding)
//

import Combine
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
  nonisolated static var sqlNotebook: UTType {
    UTType(exportedAs: "com.sqlnotebook.document")
  }

  nonisolated static var sql: UTType {
    UTType(importedAs: "public.sql")
  }
}

/// Document wrapper for SQL Notebook files (.sqlnb)
final class SQLNotebookDocument: NSObject, ReferenceFileDocument, NSFilePresenter,
  ObservableObject, @unchecked Sendable
{
  @Published var notebook: SQLNotebook

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
    [.sqlNotebook, .json]
  }

  var writableContentTypes: [UTType] {
    [.sqlNotebook]
  }

  init(notebook: SQLNotebook = SQLNotebook.newDocument()) {
    self.notebook = notebook
    super.init()
  }

  required init(configuration: ReadConfiguration) throws {
    guard let data = configuration.file.regularFileContents else {
      throw CocoaError(.fileReadCorruptFile)
    }

    // JSON format (.sqlnb)
    var decodedNotebook = try DocumentCoder.decode(from: data)
    // Ensure documentType is .notebook
    decodedNotebook.documentType = .notebook
    notebook = decodedNotebook

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
    var reloadedNotebook = try DocumentCoder.decode(from: data)
    reloadedNotebook.documentType = .notebook

    notebook = reloadedNotebook
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

  // Create snapshot for saving
  func snapshot(contentType: UTType) throws -> SQLNotebook {
    var notebookSnapshot = notebook
    notebookSnapshot.metadata.modifiedAt = Date()

    // Temporarily ignore file changes triggered by our own save
    isIgnoringChanges = true

    // Schedule to re-enable change detection after save completes
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(1000))
      self.isIgnoringChanges = false
      self.updateLastKnownModificationDate()
    }

    return notebookSnapshot
  }

  nonisolated func fileWrapper(
    snapshot: SQLNotebook, configuration: WriteConfiguration
  ) throws
    -> FileWrapper
  {
    let notebookToSave = snapshot

    // Save as JSON .sqlnb file
    // Access AppSettings in a thread-safe way
    let includeResults = AppSettings.getIncludeResultsOnSave()

    // Use compact format for large files
    let estimatedSize =
      (try? FileOptimizationService.calculateNotebookSize(
        notebookToSave, includeResults: includeResults)) ?? 0
    let useCompactFormat = estimatedSize > FileOptimizationService.warningSizeThreshold

    let data = try DocumentCoder.encode(
      notebookToSave,
      includeResultsOnSave: includeResults,
      useCompactFormat: useCompactFormat
    )
    return FileWrapper(regularFileWithContents: data)
  }
}
