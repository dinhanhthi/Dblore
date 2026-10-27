//
//  QueryCopyBar.swift
//  Dblore
//
//  Reusable component for "Run with query (click to copy)" bar.
//  Used in both notebook mode and editor mode.
//  Copies and the Export sheet of a lazy data-viewer page load its cut cells first
//  (`loadedResult`): the sheet only ever receives the fully loaded result, and a failed or
//  cancelled load copies nothing and opens no sheet.
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
///   cellId: cellId,
///   dialect: viewModel.sqlDialect
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

  /// Connection dialect of INSERT export and clipboard copy.
  let dialect: SQLDialect

  /// The connection's query language. MongoDB results have no SQL INSERT or Parquet download.
  private var queryLanguage: DatabaseCapabilities.QueryLanguage {
    dialect == .mongodb ? .mongosh : .sql
  }

  /// When set, the Grid / Chart slider sits at the trailing end (editor result footer).
  var displayMode: Binding<ResultDisplayMode>? = nil

  /// Icon-only circle for View Query and Download. Notebook cells pass true.
  var iconOnlyActions: Bool = false

  /// Binding to track copy state (for icon animation)
  @State private var isQueryCopied: Bool = false
  @State private var showCopyFeedback: CopyFeedbackType? = nil
  @State private var exportRequest: ExportRequest? = nil
  @ReduceMotion private var reduceMotion

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
              .animation(reduceMotion ? nil : .snappy(duration: 0.15), value: isQueryCopied)
              // Opt out of the app-wide animation kill switch so the symbol swap plays
              .transaction(value: isQueryCopied) { $0.disablesAnimations = false }

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

        // View Query button (left of Download button)
        viewQueryButton(query: query, mode: currentMode)

        // Download dropdown button (right-aligned)
        downloadButton(result: result, mode: currentMode)

        if let displayMode,
          let displayTabs = ResultDisplayMode.pickerTabs(
            chartable: ChartSpec.suggested(for: ChartQueryResult.make(result)) != nil,
            documents: queryLanguage == .mongosh)
        {
          ResultDisplayPicker(mode: displayMode, tabs: displayTabs)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      .sheet(item: $exportRequest) { request in
        ResultExportSheet(
          result: request.result,
          format: request.format,
          queryLanguage: queryLanguage,
          queryIndex: queryIndex,
          onExport: { options in
            let exported = request.result
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
        .background(Circle().fill(Color.controlBackground))
        .overlay(HairlineBorder(shape: Circle()))
        .contentShape(Circle())
    } else {
      label()
        .foregroundColor(.foreground)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(Capsule().fill(Color.controlBackground))
        .overlay(HairlineBorder(shape: Capsule()))
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
        Button(action: { requestExport(.csv) }) {
          HStack {
            Image(systemName: "arrow.down.doc")
            Text("Download as CSV")
          }
        }

        Button(action: { requestExport(.excel) }) {
          HStack {
            Image(systemName: "arrow.down.doc")
            Text("Download as Excel")
          }
        }

        Button(action: { requestExport(.json) }) {
          HStack {
            Image(systemName: "arrow.down.doc")
            Text("Download as JSON")
          }
        }

        Button(action: { requestExport(.markdown) }) {
          HStack {
            Image(systemName: "arrow.down.doc")
            Text("Download as Markdown")
          }
        }

        Button(action: { requestExport(.pdf) }) {
          HStack {
            Image(systemName: "arrow.down.doc")
            Text("PDF")
          }
        }

        if ResultExportSheet.exportFormats(for: queryLanguage).contains(.sqlInsert) {
          Button(action: { requestExport(.sqlInsert) }) {
            HStack {
              Image(systemName: "arrow.down.doc")
              Text("SQL INSERT")
            }
          }
        }

        if ResultExportSheet.exportFormats(for: queryLanguage).contains(.parquet) {
          Button(action: { requestExport(.parquet) }) {
            HStack {
              Image(systemName: "arrow.down.doc")
              Text("Parquet")
            }
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

  /// The Export sheet's format and the result it exports (cut cells already loaded)
  struct ExportRequest: Identifiable {
    let id = UUID()
    let format: ExportFormat
    let result: CellResult
  }

  /// `result` with every cut cell of a lazy data-viewer page loaded (progress and Cancel in
  /// the grid), the same result when it has none; nil when a load failed or was cancelled
  /// (the view model told the user): nothing is copied or exported.
  static func loadedResult(
    _ result: CellResult, viewModel: NotebookViewModel?, action: String
  ) async -> CellResult? {
    guard let viewModel, viewModel.hasUnloadedCells(in: result) else { return result }
    return await viewModel.fullyLoadedResult(result, action: action)
  }

  /// The Export sheet request for `format`, its result fully loaded; nil opens no sheet
  static func exportRequest(
    format: ExportFormat, result: CellResult, viewModel: NotebookViewModel?
  ) async -> ExportRequest? {
    guard let loaded = await loadedResult(result, viewModel: viewModel, action: "Export") else {
      return nil
    }
    return ExportRequest(format: format, result: loaded)
  }

  /// Opens the Export sheet: at once for a result with no cut cell, else once they loaded
  private func requestExport(_ format: ExportFormat) {
    guard let viewModel, viewModel.hasUnloadedCells(in: result) else {
      exportRequest = ExportRequest(format: format, result: result)
      return
    }
    let result = result
    Task {
      guard
        let request = await Self.exportRequest(
          format: format, result: result, viewModel: viewModel)
      else { return }
      exportRequest = request
    }
  }

  /// Runs `copy` on the result (at once, or once its cut cells loaded), then shows `feedback`
  private func handleCopy(_ feedback: CopyFeedbackType, _ copy: @escaping (CellResult) -> Void) {
    let finish = { (copied: CellResult) in
      copy(copied)
      showCopyFeedback = feedback
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        showCopyFeedback = nil
      }
    }
    guard let viewModel, viewModel.hasUnloadedCells(in: result) else {
      finish(result)
      return
    }
    let result = result
    Task {
      guard let loaded = await Self.loadedResult(result, viewModel: viewModel, action: "Copy")
      else { return }
      finish(loaded)
    }
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
    handleCopy(.tsv) { DataExporter.copyTSV(result: $0) }
  }

  private func handleCopyJSON(result: CellResult) {
    handleCopy(.json) { DataExporter.copyJSON(result: $0) }
  }

  private func handleCopyMarkdown(result: CellResult) {
    handleCopy(.markdown) { DataExporter.copyMarkdown(result: $0) }
  }

  private func handleCopyInsert(result: CellResult) {
    let dialect = dialect
    handleCopy(.insert) {
      DataExporter.copyInsert(result: $0, table: $0.tableName, dialect: dialect)
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
      cellId: UUID(),
      dialect: .postgresql
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
      cellId: UUID(),
      dialect: .postgresql
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
      cellId: nil,
      dialect: .postgresql
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
