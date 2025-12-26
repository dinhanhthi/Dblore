//
//  CellView.swift
//  SQLNotebook
//

import AppKit
import SwiftUI

struct CellView: View {
  @Bindable var viewModel: NotebookViewModel
  @Binding var cell: NotebookCell
  let isSelected: Bool
  let onRun: () -> Void

  @State private var isHovered = false  // For run button visibility
  @State private var isCellHovered = false  // For cell border hover effect
  @State private var isBottomEdgeHovered = false  // For floating action panel
  @State private var isCopied = false  // For copy button feedback
  @FocusState private var isEditorFocused: Bool

  var body: some View {
    ZStack(alignment: .topTrailing) {
      ZStack(alignment: .bottom) {
        VStack(spacing: 0) {
          // Main cell content
          HStack(alignment: .top, spacing: 0) {
            // Left sidebar with controls
            cellSidebar

            // Editor area
            VStack(alignment: .leading, spacing: 0) {
              editorArea
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .padding(.top, Spacing.md)
          .padding(.bottom, Spacing.md)
          .padding(.leading, 0)
          .padding(.trailing, Spacing.md)

          // Result area (if exists)
          if let result = cell.result {
            resultArea(result)
          }
        }
        .cellStyle(isSelected: isSelected, isHovered: !isSelected && isCellHovered)
        .onHover { hovering in
          isHovered = hovering
          isCellHovered = hovering
        }

        // Bottom edge hover zone (invisible, just for hover detection)
        // Extends below the cell to cover the floating panel area
        bottomEdgeHoverZone
          .offset(y: 15)  // Extend zone downward to match panel position

        // Floating action panel (shown on hover near bottom edge)
        if isBottomEdgeHovered {
          floatingActionPanel
            .offset(y: 12)
        }
      }

      // Top-right floating panel (shown only when cell is selected)
      if isSelected {
        topRightFloatingPanel.offset(x: -10, y: -15)
      }
    }
    .onTapGesture {
      viewModel.selectedCellId = cell.id
      // Clear editor focus when clicking outside editor
      isEditorFocused = false
    }
    .contextMenu {
      cellContextMenu
    }
    .onChange(of: isSelected) { oldValue, newValue in
      // Clear focus when cell becomes unselected
      if !newValue {
        isEditorFocused = false
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .focusEditor)) { _ in
      // Only focus if this cell is selected
      if isSelected {
        isEditorFocused = true
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .unfocusEditor)) { _ in
      // Unfocus from editor but keep cell selected
      isEditorFocused = false
    }
  }

  // MARK: - Bottom Edge Hover Zone

  /// Invisible hover zone at the bottom edge of the cell (Jupyter-style)
  /// This zone is offset downward to align with the floating panel position
  private var bottomEdgeHoverZone: some View {
    Color.clear
      .frame(height: 50)  // Height of the hover-sensitive area
      .contentShape(Rectangle())
      .onHover { hovering in
        isBottomEdgeHovered = hovering
      }
  }

  // MARK: - Cell Sidebar

  @ViewBuilder
  private var cellSidebar: some View {
    VStack(spacing: Spacing.sm) {
      // Run button
      Button(action: onRun) {
        if cell.isRunning {
          ProgressView()
            .scaleEffect(0.7)
            .frame(width: 20, height: 20)
        } else {
          Image(systemName: "play.fill")
            .font(.system(size: 12))
            .foregroundColor(isHovered || isSelected ? .foreground : .foregroundMuted)
            .frame(width: 20, height: 20)
        }
      }
      .buttonStyle(GhostButtonStyle())
      .contentShape(Rectangle())
      .disabled(cell.isRunning)

      // Execution count
      if let count = cell.executionCount {
        Text("[\(count)]")
          .font(.monoSmall)
          .foregroundColor(.foregroundSubtle)
      }
    }
    .frame(width: ComponentSize.cellSidebarWidth)
    .padding(.top, Spacing.xs)
  }

  // MARK: - Floating Action Panel

  private var floatingActionPanel: some View {
    FloatingPanelButton(
      icon: "plus.square",
      helpText: "Add Code Cell Below",
      action: {
        viewModel.addCell(type: .sql, after: cell.id)
      }
    )
    .onHover { hovering in
      // Keep panel visible when hovering over the button itself
      isBottomEdgeHovered = hovering
    }
  }

  // MARK: - Top-Right Floating Panel

  private var topRightFloatingPanel: some View {
    HStack(spacing: Spacing.sm) {
      FloatingPanelButton(
        icon: "trash",
        helpText: "Delete Cell",
        action: {
          viewModel.deleteCell(id: cell.id)
        }
      )

      FloatingPanelButton(
        icon: isCopied ? "checkmark" : "doc.on.doc",
        helpText: "Copy Cell Content",
        useSymbolEffect: true,
        action: copyCellContent
      )
    }
    .padding(.top, Spacing.xs)
    .padding(.trailing, Spacing.xs)
  }

  // MARK: - Helper Functions

  private func copyCellContent() {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(cell.content, forType: .string)

    // Show checkmark feedback
    isCopied = true

    // Reset back to copy icon after 500ms
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      isCopied = false
    }
  }

  // MARK: - Editor Area

  @ViewBuilder
  private var editorArea: some View {
    SQLEditorView(
      content: $cell.content,
      isSelected: isSelected,
      isFocused: isEditorFocused,
      onFocus: { viewModel.selectedCellId = cell.id }
    )
    .focused($isEditorFocused)
  }

  // MARK: - Result Area

  @ViewBuilder
  private func resultArea(_ result: CellResult) -> some View {
    HStack(alignment: .top, spacing: 0) {
      // Fake sidebar to align with cell sidebar
      Color.clear
        .frame(width: ComponentSize.cellSidebarWidth)

    VStack(alignment: .leading, spacing: Spacing.md) {
        if let error = result.error {
          // Error display
          errorView(error)
        } else {
          // Result table
          ResultTableView(result: result, viewModel: viewModel)

          // Result metadata
          resultMetadata(result)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 0)
      .padding(.bottom, 0)
      .padding(.trailing, Spacing.md)
    }
    .padding(.bottom, Spacing.md)
  }

  private func errorView(_ error: String) -> some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundColor(.destructive)

      Text(error)
        .font(.mono)
        .foregroundColor(.destructive)
    }
    .padding(Spacing.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.destructive.opacity(0.1))
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
  }

