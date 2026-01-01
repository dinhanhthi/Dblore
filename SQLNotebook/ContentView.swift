//
//  ContentView.swift
//  SQLNotebook
//

import SwiftUI

struct ContentView: View {
  @Binding var document: SQLNotebookDocument
  @State private var viewModel: NotebookViewModel
  @State private var lastSaved: Date?

  @State private var keyEventMonitor: Any?
  @State private var focusedTextView: NSTextView?
  @State private var isCellValueEditing = false
  @State private var showRunAllConfirmation = false

  init(document: Binding<SQLNotebookDocument>) {
    self._document = document
    let vm = NotebookViewModel(notebook: document.wrappedValue.notebook)
    self._viewModel = State(initialValue: vm)
  }

  var body: some View {
    ZStack {
      Color.appBackground
        .ignoresSafeArea()

      VStack(spacing: 0) {
        // Header
        HeaderView(viewModel: viewModel)

        // Main content area
        HStack(spacing: 0) {
          // Left sidebar (conditionally shown)
          if viewModel.isLeftSidebarVisible {
            LeftSidebarView(viewModel: viewModel)
              .transition(.move(edge: .leading))
          }

          // Main scrollable content
          mainContent
            .frame(maxWidth: .infinity)

          // Right sidebar (conditionally shown)
          if viewModel.isRightSidebarVisible {
            RightSidebarView(viewModel: viewModel)
              .transition(.move(edge: .trailing))
          }
        }

        // Footer
        FooterView(viewModel: viewModel, lastSaved: lastSaved)
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
    .modifier(
      NotificationHandlerModifier(
        viewModel: viewModel,
        syncDocument: syncDocument,
        showRunAllConfirmation: $showRunAllConfirmation
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
    .modifier(
      UndoRedoHandlerModifier(
        viewModel: viewModel,
        syncDocument: syncDocument,
        focusedTextView: $focusedTextView,
        isCellValueEditing: $isCellValueEditing
      )
    )
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
    }
  }

  // MARK: - Document Sync

  private func syncDocument() {
    document.notebook = viewModel.notebook
    lastSaved = nil  // Mark as unsaved
  }

  // MARK: - Keyboard Event Monitoring

  private func setupKeyEventMonitor() {
    keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
      // Check if a NSTextView is currently first responder
      let textViewIsFocused: Bool = {
        guard let window = NSApplication.shared.keyWindow,
          let firstResponder = window.firstResponder
        else {
          return false  // No window or responder = no text view focused
        }
        return firstResponder is NSTextView
      }()

      // Handle ESC key
      let isEscape = event.keyCode == 53
      if isEscape {
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
      ScrollView {
        LazyVStack(spacing: Spacing.lg) {
          ForEach($viewModel.notebook.cells) { $cell in
            CellView(
              viewModel: viewModel,
              cell: $cell,
              isSelected: viewModel.selectedCellId == cell.id,
              onRun: {
                Task { @MainActor [viewModel] in
                  await viewModel.runCell(id: cell.id)
                  syncDocument()
                }
              }
            )
            .id(cell.id)
            .onChange(of: cell.content) { _, _ in
              syncDocument()
            }
          }
        }
        .padding(Spacing.lg)
      }
      .onChange(of: viewModel.selectedCellId) { _, newId in
        if let id = newId {
          withAnimation {
            // Only scroll if the cell is not visible (no anchor means minimal scroll to make visible)
            proxy.scrollTo(id, anchor: nil)
          }
        }
      }
    }
  }
}

// MARK: - Preview

#Preview {
  // Create 2 cells: SQL with content and SQL empty
  var sqlCellWithContent = NotebookCell(
    cellType: .sql,
    content: "SELECT id, name, email\nFROM users\nWHERE created_at > '2024-01-01'\nORDER BY name;",
    executionCount: 1
  )

  // Add example result table
  sqlCellWithContent.result = CellResult(
    columns: [
      ColumnInfo(name: "id", type: "INTEGER"),
      ColumnInfo(name: "name", type: "VARCHAR"),
      ColumnInfo(name: "email", type: "VARCHAR"),
    ],
    rows: [
      [.int(1), .string("Alice Johnson"), .string("alice@example.com")],
      [.int(2), .string("Bob Smith"), .string("bob@example.com")],
      [.int(3), .string("Charlie Davis"), .string("charlie@example.com")],
      [.int(4), .string("Diana Wilson"), .string("diana@example.com")],
      [.int(5), .string("Eve Martinez"), .string("eve@example.com")],
    ],
    executionTime: 0.045,
    rowCount: 5,
    timestamp: Date()
  )

  let sqlCellEmpty = NotebookCell(
    cellType: .sql,
    content: ""
  )

  let notebook = SQLNotebook(
    cells: [sqlCellWithContent, sqlCellEmpty],
    metadata: NotebookMetadata(title: "Preview Notebook")
  )

  struct PreviewContainer: View {
    @State var document: SQLNotebookDocument
    @State var viewModel: NotebookViewModel

    init(notebook: SQLNotebook, selectedCellId: UUID) {
      let doc = SQLNotebookDocument(notebook: notebook)
      self._document = State(initialValue: doc)

      let vm = NotebookViewModel(notebook: notebook)
      vm.selectedCellId = selectedCellId
      self._viewModel = State(initialValue: vm)
    }

    var body: some View {
      ContentViewForPreview(document: $document, viewModel: viewModel)
    }
  }

  return PreviewContainer(notebook: notebook, selectedCellId: sqlCellWithContent.id)
    .frame(width: 820, height: 600)
    .preferredColorScheme(.dark)
}

// Preview version of ContentView with injectable viewModel
private struct ContentViewForPreview: View {
  @Binding var document: SQLNotebookDocument
  @State var viewModel: NotebookViewModel
  @State private var lastSaved: Date?

  var body: some View {
    ZStack {
      Color.appBackground
        .ignoresSafeArea()

      VStack(spacing: 0) {
        HeaderView(viewModel: viewModel)

        HStack(spacing: 0) {
          // Left sidebar (conditionally shown)
          if viewModel.isLeftSidebarVisible {
            LeftSidebarView(viewModel: viewModel)
              .transition(.move(edge: .leading))
          }

          mainContent
            .frame(maxWidth: .infinity)

          if viewModel.isRightSidebarVisible {
            RightSidebarView(viewModel: viewModel)
              .transition(.move(edge: .trailing))
          }
        }

        FooterView(viewModel: viewModel, lastSaved: lastSaved)
      }
    }
    .animation(.easeInOut(duration: 0.2), value: viewModel.isRightSidebarVisible)
    .animation(.easeInOut(duration: 0.2), value: viewModel.isLeftSidebarVisible)
  }

  private var mainContent: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: Spacing.md) {
          ForEach($viewModel.notebook.cells) { $cell in
            CellView(
              viewModel: viewModel,
              cell: $cell,
              isSelected: viewModel.selectedCellId == cell.id,
              onRun: {
                Task { @MainActor [viewModel] in
                  await viewModel.runCell(id: cell.id)
                }
              }
            )
            .id(cell.id)
          }
        }
        .padding(Spacing.lg)
      }
    }
  }
}

