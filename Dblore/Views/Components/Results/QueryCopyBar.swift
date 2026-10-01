//
//  QueryCopyBar.swift
//  Dblore
//
//  Reusable component for "Run with query (click to copy)" bar.
//  Used in both notebook mode and editor mode.
//

import SwiftUI

/// A reusable component that displays a query with click-to-copy functionality and action buttons.
///
/// Features:
/// - Click anywhere on the bar to copy the query
/// - Shows copy icon that changes to checkmark when copied
/// - Optional View Query button
/// - Optional Download dropdown button
/// - Configurable padding and alignment
///
/// Usage:
/// ```swift
/// QueryCopyBar(
///   query: "SELECT * FROM users",
///   result: cellResult,
///   viewModel: viewModel,
///   cellId: cellId
/// )
/// ```
struct QueryCopyBar: View {
  /// The query text to display and copy
  let query: String

  /// The result containing data for download/copy actions
  let result: CellResult

  /// Optional view model for showing query in sidebar
  var viewModel: NotebookViewModel?

  /// Optional cell ID for sidebar navigation (nil in editor mode)
  var cellId: UUID?

  /// Optional query index for multi-statement downloads (nil for single statement)
  var queryIndex: Int?

  /// Dialect of INSERT export and clipboard copy. Notebook call sites keep PostgreSQL.
  var dialect: SQLDialect = .postgresql

  /// When set, the Grid / Chart slider sits on this bar (notebook cells).
  var displayMode: Binding<ResultDisplayMode>? = nil

  /// Icon-only circle for View Query and Download. Notebook cells pass true.
  var iconOnlyActions: Bool = false

  /// Binding to track copy state (for icon animation)
  @State private var isQueryCopied: Bool = false
  @State private var showCopyFeedback: CopyFeedbackType? = nil
  @State private var exportRequest: ExportRequest? = nil

  /// Query with comments removed for display purposes
  private var displayQuery: String {
    SQLSyntaxHighlighter.removeComments(query)
  }

  /// Layout mode based on available width
  private enum LayoutMode {
    case full  // >= 600pt: Full labels for everything
    case intermediate  // 300-599pt: Icon-only buttons, icon + query (no label)
    case compact  // < 300pt: Hide query section entirely, show full buttons

    static func from(width: CGFloat) -> LayoutMode {
      if width >= 600 {
        return .full
      } else if width >= 300 {
        return .intermediate
      } else {
        return .compact
      }
    }
  }

  var body: some View {
    GeometryReader { geometry in
      let currentWidth = geometry.size.width
      let currentMode = LayoutMode.from(width: currentWidth)

      HStack(spacing: Spacing.sm) {
        // Clickable area: icon + text + query (entire bar is clickable)
        // Hidden completely in compact mode
        if currentMode != .compact {
          HStack(spacing: Spacing.sm) {
            // Icon changes when query is copied (fixed width to prevent text shifting)
            Image(systemName: isQueryCopied ? "checkmark" : "doc.on.doc")
              .font(.system(size: 11))
              .foregroundColor(.foregroundMuted)
              .frame(width: 11, height: 11, alignment: .center)
              .contentTransition(.symbolEffect(.replace))
              .animation(.spring(duration: 0.1), value: isQueryCopied)

            // Hide label in intermediate mode, show in full mode
            if currentMode == .full {
              Text("Run with query (click to copy):")
                .font(.system(size: 11))
                .foregroundColor(.foregroundMuted)
            }

            Text(displayQuery)
              .font(.system(size: 11, design: .monospaced))
              .foregroundColor(.foregroundSubtle)
              .lineLimit(1)
              .truncationMode(.tail)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())  // Make entire HStack tappable
          .onTapGesture {
            copyQueryToClipboard(query: query)
          }
          .cursor(NSCursor.pointingHand)
          .help(isQueryCopied ? "Copied!" : "Click to copy query")
        }

        if let displayMode, ChartSpec.suggested(for: ChartQueryResult.make(result)) != nil {
          ResultDisplayPicker(mode: displayMode)
        }

        // View Query button (left of Download button)
        viewQueryButton(query: query, mode: currentMode)

        // Download dropdown button (right-aligned)
        downloadButton(result: result, mode: currentMode)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      .sheet(item: $exportRequest) { request in
        ResultExportSheet(
          result: result,
          format: request.format,
          onExport: { options in
            let exported = result
            let index = queryIndex
            let exportDialect = dialect
            exportRequest = nil
            DispatchQueue.main.async {
              DataExporter.download(
                result: exported, options: options, queryIndex: index, dialect: exportDialect)
            }
          },
          onCancel: { exportRequest = nil })
      }
    }
  }

  // MARK: - Actions

  private func copyQueryToClipboard(query: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(query, forType: .string)

    // Show checkmark feedback
    isQueryCopied = true

    // Reset back to copy icon after 1 second
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
      isQueryCopied = false
    }
  }

