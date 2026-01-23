//
//  CellResultViews.swift
//  SQLNotebook
//
//  Result display components for CellView (error, success, table area, metadata).
//

import SwiftUI

// MARK: - Result Area Container

struct ResultAreaView: View {
  let result: CellResult
  let viewModel: NotebookViewModel
  let cellId: UUID
  @State private var isQueryCopied: Bool = false

  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      // Fake sidebar to align with cell sidebar
      Color.clear
        .frame(width: ComponentSize.cellSidebarWidth)

      VStack(alignment: .leading, spacing: Spacing.sm) {
        // Query footer (shows source query with click-to-copy) - always shown first
        ResultQueryFooterView(result: result, isQueryCopied: $isQueryCopied)

        if let error = result.error {
          // Error display with search highlighting
          ErrorResultView(
            error: error,
            searchQuery: viewModel.searchState.query,
            isCaseSensitive: viewModel.searchState.isCaseSensitive,
            cellId: cellId
          )
        } else if let affectedRows = result.affectedRows, affectedRows > 0, result.rows.isEmpty {
          // Success message for UPDATE/DELETE/INSERT (only when no result table)
          SuccessResultView(affectedRows: affectedRows, executionTime: result.executionTime)
        } else {
          // Result table
          ResultTableView(result: result, viewModel: viewModel, cellId: cellId)

          // Result metadata
          ResultMetadataView(result: result)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 0)
      .padding(.bottom, 0)
      .padding(.trailing, Spacing.md)
    }
    .padding(.bottom, Spacing.md)
  }
}

// MARK: - Success Result View

struct SuccessResultView: View {
  let affectedRows: Int
  let executionTime: TimeInterval

  var body: some View {
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

        Text("Execution time: \(CellResultViews.formatExecutionTime(executionTime))")
          .font(.mono)
          .foregroundColor(.foregroundSubtle)
      }
    }
    .padding(Spacing.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.green.opacity(0.1))
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
  }
}

// MARK: - Error Result View

struct ErrorResultView: View {
  let error: String
  let searchQuery: String
  let isCaseSensitive: Bool
  let cellId: UUID
  @State private var currentMatchRange: Range<String.Index>?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: Spacing.sm) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundColor(.destructive)

        Text("Error")
          .font(.system(size: 13, weight: .semibold))
          .foregroundColor(.destructive)
      }
      .padding(.bottom, Spacing.md)

      // Use SearchHighlightText if there's a search query
      if !searchQuery.isEmpty {
        SearchHighlightText(
          text: error,
          query: searchQuery,
          caseSensitive: isCaseSensitive,
          currentMatchRange: currentMatchRange
        )
        .font(.mono)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        Text(error)
          .font(.mono)
          .foregroundColor(.destructive)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(Spacing.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.destructive.opacity(0.1))
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
    .onReceive(NotificationCenter.default.publisher(for: .highlightSearchMatch)) { notification in
      if let match = notification.userInfo?["match"] as? SearchMatch,
        case .errorMessage = match.matchType,
        match.cellId == cellId
      {
        // This cell has the current match - highlight specific range
        currentMatchRange = match.matchRange
      } else {
        // Clear current match highlight (but keep all yellow highlights from query)
        currentMatchRange = nil
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .clearSearchHighlights)) { _ in
      currentMatchRange = nil
    }
  }
}

// MARK: - Result Metadata View

struct ResultMetadataView: View {
  let result: CellResult

