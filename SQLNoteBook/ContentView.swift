//
//  ContentView.swift
//  SQLNotebook
//

import SwiftUI

struct ContentView: View {
    @Binding var document: SQLNotebookDocument
    @State private var viewModel: NotebookViewModel
    @State private var showConnectionSheet = false
    @State private var lastSaved: Date?

    @State private var keyEventMonitor: Any?

    init(document: Binding<SQLNotebookDocument>) {
        self._document = document
        self._viewModel = State(initialValue: NotebookViewModel(notebook: document.wrappedValue.notebook))
    }

    var body: some View {
        ZStack {
            Color.appBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HeaderView(viewModel: viewModel, showConnectionSheet: $showConnectionSheet)

                // Main content area
                HStack(spacing: 0) {
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
        }
        .sheet(isPresented: $showConnectionSheet) {
            ConnectionSheet(viewModel: viewModel, isPresented: $showConnectionSheet)
        }
        .modifier(NotificationHandlerModifier(viewModel: viewModel, syncDocument: syncDocument))
        .onChange(of: viewModel.notebook.metadata.title) { _, _ in
            syncDocument()
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.isRightSidebarVisible)
        .onAppear {
            setupKeyEventMonitor()
        }
        .onDisappear {
            removeKeyEventMonitor()
        }
    }

    // MARK: - Document Sync

    private func syncDocument() {
        document.notebook = viewModel.notebook
        lastSaved = nil // Mark as unsaved
    }

    // MARK: - Keyboard Event Monitoring

    private func setupKeyEventMonitor() {
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            // Check if a NSTextView is currently first responder
            let textViewIsFocused: Bool = {
                guard let window = NSApplication.shared.keyWindow,
                      let firstResponder = window.firstResponder else {
                    return false  // No window or responder = no text view focused
                }
                return firstResponder is NSTextView
            }()

            // If a text view is focused, let it handle the event
            if textViewIsFocused {
                return event
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
                Task { @MainActor in
                    if isUpArrow {
                        self.viewModel.selectPreviousCell()
                    } else if isDownArrow {
                        self.viewModel.selectNextCell(createIfNeeded: false)
                    }
                }
                return nil // Event consumed
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
                LazyVStack(spacing: Spacing.md) {
                    ForEach($viewModel.notebook.cells) { $cell in
                        CellView(
                            viewModel: viewModel,
                            cell: $cell,
                            isSelected: viewModel.selectedCellId == cell.id,
                            onRun: {
                                Task {
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

                    // Add cell button at the bottom
                    addCellButton
                }
                .padding(Spacing.lg)
            }
            .onChange(of: viewModel.selectedCellId) { _, newId in
                if let id = newId {
                    withAnimation {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    private var addCellButton: some View {
        HStack(spacing: Spacing.md) {
            Button(action: {
                viewModel.addCell(type: .sql)
                syncDocument()
            }) {
                Label("Add Code", systemImage: "plus")
            }
            .buttonStyle(GhostButtonStyle())

            Button(action: {
                viewModel.addCell(type: .markdown)
                syncDocument()
            }) {
                Label("Add Markdown", systemImage: "plus")
            }
            .buttonStyle(GhostButtonStyle())
        }
        .padding(.vertical, Spacing.xl)
    }
}

// MARK: - Preview

#Preview {
    // Create 3 cells: SQL with content, SQL empty, and Markdown
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
            ColumnInfo(name: "email", type: "VARCHAR")
        ],
        rows: [
            [.int(1), .string("Alice Johnson"), .string("alice@example.com")],
            [.int(2), .string("Bob Smith"), .string("bob@example.com")],
            [.int(3), .string("Charlie Davis"), .string("charlie@example.com")],
            [.int(4), .string("Diana Wilson"), .string("diana@example.com")],
            [.int(5), .string("Eve Martinez"), .string("eve@example.com")]
        ],
        executionTime: 0.045,
        rowCount: 5,
        timestamp: Date()
    )
    
    let sqlCellEmpty = NotebookCell(
        cellType: .sql,
        content: ""
    )
    
    let markdownCell = NotebookCell(
        cellType: .markdown,
        content: "# Sample Markdown\n\nThis is a markdown cell with **bold** and *italic* text."
    )
    
    let notebook = SQLNotebook(
        cells: [sqlCellWithContent, markdownCell, sqlCellEmpty],
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
    @State private var showConnectionSheet = false
    @State private var lastSaved: Date?
    
    var body: some View {
        ZStack {
            Color.appBackground
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                HeaderView(viewModel: viewModel, showConnectionSheet: $showConnectionSheet)
                
                HStack(spacing: 0) {
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
                                Task {
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

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .addCodeCell)) { _ in
                viewModel.addCell(type: .sql)
                syncDocument()
            }
            .onReceive(NotificationCenter.default.publisher(for: .addMarkdownCell)) { _ in
                viewModel.addCell(type: .markdown)
                syncDocument()
            }
            .onReceive(NotificationCenter.default.publisher(for: .runCell)) { _ in
                if let id = viewModel.selectedCellId {
                    Task {
                        await viewModel.runCell(id: id)
                        syncDocument()
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .runCellAndSelectNext)) { _ in
                if let id = viewModel.selectedCellId {
                    Task {
                        await viewModel.runCell(id: id)
                        viewModel.selectNextCell(createIfNeeded: true)
                        syncDocument()
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .runCellAndInsertBelow)) { _ in
                if let id = viewModel.selectedCellId {
                    Task {
                        await viewModel.runCell(id: id)
                        viewModel.insertCellBelow(type: .sql)
                        syncDocument()
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .runAllCells)) { _ in
                Task {
                    await viewModel.runAllCells()
                    syncDocument()
                }
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
            .onReceive(NotificationCenter.default.publisher(for: .selectNextCell)) { _ in
                viewModel.selectNextCell(createIfNeeded: false)
            }
            .onReceive(NotificationCenter.default.publisher(for: .selectPreviousCell)) { _ in
                viewModel.selectPreviousCell()
            }
    }
}
