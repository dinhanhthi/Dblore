//
//  EditorContentView.swift
//  SQLNotebook
//

import SwiftUI

/// Content view for Editor mode (.sql files)
struct EditorContentView: View {
  @ObservedObject var document: SQLEditorDocument
  @State private var viewModel: NotebookViewModel
  @State private var lastSaved: Date?

  @State private var keyEventMonitor: Any?
  @State private var monitorWindow: NSWindow?  // Track which window this monitor belongs to
  @Bindable private var appSettings = AppSettings.shared
  @Environment(\.undoManager) private var undoManager

  init(document: SQLEditorDocument) {
    self.document = document

    // Create a notebook with single cell for editor mode
    let cell = NotebookCell(cellType: .sql, content: document.content)
    let notebook = SQLNotebook(
      cells: [cell],
      metadata: document.metadata,
      connectionConfig: nil,
      settings: NotebookSettings(),
      documentType: .script
    )

    let vm = NotebookViewModel(notebook: notebook)
    // Force editor mode
    vm.viewMode = .editor
    vm.editorContent = document.content
    _viewModel = State(initialValue: vm)
  }

  var body: some View {
    NotebookLayoutView(
      viewModel: viewModel,
      lastSaved: $lastSaved,
      isEditorMode: true
    ) {
      // Main editor content
      EditorModeView(viewModel: viewModel)
    }
    .modifier(
      EditorNotificationHandlerModifier(
        viewModel: viewModel,
        syncDocument: syncDocument
      )
    )
    .destructiveQueryDialog(viewModel: viewModel, syncDocument: syncDocument)
    .searchNotifications(viewModel: viewModel)
    .focusedSceneActions(viewModel: viewModel, mode: .editor)
    .onChange(of: viewModel.editorContent) { _, newContent in
      syncDocument()
    }
    .onChange(of: viewModel.notebook.metadata.title) { _, _ in
      syncDocument()
    }
    .onChange(of: document.content) { _, newContent in
      // Sync document content to viewModel when document changes externally
      // This handles the case where document is loaded async after view init
      if viewModel.editorContent != newContent {
        viewModel.editorContent = newContent

        // Force update NSTextView directly since @State binding may not trigger update
        if let textView = viewModel.editorTextView {
          let highlighted = SQLSyntaxHighlighter.highlight(newContent)
          textView.textStorage?.setAttributedString(highlighted)
        }
      }
    }
    .fileConflictAlert(
      state: $document.fileConflictState,
      hasUnsavedChanges: lastSaved == nil,
      onKeepMyVersion: {
        // Mark document as dirty to preserve local version
        syncDocument()
        document.fileConflictState.dismiss()
      },
      onLoadExternal: {
        reloadExternalContent()
      }
    )
    .onAppear {
      setupKeyEventMonitor()
      viewModel.onDocumentChanged = syncDocument

      // Sync content from document to viewModel on appear
      // This ensures content is loaded correctly even if document was loaded async
      if viewModel.editorContent != document.content {
        viewModel.editorContent = document.content
        viewModel.notebook.metadata = document.metadata

        // Force update NSTextView if already available
        if let textView = viewModel.editorTextView {
          let highlighted = SQLSyntaxHighlighter.highlight(document.content)
          textView.textStorage?.setAttributedString(highlighted)
        }
      }

      // Set up file URL for external change monitoring
      setupFileMonitoring()

      // Set up callback for external reload
      document.onExternalReload = { [self] in
        viewModel.editorContent = document.content
        viewModel.notebook.metadata = document.metadata
      }

      // Auto-connect to saved session if available
      viewModel.autoConnectIfNeeded()
    }
    .onDisappear {
      removeKeyEventMonitor()
      viewModel.onDocumentChanged = nil
      document.onExternalReload = nil

      // Disconnect from database when window closes to prevent connection leaks
      Task {
        await viewModel.connectionManager.disconnect()
      }
    }
  }

  // MARK: - External Content Reload

  private func reloadExternalContent() {
    do {
      try document.reloadFromDisk()
      // Update viewModel with reloaded content
      let newContent = document.content

      viewModel.editorContent = newContent
      viewModel.notebook.metadata = document.metadata

      // IMPORTANT: Directly update the NSTextView because @State doesn't trigger SwiftUI updates
      // for @Observable object properties. The binding chain is broken.
      if let textView = viewModel.editorTextView {
        let highlighted = SQLSyntaxHighlighter.highlight(newContent)
        textView.textStorage?.setAttributedString(highlighted)
      }

      // Reset lastSaved to indicate clean state
      lastSaved = Date()
    } catch {
      print("❌ [EditorContentView] Failed to reload from disk: \(error)")
    }
    document.fileConflictState.dismiss()
  }

  // MARK: - File Monitoring Setup

