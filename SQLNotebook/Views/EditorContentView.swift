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
    ZStack {
      Color.appBackground
        .ignoresSafeArea()

      VStack(spacing: 0) {
        // Header and search panel in ZStack so search slides under header
        ZStack(alignment: .top) {
          // Search panel (lower z-index, slides from top under header)
          VStack(spacing: 0) {
            Spacer()
              .frame(height: ComponentSize.headerHeight)

            if viewModel.isSearchPanelVisible {
              SearchPanelView(viewModel: viewModel)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
          }

          // Header (higher z-index, covers search panel animation)
          HeaderView(viewModel: viewModel)
        }
        .clipped()

        // Main content area
        HStack(spacing: 0) {
          // Left sidebar (conditionally shown)
          if viewModel.isLeftSidebarVisible {
            LeftSidebarView(viewModel: viewModel)
              .transition(.move(edge: .leading))
          }

          // Main editor content
          EditorModeView(viewModel: viewModel)
            .frame(maxWidth: .infinity)

          // Right sidebar (conditionally shown)
          if viewModel.isRightSidebarVisible {
            RightSidebarView(viewModel: viewModel)
              .transition(.move(edge: .trailing))
          }
        }

        // Footer
        FooterView(viewModel: viewModel, lastSaved: lastSaved, isEditorMode: true)
      }

      // Toast notification (bottom-right corner)
      if let toast = viewModel.currentToast {
        VStack {
          Spacer()
          HStack {
            Spacer()
            ToastView(toast: toast, viewModel: viewModel)
              .padding(.horizontal, Spacing.lg)
              .padding(.vertical, Spacing.xxl)
              .transition(.move(edge: .trailing).combined(with: .opacity))
          }
        }
      }
    }
    .animation(.easeInOut(duration: 0.4), value: viewModel.currentToast)
    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: viewModel.isSearchPanelVisible)
    .windowAppearance(appSettings.themePreference.colorScheme)
    .modifier(
      EditorNotificationHandlerModifier(
        viewModel: viewModel,
        syncDocument: syncDocument
      )
    )
    .modifier(EditorSearchNotificationHandlerModifier(viewModel: viewModel))
    .confirmationDialog(
      "Confirm Destructive Query",
      isPresented: $viewModel.showQueryConfirmationDialog,
      titleVisibility: .visible
    ) {
      Button("Execute Query", role: .destructive) {
        Task { @MainActor [viewModel] in
          await viewModel.executePendingQuery()
          syncDocument()
        }
      }
      Button("Cancel", role: .cancel) {
        viewModel.cancelPendingQuery()
      }
    } message: {
      VStack(alignment: .leading, spacing: 8) {
        Text("This query will modify data in your database:")
          .font(.body)
        Text(viewModel.pendingQuery)
          .font(.system(.body, design: .monospaced))
          .lineLimit(5)
        Text("Are you sure you want to proceed?")
          .font(.body)
      }
    }
    .focusedSceneValue(\.documentMode, .editor)
    .focusedSceneValue(\.toggleLeftSidebarAction) { [viewModel] in
      viewModel.toggleLeftSidebar()
    }
    .focusedSceneValue(\.toggleRightSidebarAction) { [viewModel] in
      viewModel.toggleSidebar()
    }
    .focusedSceneValue(\.openSearchAction) { [viewModel] in
      viewModel.openSearch()
    }
    .focusedSceneValue(\.findNextAction) { [viewModel] in
      viewModel.navigateToNextMatch()
    }
    .focusedSceneValue(\.findPreviousAction) { [viewModel] in
      viewModel.navigateToPreviousMatch()
    }
    .onChange(of: viewModel.editorContent) { _, newContent in
      syncDocument()
    }
    .onChange(of: viewModel.notebook.metadata.title) { _, _ in
      syncDocument()
    }
    .animation(.easeInOut(duration: 0.2), value: viewModel.isRightSidebarVisible)
    .animation(.easeInOut(duration: 0.2), value: viewModel.isLeftSidebarVisible)
    .onAppear {
      setupKeyEventMonitor()
      viewModel.onDocumentChanged = syncDocument

      // Auto-connect to saved session if available
      viewModel.autoConnectIfNeeded()
    }
    .onDisappear {
      removeKeyEventMonitor()
      viewModel.onDocumentChanged = nil

      // Disconnect from database when window closes to prevent connection leaks
      Task {
        await viewModel.connectionManager.disconnect()
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

    print(
      "🔄 [EditorContentView] syncDocument() - content changed from \(oldContent.count) to \(newContent.count) chars"
    )

    // Sync editorContent back to document
    document.content = newContent
    document.metadata = newMetadata

    // Register undo action to mark document as dirty
    // This is critical for ReferenceFileDocument to know the document has changed
    if let undoManager = undoManager {
      print("📝 [EditorContentView] Registering undo action")
      undoManager.registerUndo(withTarget: document) { [oldContent, oldMetadata] doc in
        doc.content = oldContent
        doc.metadata = oldMetadata
      }
    } else {
      print("⚠️ [EditorContentView] No undoManager available!")
    }

    lastSaved = nil  // Mark as unsaved
  }

  // MARK: - Keyboard Event Monitoring

  private func setupKeyEventMonitor() {
    keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
      // Only handle events for the key window
      // The focusedSceneValue system ensures commands are routed to the right window
      guard let eventWindow = event.window,
        eventWindow == NSApplication.shared.keyWindow
      else {
        return event  // Not our window, pass through
      }

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
        // Priority 0: If search panel is open, close it first
        if self.viewModel.isSearchPanelVisible {
          Task { @MainActor [viewModel] in
            viewModel.closeSearch()
          }
          return nil  // Event consumed
        }

        // Priority 1: If right sidebar is open, close it
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

// MARK: - Search Notification Handler Modifier

private struct EditorSearchNotificationHandlerModifier: ViewModifier {
  let viewModel: NotebookViewModel

  func body(content: Content) -> some View {
    content
      .onReceive(NotificationCenter.default.publisher(for: .openSearch)) { _ in
        viewModel.openSearch()
      }
      .onReceive(NotificationCenter.default.publisher(for: .findNext)) { _ in
        viewModel.navigateToNextMatch()
      }
      .onReceive(NotificationCenter.default.publisher(for: .findPrevious)) { _ in
        viewModel.navigateToPreviousMatch()
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