// MARK: - Notification Handler Modifier
// Extracted to reduce type complexity in ContentView body

private struct NotificationHandlerModifier: ViewModifier {
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
          Task { @MainActor [viewModel] in
            await viewModel.runCell(id: id)
            syncDocument()
          }
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .runCellAndSelectNext)) { _ in
        if let id = viewModel.selectedCellId {
          Task { @MainActor [viewModel] in
            await viewModel.runCell(id: id)
            viewModel.selectNextCell(createIfNeeded: true)
            syncDocument()
          }
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .runCellAndInsertBelow)) { _ in
        if let id = viewModel.selectedCellId {
          Task { @MainActor [viewModel] in
            await viewModel.runCell(id: id)
            viewModel.insertCellBelow(type: .sql)
            syncDocument()
          }
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
      .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in
        viewModel.toggleSidebar()
      }
      .onReceive(NotificationCenter.default.publisher(for: .toggleLeftSidebar)) { _ in
        viewModel.toggleLeftSidebar()
      }
      .onReceive(NotificationCenter.default.publisher(for: .selectNextCell)) { _ in
        viewModel.selectNextCell(createIfNeeded: false)
      }
      .onReceive(NotificationCenter.default.publisher(for: .selectPreviousCell)) { _ in
        viewModel.selectPreviousCell()
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
    // Note: Cell value editing is handled by key event monitor
    // If we reach here, it's either cell content editing or cell-level operations

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
    // Note: Cell value editing is handled by key event monitor
    // If we reach here, it's either cell content editing or cell-level operations

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