  private func resultMetadata(_ result: CellResult) -> some View {
    HStack(spacing: Spacing.md) {
      Text("Rows: \(result.rowCount)")
      Text("|")
        .foregroundColor(.foregroundSubtle)
      Text(String(format: "Execution time: %.3fs", result.executionTime))
      Text("|")
        .foregroundColor(.foregroundSubtle)
      Text(formatTimestamp(result.timestamp))
    }
    .font(.caption)
    .foregroundColor(.foregroundSubtle)
  }

  private func formatTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .medium
    return formatter.string(from: date)
  }

  // MARK: - Context Menu

  @ViewBuilder
  private var cellContextMenu: some View {
    Button(action: onRun) {
      Label("Run", systemImage: "play.fill")
    }

    Divider()

    Button(action: { viewModel.duplicateCell(id: cell.id) }) {
      Label("Duplicate", systemImage: "doc.on.doc")
    }

    Button(action: { viewModel.moveSelectedCellUp() }) {
      Label("Move Up", systemImage: "arrow.up")
    }

    Button(action: { viewModel.moveSelectedCellDown() }) {
      Label("Move Down", systemImage: "arrow.down")
    }

    Divider()

    Button(action: { viewModel.clearCellOutput(id: cell.id) }) {
      Label("Clear Output", systemImage: "trash")
    }
    .disabled(cell.result == nil)

    Button(role: .destructive, action: { viewModel.deleteCell(id: cell.id) }) {
      Label("Delete", systemImage: "trash.fill")
    }
  }
}

