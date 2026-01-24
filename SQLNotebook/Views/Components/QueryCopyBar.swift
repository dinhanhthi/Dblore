//
//  QueryCopyBar.swift
//  SQLNotebook
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

  /// Binding to track copy state (for icon animation)
  @State private var isQueryCopied: Bool = false
  @State private var showCopyFeedback: CopyFeedbackType? = nil

  /// Query with comments removed for display purposes
  private var displayQuery: String {
    SQLSyntaxHighlighter.removeComments(query)
  }

  var body: some View {
    HStack(spacing: Spacing.sm) {
      // Clickable area: icon + text + query (entire bar is clickable)
      HStack(spacing: Spacing.sm) {
        // Icon changes when query is copied (fixed width to prevent text shifting)
        Image(systemName: isQueryCopied ? "checkmark" : "doc.on.doc")
          .font(.system(size: 11))
          .foregroundColor(.foregroundMuted)
          .frame(width: 11, height: 11, alignment: .center)
          .contentTransition(.symbolEffect(.replace))
          .animation(.spring(duration: 0.1), value: isQueryCopied)

        Text("Run with query (click to copy):")
          .font(.system(size: 11))
          .foregroundColor(.foregroundMuted)

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

      // View Query button (left of Download button)
      viewQueryButton(query: query)

      // Download dropdown button (right-aligned)
      downloadButton(result: result)
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

  @ViewBuilder
  private func viewQueryButton(query: String) -> some View {
    Button(action: {
      // Show query in right sidebar (without comments)
      let queryWithoutComments = SQLSyntaxHighlighter.removeComments(query)
      viewModel?.rightSidebarContent = .executedQuery(query: queryWithoutComments, cellId: cellId)
      viewModel?.isRightSidebarVisible = true
    }) {
      HStack(spacing: 4) {
        Image(systemName: "eye")
          .font(.system(size: 11))
        Text("View Query")
          .font(.system(size: 11))
      }
      .foregroundColor(.foreground)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xs)
      .background(
        RoundedRectangle(cornerRadius: CornerRadius.md)
          .fill(Color.inputBackground)
      )
      .overlay(
        RoundedRectangle(cornerRadius: CornerRadius.md)
          .stroke(Color.border, lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .help("View full query in sidebar")
    .fixedSize()
  }

  // MARK: - Download Button

  @ViewBuilder
  private func downloadButton(result: CellResult) -> some View {
    Menu {
      // Download section
      Section("Download") {
        Button(action: { handleDownloadCSV(result: result) }) {
          HStack {
            Image(systemName: "arrow.down.doc")
            Text("Download as CSV")
          }
        }

        Button(action: { handleDownloadExcel(result: result) }) {
          HStack {
            Image(systemName: "arrow.down.doc")
            Text("Download as Excel")
          }
        }

        Button(action: { handleDownloadJSON(result: result) }) {
          HStack {
            Image(systemName: "arrow.down.doc")
            Text("Download as JSON")
          }
        }

        Button(action: { handleDownloadMarkdown(result: result) }) {
          HStack {
            Image(systemName: "arrow.down.doc")
            Text("Download as Markdown")
          }
        }
      }

      Divider()

      // Copy section
      Section("Copy to Clipboard") {
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
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "arrow.down.circle")
          .font(.system(size: 11))
        Text("Download")
          .font(.system(size: 11))
        Image(systemName: "chevron.down")
          .font(.system(size: 8))
      }
      .foregroundColor(.foreground)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xs)
      .background(
        RoundedRectangle(cornerRadius: CornerRadius.md)
          .fill(Color.inputBackground)
      )
      .overlay(
        RoundedRectangle(cornerRadius: CornerRadius.md)
          .stroke(Color.border, lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .help("Download or copy result data")
    .fixedSize()
  }

  // MARK: - Download/Copy Actions

  enum CopyFeedbackType {
    case tsv
    case json
    case markdown
  }

  private func handleDownloadCSV(result: CellResult) {
    DataExporter.downloadCSV(result: result, queryIndex: queryIndex)
  }

  private func handleDownloadExcel(result: CellResult) {
    DataExporter.downloadExcel(result: result, queryIndex: queryIndex)
  }

  private func handleDownloadJSON(result: CellResult) {
    DataExporter.downloadJSON(result: result, queryIndex: queryIndex)
  }

  private func handleDownloadMarkdown(result: CellResult) {
    DataExporter.downloadMarkdown(result: result, queryIndex: queryIndex)
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
}

// MARK: - Previews

#Preview("Query Copy Bar") {
  let result = CellResult(
    columns: [],
    rows: [],
    executionTime: 0.045,
    rowCount: 10,
    timestamp: Date(),
    sourceQuery: "SELECT id, name, email FROM users WHERE status = 'active' ORDER BY created_at DESC LIMIT 10"
  )

  return VStack(spacing: 20) {
    Text("Normal Query Bar")
      .font(.headline)

    QueryCopyBar(
      query: "SELECT id, name, email FROM users WHERE status = 'active' ORDER BY created_at DESC LIMIT 10",
      result: result,
      viewModel: NotebookViewModel(),
      cellId: UUID()
    )
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .background(Color.appBackground)
    .overlay(
      Rectangle()
        .fill(Color.foregroundMuted.opacity(0.1))
        .frame(height: 1),
      alignment: .top
    )

    Text("Short Query")
      .font(.headline)

    QueryCopyBar(
      query: "SELECT * FROM users",
      result: result,
      viewModel: NotebookViewModel(),
      cellId: nil
    )
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