  /// Determine color for affected rows text based on query type
  /// - Green for INSERT/UPDATE queries with affected rows > 0
  /// - Red for DELETE queries with affected rows > 0
  /// - Subtle gray for SELECT, 0 affected rows, or when no query info available
  private func affectedRowsColor(for result: CellResult) -> Color {
    let affectedRows = result.affectedRows ?? 0

    // If no rows affected, use default gray color
    guard affectedRows > 0, let query = result.sourceQuery else {
      return .foregroundSubtle
    }

    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

    if trimmed.hasPrefix("DELETE") {
      return .red
    } else if trimmed.hasPrefix("INSERT") || trimmed.hasPrefix("UPDATE") {
      return .green
    } else {
      return .foregroundSubtle
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Horizontal divider line
      Rectangle()
        .fill(Color.border)
        .frame(height: 1)

      HStack(spacing: Spacing.md) {
        Text("Rows: \(result.rowCount)")

        // Show warning if limited (either auto-limited or user LIMIT exceeded)
        if result.wasLimited || result.userLimitExceeded {
          HStack(spacing: Spacing.xs) {
            Text("(")
              .foregroundColor(.warning)
            Text("limited to \(AppSettings.shared.maxRowLimit) rows")
              .foregroundColor(.warning)
            Text(")")
              .foregroundColor(.warning)
          }.font(.labelText)
        }

        Text("|")
          .foregroundColor(.foregroundSubtle)
        Text("Affected: \(result.affectedRows ?? 0)")
          .foregroundColor(affectedRowsColor(for: result))

        Text("|")
          .foregroundColor(.foregroundSubtle)
        Text("Execution time: \(CellResultViews.formatExecutionTime(result.executionTime))")
        Text("|")
          .foregroundColor(.foregroundSubtle)
        Text(CellResultViews.formatTimestamp(result.timestamp))
      }
      .font(.labelText)
      .foregroundColor(.foregroundSubtle)
      .padding(.top, Spacing.sm)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

// MARK: - Result Query Footer

/// Footer showing the source query with click-to-copy functionality.
struct ResultQueryFooterView: View {
  let result: CellResult
  @Binding var isQueryCopied: Bool
  @State private var showCopyFeedback: CopyFeedbackType? = nil

  enum CopyFeedbackType {
    case tsv
    case json
    case markdown
  }

  var body: some View {
    // Don't show if setting is enabled to hide this section
    if !AppSettings.shared.hideRunWithQuerySection, let sourceQuery = result.sourceQuery {
      VStack(alignment: .leading, spacing: 0) {
        // Horizontal divider line (top)
        Rectangle()
          .fill(Color.border)
          .frame(height: 1)

        HStack(spacing: Spacing.sm) {
          // Clickable area: icon + text + query
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

            Text(sourceQuery)
              .font(.system(size: 11, design: .monospaced))
              .foregroundColor(.foregroundSubtle)
              .lineLimit(1)
              .truncationMode(.tail)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
          .onTapGesture {
            copyQueryToClipboard(query: sourceQuery)
          }
          .cursor(NSCursor.pointingHand)
          .help(isQueryCopied ? "Copied!" : "Click to copy query")

          // Download dropdown button (right-aligned)
          downloadButton(result: result)
        }
        .padding(.vertical, Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)

        // Horizontal divider line (bottom)
        Rectangle()
          .fill(Color.border)
          .frame(height: 1)
      }
    }
  }

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

  /// Download dropdown button
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

  private func handleDownloadCSV(result: CellResult) {
    DataExporter.downloadCSV(result: result, queryIndex: nil)
  }

  private func handleDownloadExcel(result: CellResult) {
    DataExporter.downloadExcel(result: result, queryIndex: nil)
  }

  private func handleDownloadJSON(result: CellResult) {
    DataExporter.downloadJSON(result: result, queryIndex: nil)
  }

  private func handleDownloadMarkdown(result: CellResult) {
    DataExporter.downloadMarkdown(result: result, queryIndex: nil)
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

// MARK: - Helper Functions

enum CellResultViews {
  // Static date formatter (cached for performance)
  private static let timestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .medium
    return formatter
  }()

  static func formatTimestamp(_ date: Date) -> String {
    timestampFormatter.string(from: date)
  }

  /// Format execution time with appropriate unit
  /// - If time >= 1 second: show in seconds with 3 decimal places (e.g., "1.234s")
  /// - If time < 1 second: show in milliseconds with 0 decimal places (e.g., "450ms")
  static func formatExecutionTime(_ seconds: Double) -> String {
    if seconds >= 1.0 {
      return String(format: "%.3fs", seconds)
    } else {
      let milliseconds = seconds * 1000
      return String(format: "%.0fms", milliseconds)
    }
  }
}

// MARK: - Previews

#Preview("Success Result") {
  SuccessResultView(affectedRows: 5, executionTime: 0.123)
    .padding()
    .frame(width: 600)
    .background(Color.appBackground)
    .preferredColorScheme(.dark)
}

#Preview("Error Result") {
  ErrorResultView(
    error:
      "ERROR: column \"invalid_column\" does not exist\nLINE 1: SELECT invalid_column FROM users;\n               ^",
    searchQuery: "",
    isCaseSensitive: false,
    cellId: UUID()
  )
  .padding()
  .frame(width: 600)
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}

#Preview("Result Metadata - Normal") {
  let result = CellResult(
    columns: [],
    rows: [],
    executionTime: 0.087,
    rowCount: 18,
    timestamp: Date()
  )

  return ResultMetadataView(result: result)
    .padding()
    .frame(width: 600)
    .background(Color.appBackground)
    .preferredColorScheme(.dark)
}

#Preview("Result Metadata - Limited") {
  let result = CellResult(
    columns: [],
    rows: [],
    executionTime: 0.087,
    rowCount: 50,
    timestamp: Date(),
    wasLimited: true
  )

  return ResultMetadataView(result: result)
    .padding()
    .frame(width: 600)
    .background(Color.appBackground)
    .preferredColorScheme(.dark)
}