// MARK: - SQL Editor View

struct SQLEditorView: View {
  @Binding var content: String
  let isSelected: Bool
  let isFocused: Bool
  var onFocus: (() -> Void)?

  var body: some View {
    ZStack(alignment: .topLeading) {
      // Placeholder
      if content.isEmpty {
        Text("-- Write your SQL query here...")
          .font(.system(size: 13, design: .monospaced))
          .foregroundColor(.foregroundSubtle)
          .padding(.horizontal, Spacing.sm + 4)
          .padding(.vertical, Spacing.xxs)
      }

      // Text editor with syntax highlighting
      HighlightedTextEditor(text: $content, onFocus: onFocus)
    }
    .padding(Spacing.sm)
    .background(Color.inputBackground)
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
    .overlay(
      RoundedRectangle(cornerRadius: CornerRadius.md)
        .stroke(isFocused ? Color.foregroundMuted.opacity(0.4) : Color.clear, lineWidth: 1)
    )
  }
}

// MARK: - SQL Text View (handles keyboard shortcuts)

class SQLTextView: NSTextView {
  var onFocus: (() -> Void)?
  var onBlur: ((String) -> Void)?  // Callback with current text when losing focus

  override func becomeFirstResponder() -> Bool {
    let result = super.becomeFirstResponder()
    if result {
      onFocus?()
      // Notify that this editor is now focused
      NotificationCenter.default.post(name: .editorFocused, object: self)
    }
    return result
  }

  override func resignFirstResponder() -> Bool {
    // Capture the string before calling super to avoid accessing potentially deallocated state
    let currentText = self.string
    let result = super.resignFirstResponder()
    if result {
      // Update binding when losing focus
      onBlur?(currentText)
      // Notify that this editor is no longer focused
      NotificationCenter.default.post(name: .editorUnfocused, object: self)
    }
    return result
  }

