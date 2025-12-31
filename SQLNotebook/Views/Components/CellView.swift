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
  @State private var isTopRightPanelHovered = false  // For top-right panel hover
  @State private var isCopied = false  // For copy button feedback
  @State private var isDeleteConfirming = false  // For delete confirmation state
  @FocusState private var isEditorFocused: Bool
  @State private var textViewRef: SQLTextView?  // Reference to text view for text insertion

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

      // Top-right floating panel (shown when cell is hovered or selected)
      if isHovered || isSelected || isTopRightPanelHovered {
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
    .onReceive(NotificationCenter.default.publisher(for: .insertTextIntoCell)) { notification in
      // Only insert if this cell is selected
      guard isSelected,
            let userInfo = notification.userInfo,
            let text = userInfo["text"] as? String,
            let textView = textViewRef
      else { return }

      // Insert text at current cursor position
      let selectedRange = textView.selectedRange()
      textView.insertText(text, replacementRange: selectedRange)

      // Focus the editor after inserting text
      isEditorFocused = true
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
            .frame(width: 26, height: 26)
        } else {
          Image(systemName: "play.fill")
            .font(.system(size: 12))
            .foregroundColor(isHovered || isSelected ? .foreground : .foregroundMuted)
            .frame(width: 26, height: 26)
        }
      }
      .buttonStyle(GhostButtonStyle())
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
      if isDeleteConfirming {
        // Confirmation buttons (check and cross)
        FloatingPanelButton(
          icon: "checkmark",
          helpText: "Confirm Delete",
          action: {
            viewModel.deleteCell(id: cell.id)
            isDeleteConfirming = false
          }
        )

        FloatingPanelButton(
          icon: "xmark",
          helpText: "Cancel Delete",
          action: {
            isDeleteConfirming = false
          }
        )
      } else {
        // Normal buttons (delete and copy)
        FloatingPanelButton(
          icon: "trash",
          helpText: "Delete Cell",
          action: {
            isDeleteConfirming = true
          }
        )
      }

      FloatingPanelButton(
        icon: isCopied ? "checkmark" : "doc.on.doc",
        helpText: "Copy Cell Content",
        useSymbolEffect: true,
        action: copyCellContent
      )
    }
    .padding(.top, Spacing.xs)
    .padding(.trailing, Spacing.xs)
    .onHover { hovering in
      // Keep panel visible when hovering over the buttons
      isTopRightPanelHovered = hovering
      // Reset confirmation state when mouse leaves the panel
      if !hovering && isDeleteConfirming {
        isDeleteConfirming = false
      }
    }
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
      onFocus: { viewModel.selectedCellId = cell.id },
      textViewRef: $textViewRef
    )
    .focused($isEditorFocused)
    .id(cell.id)  // Force recreate view when cell ID changes to prevent content leakage
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
        } else if let affectedRows = result.affectedRows {
          // Success message for UPDATE/DELETE/INSERT
          successView(affectedRows: affectedRows, executionTime: result.executionTime)
        } else {
          // Result table
          ResultTableView(result: result, viewModel: viewModel, cellId: cell.id)

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

  private func successView(affectedRows: Int, executionTime: TimeInterval) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: Spacing.sm) {
        Image(systemName: "checkmark.circle.fill")
          .foregroundColor(.green)

        Text("Success")
          .font(.system(size: 13, weight: .semibold))
          .foregroundColor(.green)
      }
      .padding(.bottom, Spacing.md)

      HStack(spacing: Spacing.md) {
        Text("\(affectedRows) row\(affectedRows == 1 ? "" : "s") affected")
          .font(.mono)
          .foregroundColor(.foreground)

        Text("|")
          .foregroundColor(.foregroundSubtle)

        Text(String(format: "Execution time: %.3fs", executionTime))
          .font(.mono)
          .foregroundColor(.foregroundSubtle)
      }
    }
    .padding(Spacing.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.green.opacity(0.1))
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
  }

  private func errorView(_ error: String) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: Spacing.sm) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundColor(.destructive)

        Text("Error")
          .font(.system(size: 13, weight: .semibold))
          .foregroundColor(.destructive)
      }
      .padding(.bottom, Spacing.md)

      Text(error)
        .font(.mono)
        .foregroundColor(.destructive)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(Spacing.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.destructive.opacity(0.1))
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
  }

  private func resultMetadata(_ result: CellResult) -> some View {
    HStack(spacing: Spacing.md) {
      Text("Rows: \(result.rowCount)")

      // Show warning if limited (either auto-limited or user LIMIT exceeded)
      if result.wasLimited || result.userLimitExceeded {
        HStack(spacing: Spacing.xs) {
          Text("(")
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundColor(.foregroundSubtle)
          Text("limited to \(AppSettings.shared.maxRowLimit) rows")
            .foregroundColor(.foregroundSubtle)
          Text(")")
        }.font(.caption2)
      }

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

// MARK: - Previews

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
  .frame(width: 700, height: 150)
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
      timestamp: Date(),
      wasLimited: true
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
      error:
        "ERROR: column \"invalid_column\" does not exist\nLINE 1: SELECT invalid_column FROM users;\n               ^"
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