  // MARK: - View Query Button

  /// Labels stay on the wide and compact editor bar. Notebook cells are icon-only.
  private func showsActionLabel(_ mode: LayoutMode) -> Bool {
    !iconOnlyActions && (mode == .full || mode == .compact)
  }

  @ViewBuilder
  private func actionChrome<Label: View>(
    iconOnly: Bool, @ViewBuilder label: () -> Label
  )
    -> some View
  {
    if iconOnly {
      label()
        .foregroundColor(.foreground)
        .frame(width: ResultDisplayPicker.height, height: ResultDisplayPicker.height)
        .background(Circle().fill(Color.inputBackground))
        .overlay(Circle().strokeBorder(Color.border, lineWidth: 1))
        .contentShape(Circle())
    } else {
      label()
        .foregroundColor(.foreground)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(Capsule().fill(Color.inputBackground))
        .overlay(Capsule().stroke(Color.border, lineWidth: 1))
    }
  }

  @ViewBuilder
  private func viewQueryButton(query: String, mode: LayoutMode) -> some View {
    Button(action: {
      // Show query in right sidebar (without comments)
      let queryWithoutComments = SQLSyntaxHighlighter.removeComments(query)
      viewModel?.showSidebar(content: .executedQuery(query: queryWithoutComments, cellId: cellId))
    }) {
      actionChrome(iconOnly: iconOnlyActions) {
        HStack(spacing: 4) {
          Image(systemName: "eye")
            .font(.system(size: 11))

          // Show label in full mode or compact mode, hide in intermediate mode
          if showsActionLabel(mode) {
            Text("View Query")
              .font(.system(size: 11))
          }
        }
      }
    }
    .buttonStyle(.plain)
    .linkPointer()
    .help("View full query in sidebar")
    .accessibilityLabel("View Query")
    .fixedSize()
  }

  // MARK: - Download Button

  @ViewBuilder
  private func downloadButton(result: CellResult, mode: LayoutMode) -> some View {
    Menu {
      // Download section
      Section("Download result data") {
        Button(action: { exportRequest = ExportRequest(format: .csv) }) {
          HStack {
            Image(systemName: "arrow.down.doc")
            Text("Download as CSV")
          }
        }

        Button(action: { exportRequest = ExportRequest(format: .excel) }) {
          HStack {
            Image(systemName: "arrow.down.doc")
            Text("Download as Excel")
          }
        }

        Button(action: { exportRequest = ExportRequest(format: .json) }) {
          HStack {
            Image(systemName: "arrow.down.doc")
            Text("Download as JSON")
          }
        }

        Button(action: { exportRequest = ExportRequest(format: .markdown) }) {
          HStack {
            Image(systemName: "arrow.down.doc")
            Text("Download as Markdown")
          }
        }

        Button(action: { exportRequest = ExportRequest(format: .pdf) }) {
          HStack {
            Image(systemName: "arrow.down.doc")
            Text("PDF")
          }
        }

        Button(action: { exportRequest = ExportRequest(format: .sqlInsert) }) {
          HStack {
            Image(systemName: "arrow.down.doc")
            Text("SQL INSERT")
          }
        }
      }

      Divider()

      // Copy section
      Section("Copy result data to clipboard") {
        Button(action: { handleCopyTSV(result: result) }) {
          HStack {
            Image(systemName: showCopyFeedback == .tsv ? "checkmark" : "doc.on.clipboard")
            Text("TSV/Excel")
            if showCopyFeedback == .tsv {
              Spacer()
              Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
            }
          }
        }

        Button(action: { handleCopyJSON(result: result) }) {
          HStack {
            Image(systemName: showCopyFeedback == .json ? "checkmark" : "doc.on.clipboard")
            Text("JSON")
            if showCopyFeedback == .json {
              Spacer()
              Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
            }
          }
        }

        Button(action: { handleCopyMarkdown(result: result) }) {
          HStack {
            Image(systemName: showCopyFeedback == .markdown ? "checkmark" : "doc.on.clipboard")
            Text("Markdown")
            if showCopyFeedback == .markdown {
              Spacer()
              Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
            }
          }
        }

        Button(action: { handleCopyInsert(result: result) }) {
          HStack {
            Image(systemName: showCopyFeedback == .insert ? "checkmark" : "doc.on.clipboard")
            Text(CopyFeedbackType.insert.title)
            if showCopyFeedback == .insert {
              Spacer()
              Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
            }
          }
        }
      }
    } label: {
      actionChrome(iconOnly: iconOnlyActions) {
        HStack(spacing: 4) {
          Image(systemName: "arrow.down.circle")
            .font(.system(size: 11))

          // Show label in full mode or compact mode, hide in intermediate mode
          if showsActionLabel(mode) {
            Text("Download")
              .font(.system(size: 11))
          }

          // Show chevron only when label is shown
          if showsActionLabel(mode) {
            Image(systemName: "chevron.down")
              .font(.system(size: 8))
          }
        }
      }
    }
    .modifier(QueryBarDownloadMenuChrome(iconOnly: iconOnlyActions))
  }