  override func keyDown(with event: NSEvent) {
    if handleCellShortcut(with: event) {
      return  // Handled, don't pass to super
    }
    if handleArrowNavigation(with: event) {
      return  // Handled, don't pass to super
    }
    super.keyDown(with: event)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if handleCellShortcut(with: event) {
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  /// Returns true if the event was handled as a cell shortcut
  private func handleCellShortcut(with event: NSEvent) -> Bool {
    let isEnter = event.keyCode == 36
    guard isEnter else { return false }

    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let hasControl = flags.contains(.control)
    let hasShift = flags.contains(.shift)
    let hasOption = flags.contains(.option)
    let hasCommand = flags.contains(.command)

    // Cmd+Shift+Enter -> Run All Cells
    if hasCommand && hasShift && !hasControl && !hasOption {
      NotificationCenter.default.post(name: .runAllCells, object: nil)
      return true
    }

    // Ctrl+Enter -> Run current cell (stay on current cell)
    if hasControl && !hasShift && !hasOption && !hasCommand {
      NotificationCenter.default.post(name: .runCell, object: nil)
      return true
    }

    // Shift+Enter -> Run cell and move to next (create new if last)
    if hasShift && !hasControl && !hasOption && !hasCommand {
      NotificationCenter.default.post(name: .runCellAndSelectNext, object: nil)
      return true
    }

    // Alt/Option+Enter -> Run cell and insert new cell below
    if hasOption && !hasControl && !hasShift && !hasCommand {
      NotificationCenter.default.post(name: .runCellAndInsertBelow, object: nil)
      return true
    }

    return false
  }

  /// Handles up/down arrow navigation between cells
  /// Returns true if the event was handled as a navigation action
  private func handleArrowNavigation(with event: NSEvent) -> Bool {
    let isUpArrow = event.keyCode == 126
    let isDownArrow = event.keyCode == 125

    guard isUpArrow || isDownArrow else { return false }

    // Check for actual modifier keys (Cmd, Ctrl, Alt, Shift) - ignore function key flag
    let modifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
    let hasModifiers = !event.modifierFlags.intersection(modifiers).isEmpty

    if hasModifiers {
      return false
    }

    let text = self.string
    let cursorPosition = self.selectedRange().location

    if isUpArrow {
      // Navigate to previous cell only if cursor is at the first line
      // Check if there's a newline before the cursor position
      let textBeforeCursor = text.prefix(cursorPosition)
      if !textBeforeCursor.contains("\n") {
        // No newline before cursor, we're on the first line
        NotificationCenter.default.post(name: .selectPreviousCell, object: nil)
        return true
      }
    } else if isDownArrow {
      // Navigate to next cell only if cursor is at the last line
      // Check if there's a newline after the cursor position
      let textAfterCursor = text.suffix(text.count - cursorPosition)
      if !textAfterCursor.contains("\n") {
        // No newline after cursor, we're on the last line
        NotificationCenter.default.post(name: .selectNextCell, object: nil)
        return true
      }
    }

    return false
  }
}

// MARK: - Highlighted Text Editor

struct HighlightedTextEditor: View {
  @Binding var text: String
  var onFocus: (() -> Void)?
  @State private var height: CGFloat = 40

  var body: some View {
    HighlightedTextEditorRepresentable(text: $text, height: $height, onFocus: onFocus)
      .frame(height: height)
  }
}

struct HighlightedTextEditorRepresentable: NSViewRepresentable {
  @Binding var text: String
  @Binding var height: CGFloat
  var onFocus: (() -> Void)?

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    let textView = SQLTextView()

    textView.delegate = context.coordinator
    textView.onFocus = onFocus

    // Use weak reference to coordinator to prevent crash on deallocation
    textView.onBlur = { [weak coordinator = context.coordinator] newText in
      // Update binding when editor loses focus
      coordinator?.text.wrappedValue = newText
    }
    textView.isRichText = false
    textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    textView.textColor = NSColor(Color.foreground)
    textView.backgroundColor = NSColor.clear
    textView.drawsBackground = false
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.allowsUndo = true

    // Enable continuous undo grouping for better undo/redo behavior
    textView.isContinuousSpellCheckingEnabled = false
    if let undoManager = textView.undoManager {
      undoManager.groupsByEvent = true
    }

    textView.textContainerInset = NSSize(width: 4, height: 4)
    textView.textContainer?.lineFragmentPadding = 0

    // Configure text container to expand vertically
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.heightTracksTextView = false
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]

    scrollView.documentView = textView
    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalScroller = false
    scrollView.drawsBackground = false

    // Set initial text with highlighting
    context.coordinator.applyHighlighting(to: textView, text: text)

    // Update height after setting text
    DispatchQueue.main.async {
      context.coordinator.updateHeight(textView: textView)
    }

    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? SQLTextView else { return }

    // Update callbacks
    textView.onFocus = onFocus

    // Use weak reference to coordinator to prevent crash on deallocation
    textView.onBlur = { [weak coordinator = context.coordinator] newText in
      // Update binding when editor loses focus
      coordinator?.text.wrappedValue = newText
    }

    // Only update text from external source if different
    // Don't update if textView is first responder (user is typing)
    if textView.string != text && textView.window?.firstResponder != textView {
      // Apply syntax highlighting when updating from external source
      context.coordinator.applyHighlighting(to: textView, text: text)

      DispatchQueue.main.async {
        context.coordinator.updateHeight(textView: textView)
      }
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text, height: $height)
  }

  class Coordinator: NSObject, NSTextViewDelegate {
    var text: Binding<String>
    var height: Binding<CGFloat>

    init(text: Binding<String>, height: Binding<CGFloat>) {
      self.text = text
      self.height = height
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }

      // Safety check: ensure textView is still valid and attached to a window
      guard textView.window != nil else { return }

      // Apply syntax highlighting without affecting undo stack
      applyHighlightingWithoutUndo(to: textView, text: textView.string)

      // Update height to fit content
      updateHeight(textView: textView)

      // DO NOT update binding here - it causes undo/redo lag!
      // The binding will be updated when editor loses focus (see resignFirstResponder)
    }