  private func setupFileMonitoring() {
    // Get file URL from NSDocumentController
    // Try multiple times with increasing delays to ensure window is ready
    let contentToMatch = document.content
    let delays = [0.1, 0.5, 1.0]

    for delay in delays {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak document] in
        guard let document = document else { return }
        // Skip if URL already set
        guard document.presentedItemURL == nil else { return }

        // Find matching NSDocument by comparing content
        for doc in NSDocumentController.shared.documents {
          guard let nsDoc = doc as? NSDocument,
            let fileURL = nsDoc.fileURL,
            fileURL.pathExtension == "sql"
          else { continue }

          // Try to match by reading file content
          if let fileContent = try? String(contentsOf: fileURL, encoding: .utf8),
            fileContent == contentToMatch
          {
            document.setFileURL(fileURL)
            return
          }
        }
      }
    }
  }

  // MARK: - Document Sync

  private func syncDocument() {
    // Capture old values before changing
    let oldContent = document.content
    let oldMetadata = document.metadata

    let newContent = viewModel.editorContent
    let newMetadata = viewModel.notebook.metadata

    // Only sync if there are actual changes
    guard oldContent != newContent || oldMetadata.title != newMetadata.title else {
      return
    }

    // Sync editorContent back to document
    document.content = newContent
    document.metadata = newMetadata

    // Register undo action to mark document as dirty
    // This is critical for ReferenceFileDocument to know the document has changed
    if let undoManager = undoManager {
      undoManager.registerUndo(withTarget: document) { [oldContent, oldMetadata] doc in
        doc.content = oldContent
        doc.metadata = oldMetadata
      }
    }

    lastSaved = nil  // Mark as unsaved
  }

  // MARK: - Keyboard Event Monitoring

  private func setupKeyEventMonitor() {
    keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
      // CRITICAL: Only handle events for the key window
      // Store window reference on first event to identify "our" window
      guard let eventWindow = event.window,
        eventWindow == NSApplication.shared.keyWindow
      else {
        return event  // Not our window, pass through
      }

      // Store our window on first event if not set
      if self.monitorWindow == nil {
        self.monitorWindow = eventWindow
      }

      // Only handle if this is OUR window (prevent multi-window conflicts)
      guard eventWindow == self.monitorWindow else {
        return event  // Different window, pass through
      }

      // Check if a NSTextView is currently first responder (excluding search field)
      let textViewIsFocused: Bool = {
        guard let firstResponder = eventWindow.firstResponder else {
          return false  // No responder = no text view focused
        }
        // If search panel is visible, don't treat search field as "text view focused"
        // because we want ESC to close search panel, not unfocus search field
        if self.viewModel.isSearchPanelVisible {
          return false
        }
        return firstResponder is NSTextView
      }()

      // Handle Cmd+Enter to run query (alternative to Cmd+R)
      let isReturn = event.keyCode == 36
      let hasCommandModifier = event.modifierFlags.contains(.command)
      let hasNoOtherModifiers =
        !event.modifierFlags.contains(.shift)
        && !event.modifierFlags.contains(.option)
        && !event.modifierFlags.contains(.control)

      if isReturn && hasCommandModifier && hasNoOtherModifiers {
        NotificationCenter.default.post(name: .runEditorQuery, object: nil)
        return nil  // Event consumed
      }

      // Handle ESC key
      let isEscape = event.keyCode == 53
      if isEscape {
        // Priority 0: If search panel is open, close it
        // Note: This works together with SearchPanelView's .onKeyPress
        // - If search field is focused: .onKeyPress handles it and returns .handled (blocks this)
        // - If search field is NOT focused: this NSEvent monitor handles it
        if self.viewModel.isSearchPanelVisible {
          Task { @MainActor [viewModel] in
            viewModel.closeSearch()
          }
          return nil  // Event consumed
        }

        // Priority 1: If text editor is focused, unfocus it
        if textViewIsFocused {
          NotificationCenter.default.post(name: .unfocusEditor, object: nil)
          return nil  // Event consumed
        }

        // Priority 2: If right sidebar is open, close it
        if self.viewModel.isRightSidebarVisible {
          Task { @MainActor [viewModel] in
            viewModel.closeSidebar()
          }
          return nil  // Event consumed
        }
      }

      return event
    }
  }

  private func removeKeyEventMonitor() {
    if let monitor = keyEventMonitor {
      NSEvent.removeMonitor(monitor)
      keyEventMonitor = nil
    }
  }
}

// MARK: - Notification Handler Modifier

private struct EditorNotificationHandlerModifier: ViewModifier {
  let viewModel: NotebookViewModel
  let syncDocument: () -> Void

  func body(content: Content) -> some View {
    content
      .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
        // Toggle settings sidebar
        if viewModel.isRightSidebarVisible && viewModel.rightSidebarContent == .settings {
          viewModel.isRightSidebarVisible = false
        } else {
          viewModel.rightSidebarContent = .settings
          viewModel.isRightSidebarVisible = true
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .runEditorQuery)) { _ in
        Task { @MainActor in
          await viewModel.runEditorQuery()
          syncDocument()
        }
      }
  }
}

// MARK: - Previews

#Preview("Editor - Both Sidebars Open") {
  EditorContentView(document: EditorPreviewData.documentWithContent)
    .frame(width: 1000, height: 600)
}

#Preview("Editor - Empty") {
  EditorContentView(document: SQLEditorDocument())
    .frame(width: 1000, height: 600)
}

// MARK: - Preview Data

private enum EditorPreviewData {
  static var documentWithContent: SQLEditorDocument {
    let sqlContent = """
      -- Sample SQL Script
      -- This demonstrates the Editor mode for .sql files

      SELECT
          u.id,
          u.name,
          u.email,
          COUNT(o.id) as order_count,
          SUM(o.total) as total_spent
      FROM users u
      LEFT JOIN orders o ON u.id = o.user_id
      WHERE u.created_at >= '2024-01-01'
      GROUP BY u.id, u.name, u.email
      HAVING COUNT(o.id) > 0
      ORDER BY total_spent DESC
      LIMIT 100;

      -- Another query
      SELECT * FROM products WHERE stock < 10;
      """

    return SQLEditorDocument(
      content: sqlContent,
      metadata: NotebookMetadata(title: "Sample Query")
    )
  }
}