  // MARK: - Download/Copy Actions

  private struct ExportRequest: Identifiable {
    let id = UUID()
    let format: ExportFormat
  }

  enum CopyFeedbackType {
    case tsv
    case json
    case markdown
    case insert
    case inList

    /// Menu title for this clipboard format. `.inList` is the grid's IN-list copy.
    var title: String {
      switch self {
      case .tsv: "TSV/Excel"
      case .json: "JSON"
      case .markdown: "Markdown"
      case .insert: "INSERT statements"
      case .inList: "IN list"
      }
    }
  }

  private func handleCopyTSV(result: CellResult) {
    DataExporter.copyTSV(result: result)
    showCopyFeedback = .tsv
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
      showCopyFeedback = nil
    }
  }

  private func handleCopyJSON(result: CellResult) {
    DataExporter.copyJSON(result: result)
    showCopyFeedback = .json
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
      showCopyFeedback = nil
    }
  }

  private func handleCopyMarkdown(result: CellResult) {
    DataExporter.copyMarkdown(result: result)
    showCopyFeedback = .markdown
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
      showCopyFeedback = nil
    }
  }

  private func handleCopyInsert(result: CellResult) {
    DataExporter.copyInsert(result: result, table: result.tableName, dialect: dialect)
    showCopyFeedback = .insert
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
      showCopyFeedback = nil
    }
  }
}

/// Keeps the editor Download menu unchanged. Notebook icon-only menus hide the
/// system indicator and lock the control to the Grid / Chart slider height.
private struct QueryBarDownloadMenuChrome: ViewModifier {
  var iconOnly: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    if iconOnly {
      content
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .linkPointer()
        .help("Download or copy result data")
        .accessibilityLabel("Download")
        .fixedSize()
        .frame(width: ResultDisplayPicker.height, height: ResultDisplayPicker.height)
    } else {
      content
        .buttonStyle(.plain)
        .linkPointer()
        .help("Download or copy result data")
        .accessibilityLabel("Download")
        .fixedSize()
    }
  }
}

// MARK: - Previews

#Preview("Query Copy Bar - Responsive") {
  let result = CellResult(
    columns: [],
    rows: [],
    executionTime: 0.045,
    rowCount: 10,
    timestamp: Date(),
    sourceQuery:
      "SELECT id, name, email FROM users WHERE status = 'active' ORDER BY created_at DESC LIMIT 10"
  )

  VStack(spacing: 20) {
    Text("Full Width (>600pt)")
      .font(.headline)

    QueryCopyBar(
      query:
        "SELECT id, name, email FROM users WHERE status = 'active' ORDER BY created_at DESC LIMIT 10",
      result: result,
      viewModel: NotebookViewModel(),
      cellId: UUID()
    )
    .frame(width: 700, height: 24)
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .background(Color.appBackground)
    .overlay(
      Rectangle()
        .fill(Color.foregroundMuted.opacity(0.1))
        .frame(height: 1),
      alignment: .top
    )

    Text("Intermediate Width (300-600pt)")
      .font(.headline)

    QueryCopyBar(
      query:
        "SELECT id, name, email FROM users WHERE status = 'active' ORDER BY created_at DESC LIMIT 10",
      result: result,
      viewModel: NotebookViewModel(),
      cellId: UUID()
    )
    .frame(width: 450, height: 24)
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .background(Color.appBackground)
    .overlay(
      Rectangle()
        .fill(Color.foregroundMuted.opacity(0.1))
        .frame(height: 1),
      alignment: .top
    )

    Text("Compact Width (<300pt)")
      .font(.headline)

    QueryCopyBar(
      query: "SELECT * FROM users",
      result: result,
      viewModel: NotebookViewModel(),
      cellId: nil
    )
    .frame(width: 250, height: 24)
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .background(Color.appBackground)
    .overlay(
      Rectangle()
        .fill(Color.foregroundMuted.opacity(0.1))
        .frame(height: 1),
      alignment: .top
    )
  }
  .frame(width: 800)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}