    func applyHighlighting(to textView: NSTextView, text: String) {
      let attributed = SQLSyntaxHighlighter.highlight(text)

      textView.textStorage?.beginEditing()
      textView.textStorage?.setAttributedString(attributed)
      textView.textStorage?.endEditing()
    }

    /// Apply syntax highlighting without creating undo operations
    /// This prevents undo/redo lag when typing
    func applyHighlightingWithoutUndo(to textView: NSTextView, text: String) {
      guard let textStorage = textView.textStorage else { return }

      let attributed = SQLSyntaxHighlighter.highlight(text)

      // Only apply if the text content matches (same length)
      guard textStorage.length == attributed.length else { return }

      let fullRange = NSRange(location: 0, length: textStorage.length)

      // Use shouldChangeText to control undo behavior
      // By wrapping in beginEditing/endEditing without shouldChangeText,
      // we can modify attributes without registering undo
      textStorage.beginEditing()

      // Remove all attributes first
      textStorage.setAttributes([:], range: fullRange)

      // Apply new attributes from syntax highlighting
      attributed.enumerateAttributes(
        in: NSRange(location: 0, length: attributed.length), options: []
      ) { attrs, range, _ in
        textStorage.addAttributes(attrs, range: range)
      }

      textStorage.endEditing()
    }

    func updateHeight(textView: NSTextView) {
      guard let textContainer = textView.textContainer,
        let layoutManager = textView.layoutManager
      else { return }

      // Force layout
      layoutManager.ensureLayout(for: textContainer)

      // Calculate the required height
      let usedRect = layoutManager.usedRect(for: textContainer)
      let insets = textView.textContainerInset
      let requiredHeight = usedRect.height + insets.height * 2

      // Set minimum height
      let minHeight: CGFloat = 40
      let newHeight = max(requiredHeight, minHeight)

      // Update SwiftUI binding to trigger view update
      if abs(height.wrappedValue - newHeight) > 1 {
        height.wrappedValue = newHeight
      }

      // Update frame
      var frame = textView.frame
      frame.size.height = newHeight
      textView.frame = frame
    }
  }
}

// MARK: - Floating Panel Button Component

/// Reusable button component for floating panels (top-right and bottom action panels)
struct FloatingPanelButton: View {
  let icon: String
  let helpText: String
  var useSymbolEffect: Bool = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: 12))
        .if(useSymbolEffect) { view in
          view.contentTransition(.symbolEffect(.replace))
        }
    }
    .buttonStyle(FloatingPanelButtonStyle())
    .help(helpText)
  }
}

#Preview("Empty Cells") {
  ScrollView {
    VStack(spacing: 0) {
      CellView(
        viewModel: NotebookViewModel(),
        cell: .constant(NotebookCell(cellType: .sql, content: "")),
        isSelected: false,
        onRun: {}
      )
    }
    .padding()
  }
  .frame(width: 700)
  .frame(maxHeight: .infinity)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}

