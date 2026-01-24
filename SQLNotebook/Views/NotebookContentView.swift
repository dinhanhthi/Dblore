//
//  NotebookContentView.swift
//  SQLNotebook
//

import SwiftUI

/// Content view for Notebook mode (.sqlnb files)
struct NotebookContentView: View {
  @ObservedObject var document: SQLNotebookDocument
  @State private var viewModel: NotebookViewModel
  @State private var lastSaved: Date?

  @State private var keyEventMonitor: Any?
  @State private var focusedTextView: NSTextView?
  @State private var isCellValueEditing = false
  @State private var showRunAllConfirmation = false
  @Bindable private var appSettings = AppSettings.shared
  @Environment(\.undoManager) private var undoManager

  init(document: SQLNotebookDocument) {
    self.document = document
    let vm = NotebookViewModel(notebook: document.notebook)
    // Force notebook mode
    vm.viewMode = .notebook
    _viewModel = State(initialValue: vm)
  }

  var body: some View {
    NotebookLayoutView(
      viewModel: viewModel,
      lastSaved: $lastSaved,
      isEditorMode: false
    ) {
      // Main scrollable content (notebook mode)
      mainContent
    }
    .modifier(
      NotebookNotificationHandlerModifier(
        viewModel: viewModel,
        syncDocument: syncDocument,
        showRunAllConfirmation: $showRunAllConfirmation
      )
    )
    .destructiveQueryDialog(viewModel: viewModel, syncDocument: syncDocument)
    .searchNotifications(viewModel: viewModel)
    .focusedSceneActions(viewModel: viewModel, mode: .notebook)
    .modifier(
      UndoRedoHandlerModifier(
        viewModel: viewModel,
        syncDocument: syncDocument,
        focusedTextView: $focusedTextView,
        isCellValueEditing: $isCellValueEditing
      )
    )
    .confirmationDialog(
      "Run all cells?",
      isPresented: $showRunAllConfirmation,
      titleVisibility: .visible
    ) {
      Button("Run All Cells", role: .none) {
        Task { @MainActor [viewModel] in
          await viewModel.runAllCells()
          syncDocument()
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This will execute all SQL cells in sequence. Existing results will be replaced.")
    }
    .alert(
      "File Size Warning",
      isPresented: $viewModel.showFileSizeWarningDialog,
      actions: {
        Button("OK", role: .cancel) {}
        Button("Open Settings") {
          viewModel.rightSidebarContent = .settings
          viewModel.isRightSidebarVisible = true
        }
      },
      message: {
        Text(
          "Your notebook file size is approaching the recommended limit (\(FileOptimizationService.formatFileSize(FileOptimizationService.warningSizeThreshold))). Consider removing old results or creating a new notebook to maintain optimal performance."
        )
      }
    )
    .alert(
      "File Size Limit Exceeded",
      isPresented: $viewModel.showFileSizeLargeDialog,
      actions: {
        Button("OK", role: .cancel) {}
        Button("Remove All Results") {
          viewModel.clearAllOutputs()
          syncDocument()
        }
        Button("Open Settings") {
          viewModel.rightSidebarContent = .settings
          viewModel.isRightSidebarVisible = true
        }
      },
      message: {
        Text(
          "Your notebook file size has exceeded the limit (\(FileOptimizationService.formatFileSize(FileOptimizationService.largeSizeThreshold))). You cannot add new cells until you reduce the file size. Consider removing old results or creating a new notebook."
        )
      }
    )
    .onChange(of: viewModel.notebook.metadata.title) { _, _ in
      syncDocument()
    }
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
    // Capture old value before changing
    let oldNotebook = document.notebook

    print(
      "🔄 [NotebookContentView] syncDocument() - notebook changed (cells: \(viewModel.notebook.cells.count))"
    )

    // Sync notebook back to document
    document.notebook = viewModel.notebook

    // Register undo action to mark document as dirty
    // This is critical for ReferenceFileDocument to know the document has changed
    if let undoManager = undoManager {
      print("📝 [NotebookContentView] Registering undo action")
      undoManager.registerUndo(withTarget: document) { [oldNotebook] doc in
        doc.notebook = oldNotebook
      }
    } else {
      print("⚠️ [NotebookContentView] No undoManager available!")
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

      // Check if a NSTextView is currently first responder
      let textViewIsFocused: Bool = {
        guard let firstResponder = eventWindow.firstResponder else {
          return false  // No responder = no text view focused
        }
        return firstResponder is NSTextView
      }()

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

      // Handle Cmd+Z (Undo) and Cmd+Shift+Z (Redo)
      let isZ = event.keyCode == 6  // Z key
      let hasCommand = event.modifierFlags.contains(.command)
      let hasShift = event.modifierFlags.contains(.shift)

      if isZ && hasCommand {
        // If editing cell value, let TextEditor handle its own undo/redo natively
        if self.isCellValueEditing {
          return event  // Let TextEditor handle it
        }

        // For cell content editors and cell-level operations, post notifications
        if hasShift {
          NotificationCenter.default.post(name: .redo, object: nil)
        } else {
          NotificationCenter.default.post(name: .undo, object: nil)
        }
        return nil  // Event consumed
      }

      // If a text view is focused, let it handle the event
      if textViewIsFocused {
        return event
      }

      // Handle Enter key - focus on the selected cell's editor
      let isReturn = event.keyCode == 36
      if isReturn {
        // Check for modifier keys
        let modifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        let hasModifiers = !event.modifierFlags.intersection(modifiers).isEmpty

        // Only handle plain Enter (no modifiers)
        if !hasModifiers {
          NotificationCenter.default.post(name: .focusEditor, object: nil)
          return nil  // Event consumed
        }
      }

      // Handle up/down arrows for cell navigation when text view is NOT focused
      let isUpArrow = event.keyCode == 126
      let isDownArrow = event.keyCode == 125

      if isUpArrow || isDownArrow {
        // Check for actual modifier keys (Cmd, Ctrl, Alt, Shift) - ignore function key flag
        let modifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        let hasModifiers = !event.modifierFlags.intersection(modifiers).isEmpty

        guard !hasModifiers else {
          return event
        }

        // Use MainActor to ensure we're on the main thread
        Task { @MainActor [viewModel] in
          if isUpArrow {
            viewModel.selectPreviousCell()
          } else if isDownArrow {
            viewModel.selectNextCell(createIfNeeded: false)
          }
        }
        return nil  // Event consumed
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

  // MARK: - Main Content

  private var mainContent: some View {
    ScrollViewReader { proxy in
      List {
        ForEach(viewModel.notebook.cells) { cell in
          CellView(
            viewModel: viewModel,
            cell: binding(for: cell.id),
            isSelected: viewModel.selectedCellId == cell.id,
            onRun: {
              // Use confirmAndRunCell to check for destructive queries
              viewModel.confirmAndRunCell(id: cell.id)
              syncDocument()
            }
          )
          .id(cell.id)
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
          .listRowInsets(
            EdgeInsets(
              top: Spacing.md, leading: Spacing.sm, bottom: Spacing.md, trailing: Spacing.sm))
        }
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .onChange(of: viewModel.selectedCellId) { _, newId in
        if let id = newId {
          withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(id, anchor: nil)
          }
        }
      }
    }
  }

  // MARK: - Helper for Safe Binding

  /// Creates a safe binding for a cell by ID to avoid mutation conflicts in LazyVStack
  private func binding(for cellId: UUID) -> Binding<NotebookCell> {
    Binding(
      get: {
        self.viewModel.notebook.cells.first(where: { $0.id == cellId }) ?? NotebookCell()
      },
      set: { newValue in
        if let index = self.viewModel.notebook.cells.firstIndex(where: { $0.id == cellId }) {
          self.viewModel.notebook.cells[index] = newValue
          self.syncDocument()
        }
      }
    )
  }
}

// MARK: - Notification Handler Modifier

private struct NotebookNotificationHandlerModifier: ViewModifier {
  let viewModel: NotebookViewModel
  let syncDocument: () -> Void
  @Binding var showRunAllConfirmation: Bool

  func body(content: Content) -> some View {
    content
      .onReceive(NotificationCenter.default.publisher(for: .addCodeCell)) { _ in
        viewModel.addCell(type: .sql)
        syncDocument()
      }
      .onReceive(NotificationCenter.default.publisher(for: .runCell)) { _ in
        if let id = viewModel.selectedCellId {
          viewModel.confirmAndRunCell(id: id)
          syncDocument()
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .runCellAndSelectNext)) { _ in
        if let id = viewModel.selectedCellId {
          viewModel.confirmAndRunCell(id: id)
          viewModel.selectNextCell(createIfNeeded: true)
          syncDocument()
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .runCellAndInsertBelow)) { _ in
        if let id = viewModel.selectedCellId {
          viewModel.confirmAndRunCell(id: id)
          viewModel.insertCellBelow(type: .sql)
          syncDocument()
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .runAllCells)) { _ in
        showRunAllConfirmation = true
      }
      .onReceive(NotificationCenter.default.publisher(for: .clearCellOutput)) { _ in
        if let id = viewModel.selectedCellId {
          viewModel.clearCellOutput(id: id)
          syncDocument()
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .clearAllOutputs)) { _ in
        viewModel.clearAllOutputs()
        syncDocument()
      }
      .onReceive(NotificationCenter.default.publisher(for: .deleteCell)) { _ in
        if let id = viewModel.selectedCellId {
          viewModel.deleteCell(id: id)
          syncDocument()
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .duplicateCell)) { _ in
        if let id = viewModel.selectedCellId {
          viewModel.duplicateCell(id: id)
          syncDocument()
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .selectNextCell)) { _ in
        viewModel.selectNextCell(createIfNeeded: false)
      }
      .onReceive(NotificationCenter.default.publisher(for: .selectPreviousCell)) { _ in
        viewModel.selectPreviousCell()
      }
      .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
        // Toggle settings sidebar: if already showing settings, close it; otherwise show settings
        if viewModel.isRightSidebarVisible && viewModel.rightSidebarContent == .settings {
          viewModel.isRightSidebarVisible = false
        } else {
          viewModel.rightSidebarContent = .settings
          viewModel.isRightSidebarVisible = true
        }
      }
  }
}

// MARK: - Undo/Redo Handler Modifier

private struct UndoRedoHandlerModifier: ViewModifier {
  let viewModel: NotebookViewModel
  let syncDocument: () -> Void
  @Binding var focusedTextView: NSTextView?
  @Binding var isCellValueEditing: Bool

  func body(content: Content) -> some View {
    content
      .onReceive(NotificationCenter.default.publisher(for: .undo)) { _ in
        handleUndo()
      }
      .onReceive(NotificationCenter.default.publisher(for: .redo)) { _ in
        handleRedo()
      }
      .onReceive(NotificationCenter.default.publisher(for: .editorFocused)) { notification in
        if let textView = notification.object as? NSTextView {
          focusedTextView = textView
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .editorUnfocused)) { _ in
        focusedTextView = nil
      }
      .onReceive(NotificationCenter.default.publisher(for: .cellValueEditingStarted)) { _ in
        isCellValueEditing = true
      }
      .onReceive(NotificationCenter.default.publisher(for: .cellValueEditingEnded)) { _ in
        isCellValueEditing = false
      }
  }

  private func handleUndo() {
    if let textView = focusedTextView, let undoManager = textView.undoManager {
      // Editor is focused - use editor's undo manager
      undoManager.undo()
    } else {
      // No editor focused - use cell-level undo manager
      viewModel.undoManager.undo()
      syncDocument()
    }
  }

  private func handleRedo() {
    if let textView = focusedTextView, let undoManager = textView.undoManager {
      // Editor is focused - use editor's undo manager
      undoManager.redo()
    } else {
      // No editor focused - use cell-level undo manager
      viewModel.undoManager.redo()
      syncDocument()
    }
  }
}

// MARK: - Previews

#Preview("Notebook") {
  NotebookContentView(document: NotebookPreviewData.documentWithCells)
    .frame(width: 1000, height: 600)
}

#Preview("Notebook - Empty") {
  NotebookContentView(document: SQLNotebookDocument())
    .frame(width: 800, height: 600)
}

// MARK: - Preview Data

private enum NotebookPreviewData {
  static var documentWithCells: SQLNotebookDocument {
    let cells = [
      NotebookCell(
        cellType: .sql,
        content: "-- Welcome to SQLNotebook\nSELECT * FROM users LIMIT 10;"
      ),
      cellWithResult,
      NotebookCell(
        cellType: .sql,
        content: "SELECT COUNT(*) as total FROM orders WHERE status = 'completed';"
      ),
    ]

    let notebook = SQLNotebook(
      cells: cells,
      metadata: NotebookMetadata(title: "Sample Notebook"),
      documentType: .notebook
    )

    return SQLNotebookDocument(notebook: notebook)
  }

  static var cellWithResult: NotebookCell {
    var cell = NotebookCell(
      cellType: .sql,
      content: "SELECT id, name, email, created_at\nFROM users\nLIMIT 5;"
    )
    cell.result = CellResult(
      columns: [
        ColumnInfo(name: "id", type: "INTEGER"),
        ColumnInfo(name: "name", type: "VARCHAR"),
        ColumnInfo(name: "email", type: "VARCHAR"),
        ColumnInfo(name: "created_at", type: "TIMESTAMP"),
      ],
      rows: [
        [.int(1), .string("Alice"), .string("alice@example.com"), .string("2024-01-15")],
        [.int(2), .string("Bob"), .string("bob@example.com"), .string("2024-01-16")],
        [.int(3), .string("Charlie"), .string("charlie@example.com"), .string("2024-01-17")],
        [.int(4), .string("Diana"), .string("diana@example.com"), .string("2024-01-18")],
        [.int(5), .string("Eve"), .string("eve@example.com"), .string("2024-01-19")],
      ],
      executionTime: 0.023,
      rowCount: 5,
      timestamp: Date()
    )
    cell.executionCount = 1
    return cell
  }
}