#Preview("Long Results") {
  @Previewable @State var cellWithResult = {
    let mockResult = CellResult(
      columns: [
        ColumnInfo(name: "id", type: "INTEGER"),
        ColumnInfo(name: "name", type: "VARCHAR"),
        ColumnInfo(name: "email", type: "VARCHAR"),
        ColumnInfo(name: "description", type: "TEXT"),
        ColumnInfo(name: "age", type: "INTEGER"),
        ColumnInfo(name: "active", type: "BOOLEAN"),
        ColumnInfo(name: "metadata", type: "JSONB"),
      ],
      rows: [
        [
          .int(1), .string("Alice Johnson"), .string("alice@example.com"),
          .string(
            "Senior Software Engineer with expertise in iOS development, SwiftUI, and system architecture. Passionate about creating elegant user interfaces and scalable solutions."
          ), .int(28), .bool(true), .json("{\"role\": \"admin\", \"dept\": \"IT\"}"),
        ],
        [
          .int(2), .string("Bob Williams"), .string("bob@example.com"),
          .string(
            "Sales Manager responsible for the entire West Coast region, managing a team of 15 sales representatives and achieving consistent quarterly growth."
          ), .int(35), .bool(true), .json("{\"role\": \"user\", \"dept\": \"Sales\"}"),
        ],
        [
          .int(3), .string("Charlie Brown"), .string("charlie@example.com"),
          .string(
            "Product Designer specializing in user experience research and interface design. Led design initiatives for multiple successful product launches."
          ), .int(42), .bool(false), .null,
        ],
        [
          .int(4), .string("Diana Prince"), .string("diana@example.com"),
          .string(
            "Engineering Manager overseeing backend infrastructure team. Expert in distributed systems, microservices architecture, and cloud technologies."
          ), .int(31), .bool(true), .json("{\"role\": \"manager\"}"),
        ],
        [
          .int(5), .string("Eve Anderson"), .string("eve@example.com"),
          .string(
            "Data Scientist with focus on machine learning and predictive analytics. Published researcher in AI and natural language processing."
          ), .int(29), .bool(false), .null,
        ],
        [
          .int(6), .string("Frank Martinez"), .string("frank@example.com"),
          .string(
            "DevOps Engineer maintaining CI/CD pipelines and cloud infrastructure. Certified in AWS, Azure, and Kubernetes administration."
          ), .int(33), .bool(true), .json("{\"role\": \"user\", \"dept\": \"IT\"}"),
        ],
        [
          .int(7), .string("Grace Lee"), .string("grace@example.com"),
          .string(
            "Marketing Director developing comprehensive marketing strategies across digital and traditional channels with proven ROI improvement."
          ), .int(38), .bool(true), .json("{\"role\": \"manager\", \"dept\": \"Marketing\"}"),
        ],
        [
          .int(8), .string("Henry Taylor"), .string("henry@example.com"),
          .string(
            "Quality Assurance Lead ensuring product quality through automated testing frameworks and comprehensive test coverage strategies."
          ), .int(30), .bool(true), .json("{\"role\": \"user\", \"dept\": \"QA\"}"),
        ],
        [
          .int(9), .string("Iris Chen"), .string("iris@example.com"),
          .string(
            "Full-stack Developer building scalable web applications using modern frameworks and best practices in software engineering."
          ), .int(27), .bool(true), .json("{\"role\": \"user\", \"dept\": \"IT\"}"),
        ],
        [
          .int(10), .string("Jack Wilson"), .string("jack@example.com"),
          .string(
            "Security Analyst responsible for identifying vulnerabilities, implementing security protocols, and ensuring compliance with industry standards."
          ), .int(36), .bool(false), .json("{\"role\": \"user\", \"dept\": \"Security\"}"),
        ],
        [
          .int(11), .string("Kate Brown"), .string("kate@example.com"),
          .string(
            "Technical Writer creating comprehensive documentation, API references, and user guides for complex software systems and platforms."
          ), .int(32), .bool(true), .json("{\"role\": \"user\", \"dept\": \"Documentation\"}"),
        ],
        [
          .int(12), .string("Liam Davis"), .string("liam@example.com"),
          .string(
            "Mobile Developer specializing in cross-platform development with React Native and Flutter for iOS and Android applications."
          ), .int(28), .bool(true), .json("{\"role\": \"user\", \"dept\": \"Mobile\"}"),
        ],
        [
          .int(13), .string("Maya Patel"), .string("maya@example.com"),
          .string(
            "Business Analyst bridging technical and business stakeholders, defining requirements, and ensuring project alignment with business objectives."
          ), .int(34), .bool(true), .json("{\"role\": \"analyst\", \"dept\": \"Business\"}"),
        ],
        [
          .int(14), .string("Noah Garcia"), .string("noah@example.com"),
          .string(
            "System Administrator managing server infrastructure, network security, and ensuring high availability of critical business systems."
          ), .int(40), .bool(false), .null,
        ],
        [
          .int(15), .string("Olivia Smith"), .string("olivia@example.com"),
          .string(
            "Project Manager coordinating cross-functional teams, managing timelines and budgets, and delivering complex projects on schedule."
          ), .int(37), .bool(true), .json("{\"role\": \"manager\", \"dept\": \"PMO\"}"),
        ],
        [
          .int(16), .string("Paul Johnson"), .string("paul@example.com"),
          .string(
            "Database Administrator optimizing database performance, managing backups, and ensuring data integrity across multiple systems."
          ), .int(39), .bool(true), .json("{\"role\": \"user\", \"dept\": \"IT\"}"),
        ],
        [
          .int(17), .string("Quinn Roberts"), .string("quinn@example.com"),
          .string(
            "UX Researcher conducting user studies, analyzing behavior patterns, and providing insights to improve product usability and satisfaction."
          ), .int(31), .bool(true), .json("{\"role\": \"researcher\", \"dept\": \"Design\"}"),
        ],
        [
          .int(18), .string("Rachel Green"), .string("rachel@example.com"),
          .string(
            "Content Strategist developing content plans, managing editorial calendars, and ensuring consistent brand voice across all platforms."
          ), .int(33), .bool(false), .json("{\"role\": \"user\", \"dept\": \"Marketing\"}"),
        ],
      ],
      executionTime: 0.087,
      rowCount: 18,
      timestamp: Date()
    )

    var cell = NotebookCell(
      cellType: .sql,
      content:
        "SELECT id, name, email, description, age, active, metadata\nFROM users\nWHERE active = true\nORDER BY id;"
    )
    cell.result = mockResult
    cell.executionCount = 3
    return cell
  }()

  ScrollView {
    VStack(spacing: 0) {
      CellView(
        viewModel: NotebookViewModel(),
        cell: $cellWithResult,
        isSelected: true,
        onRun: {}
      )
    }
    .padding()
  }
  .frame(width: 800, height: 700)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}

#Preview("Short Results") {
  @Previewable @State var cellWithResult = {
    let mockResult = CellResult(
      columns: [
        ColumnInfo(name: "id", type: "INTEGER"),
        ColumnInfo(name: "name", type: "VARCHAR"),
        ColumnInfo(name: "status", type: "VARCHAR"),
      ],
      rows: [
        [.int(1), .string("Alice"), .string("Active")],
        [.int(2), .string("Bob"), .string("Inactive")],
        [.int(3), .string("Charlie"), .string("Active")],
        [.int(4), .string("Diana"), .string("Active")],
      ],
      executionTime: 0.012,
      rowCount: 4,
      timestamp: Date()
    )

    var cell = NotebookCell(
      cellType: .sql,
      content: "SELECT id, name, status\nFROM users\nLIMIT 4;"
    )
    cell.result = mockResult
    cell.executionCount = 1
    return cell
  }()

  ScrollView {
    VStack(spacing: 0) {
      CellView(
        viewModel: NotebookViewModel(),
        cell: $cellWithResult,
        isSelected: true,
        onRun: {}
      )
    }
    .padding()
  }
  .frame(width: 600, height: 400)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}

#Preview("Error State") {
  @Previewable @State var cellWithError = {
    let errorResult = CellResult(
      columns: [],
      rows: [],
      executionTime: 0.003,
      rowCount: 0,
      timestamp: Date(),
      error: "ERROR: column \"invalid_column\" does not exist\nLINE 1: SELECT invalid_column FROM users;\n               ^"
    )

    var cell = NotebookCell(
      cellType: .sql,
      content: "SELECT invalid_column FROM users;"
    )
    cell.result = errorResult
    cell.executionCount = 5
    return cell
  }()

  ScrollView {
    VStack(spacing: 0) {
      CellView(
        viewModel: NotebookViewModel(),
        cell: $cellWithError,
        isSelected: false,
        onRun: {}
      )
    }
    .padding()
  }
  .frame(width: 600)
  .frame(maxHeight: .infinity)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}
