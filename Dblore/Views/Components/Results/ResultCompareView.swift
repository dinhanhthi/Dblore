//
//  ResultCompareView.swift
//  Dblore
//
//  Pin / Compare controls and the pinned-vs-current compare view of a result.
//

import AppKit
import SwiftUI

// MARK: - Summary text

/// Summary line of a diff, current relative to the pin, e.g.
/// "Current vs pinned: +3 rows, −1 row, 2 changed, 1 column added"
enum ResultCompareSummary {
  private static let prefix = "Current vs pinned: "

  static func text(_ diff: ResultDiff) -> String {
    var parts: [String] = []
    if !diff.addedRows.isEmpty {
      parts.append("+" + count(diff.addedRows.count, "row"))
    }
    if !diff.removedRows.isEmpty {
      parts.append("\u{2212}" + count(diff.removedRows.count, "row"))
    }
    if !diff.changedRows.isEmpty {
      parts.append("\(diff.changedRows.count) changed")
    }
    if !diff.addedColumns.isEmpty {
      parts.append(count(diff.addedColumns.count, "column") + " added")
    }
    if !diff.removedColumns.isEmpty {
      parts.append(count(diff.removedColumns.count, "column") + " removed")
    }
    return prefix + (parts.isEmpty ? "no changes" : parts.joined(separator: ", "))
  }

  static func text(_ comparison: CellComparison) -> String {
    switch comparison {
    case .rows(let diff): text(diff)
    case .plan(let diff): prefix + (diff.hasChanges ? "plan changed" : "no changes")
    }
  }

  static func truncationNote(rowCap: Int = ResultComparison.defaultRowCap) -> String {
    "Compared first \(rowCap.formatted()) rows"
  }

  private static func count(_ value: Int, _ noun: String) -> String {
    "\(value) \(noun)\(value == 1 ? "" : "s")"
  }
}

// MARK: - Pin / Compare controls

/// Pin / Unpin button and the Compare toggle of a result toolbar
struct ResultPinControls: View {
  let isPinned: Bool
  /// False when there is no successful result to pin
  let canPin: Bool
  let isComparing: Bool
  /// Appended to the pin tooltip (where the pin is kept)
  var pinNote: String? = nil
  let onPin: () -> Void
  let onUnpin: () -> Void
  let onToggleCompare: () -> Void

  private var pinHelp: String {
    if isPinned { return "Unpin result" }
    let help = "Pin result to compare later"
    return pinNote.map { "\(help). \($0)" } ?? help
  }

  var body: some View {
    HStack(spacing: Spacing.xs) {
      Button(action: isPinned ? onUnpin : onPin) {
        Image(systemName: isPinned ? "pin.fill" : "pin")
      }
      .buttonStyle(GhostButtonStyle(isActive: isPinned, iconOnly: true))
      .controlSize(.small)
      .disabled(!isPinned && !canPin)
      .help(pinHelp)
      .accessibilityLabel(isPinned ? "Unpin result" : "Pin result")

      // Also shown while comparing without a pin, so compare can be turned off
      if isPinned || isComparing {
        Button(action: onToggleCompare) {
          Image(systemName: "arrow.left.arrow.right")
        }
        .buttonStyle(GhostButtonStyle(isActive: isComparing, iconOnly: true))
        .controlSize(.small)
        .help(isComparing ? "Stop comparing" : "Compare with the pinned result")
        .accessibilityLabel("Compare")
      }
    }
    .fixedSize()
  }
}

// MARK: - Compare panel

/// Summary line plus the row or plan compare view. Shows a hint when nothing is pinned.
struct ResultComparePanel: View {
  let pin: PinnedResult?
  let current: CellResult
  let comparison: CellComparison?
  /// Where the pin is kept, shown after the pinned time
  var pinNote: String? = nil
  /// Lexical rules for removing comments from the shown queries
  var dialect: SQLDialect = .postgresql
  /// Editor panel fills its parent; a notebook cell fits the rows shown
  var fillsAvailableHeight = false

  /// Notebook height while comparing, so the cell does not collapse to the summary line
  private static let pendingHeight: CGFloat = 60

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      if let pin {
        summaryLine(pin: pin)
        content(pin: pin)
          .frame(maxWidth: .infinity, maxHeight: fillsAvailableHeight ? .infinity : nil)
      } else {
        Label("Pin a result first", systemImage: "pin")
          .font(.small)
          .foregroundStyle(Color.foregroundMuted)
      }
    }
    .frame(
      maxWidth: .infinity, maxHeight: fillsAvailableHeight ? .infinity : nil,
      alignment: .topLeading)
  }

  private func summaryLine(pin: PinnedResult) -> some View {
    HStack(spacing: Spacing.sm) {
      if let comparison {
        Text(ResultCompareSummary.text(comparison))
          .foregroundStyle(Color.foreground)
        if case .rows(let diff) = comparison, diff.truncated {
          Text(ResultCompareSummary.truncationNote())
            .foregroundStyle(Color.warning)
        }
        // Row compares show the pinned time in the Pinned pane title
        if case .plan = comparison {
          Text(ResultComparePane.pinnedTitle(pin.pinnedAt))
            .foregroundStyle(Color.foregroundSubtle)
            .help(pinNote ?? "")
        }
      } else {
        ProgressView()
          .controlSize(.mini)
        Text("Comparing\u{2026}")
          .foregroundStyle(Color.foregroundMuted)
      }
    }
    .font(.small)
    .lineLimit(1)
  }

  @ViewBuilder
  private func content(pin: PinnedResult) -> some View {
    switch comparison {
    case .rows(let diff):
      ResultCompareView(
        baseline: pin.result, current: current, diff: diff,
        pinnedAt: pin.pinnedAt, pinNote: pinNote,
        baselineQuery: pin.sourceQuery.map(dialectTokenizer.strippingComments),
        currentQuery: current.sourceQuery.map(dialectTokenizer.strippingComments),
        fillsAvailableHeight: fillsAvailableHeight)
    case .plan(let diff):
      ExplainPlanCompareView(diff: diff)
        .frame(height: fillsAvailableHeight ? nil : notebookPlanHeight)
    case nil:
      Color.clear
        .frame(height: fillsAvailableHeight ? nil : Self.pendingHeight)
    }
  }

  private var dialectTokenizer: SQLTokenizer {
    SQLTokenizer(dialect: dialect)
  }
}

// MARK: - Row compare view

/// Pinned and current rows side by side, each under the query that produced it. Only
/// differing rows are listed (removed and changed rows on the pinned side, added and changed
/// rows on the current side), unless the column set changed: then every row is listed so the
/// added or removed columns show (see `ResultDiff.paneRows`).
struct ResultCompareView: View {
  let baseline: CellResult
  let current: CellResult
  let diff: ResultDiff
  let pinnedAt: Date
  var pinNote: String? = nil
  /// Comment-free SQL of each side; nil when not recorded
  let baselineQuery: String?
  let currentQuery: String?
  var fillsAvailableHeight = false

  /// Rows drawn per side; the summary line still counts every difference
  static let displayRowCap = 200

  private var columnsChanged: Bool {
    !diff.addedColumns.isEmpty || !diff.removedColumns.isEmpty
  }

  private func emptyText(_ side: ResultDiff.Side) -> String {
    if !diff.hasChanges { return "No changes" }
    if columnsChanged { return "No rows" }
    return side == .current ? "No added or changed rows" : "No removed or changed rows"
  }

  var body: some View {
    HStack(alignment: .top, spacing: Spacing.sm) {
      ResultComparePane(
        title: ResultComparePane.pinnedTitle(pinnedAt),
        note: pinNote,
        query: baselineQuery,
        result: baseline,
        columns: diff.sharedColumns + diff.removedColumns,
        sideColumns: Set(diff.removedColumns),
        sideTint: .destructive,
        sideMarker: "\u{2212}",
        rows: diff.paneRows(side: .baseline, rowCount: baseline.rows.count),
        emptyText: emptyText(.baseline),
        fillsAvailableHeight: fillsAvailableHeight
      )
      ResultComparePane(
        title: "Current",
        query: currentQuery,
        result: current,
        columns: diff.sharedColumns + diff.addedColumns,
        sideColumns: Set(diff.addedColumns),
        sideTint: .success,
        sideMarker: "+",
        rows: diff.paneRows(side: .current, rowCount: current.rows.count),
        emptyText: emptyText(.current),
        fillsAvailableHeight: fillsAvailableHeight
      )
    }
    // Notebook: both panes take the taller pane's height
    .fixedSize(horizontal: false, vertical: !fillsAvailableHeight)
  }
}

/// One side of the row compare view
private struct ResultComparePane: View {
  let title: String
  /// Small secondary text after the title (where the pin is kept)
  var note: String? = nil
  /// Comment-free SQL of this side; nil when not recorded
  let query: String?
  let result: CellResult
  let columns: [String]
  /// Columns only on this side
  let sideColumns: Set<String>
  let sideTint: Color
  let sideMarker: String
  let rows: [ResultCompareRow]
  let emptyText: String
  let fillsAvailableHeight: Bool

  private static let columnWidth: CGFloat = 140
  private static let markerWidth: CGFloat = 18
  private static let rowHeight: CGFloat = 22
  /// Lines of SQL shown before truncation (the full query is in the tooltip)
  private static let queryLineLimit = 4
  /// Notebook body height when there are no rows to list
  private static let emptyHeight: CGFloat = 44

  static func pinnedTitle(_ pinnedAt: Date) -> String {
    "Pinned \u{00B7} \(CellResultViews.formatTimestamp(pinnedAt))"
  }

  private var shownRows: ArraySlice<ResultCompareRow> {
    rows.prefix(ResultCompareView.displayRowCap)
  }

  /// Notebook scroll height: header plus shown rows, at most as many rows as the result grid
  private var scrollHeight: CGFloat {
    let visibleRows = min(shownRows.count, ResultGridView.maxVisibleRows)
    let scroller =
      NSScroller.preferredScrollerStyle == .legacy
      ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    return CGFloat(visibleRows + 1) * Self.rowHeight + scroller
  }

  var body: some View {
    let columnIndex = Self.firstIndexByName(result.columns.map(\.name))
    VStack(alignment: .leading, spacing: Spacing.xs) {
      titleRow
      queryBox
      if rows.isEmpty {
        Text(emptyText)
          .font(.small)
          .foregroundStyle(Color.foregroundSubtle)
          .frame(maxWidth: .infinity, maxHeight: fillsAvailableHeight ? .infinity : nil)
          .frame(height: fillsAvailableHeight ? nil : Self.emptyHeight)
      } else {
        ScrollView([.horizontal, .vertical]) {
          LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
            Section {
              ForEach(shownRows, id: \.index) { row in
                rowView(row, columnIndex: columnIndex)
              }
            } header: {
              header
            }
          }
        }
        .frame(height: fillsAvailableHeight ? nil : scrollHeight)
        if rows.count > shownRows.count {
          Text("Showing first \(shownRows.count) of \(rows.count) rows")
            .font(.smallest)
            .foregroundStyle(Color.foregroundSubtle)
        }
      }
    }
    .padding(Spacing.sm)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color.cellBackground)
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
  }

  private var titleRow: some View {
    HStack(spacing: Spacing.sm) {
      Text(title)
        .font(.small)
        .foregroundStyle(Color.foregroundMuted)
        .layoutPriority(1)
      if let note {
        Text(note)
          .font(.smallest)
          .foregroundStyle(Color.foregroundSubtle)
          .truncationMode(.tail)
          .help(note)
      }
    }
    .lineLimit(1)
  }

  /// The query that produced this side, on a subtly different background
  private var queryBox: some View {
    Group {
      if let query, !query.isEmpty {
        Text(query)
          .font(.monoSmall)
          .foregroundStyle(Color.foreground)
          .lineLimit(Self.queryLineLimit)
          .truncationMode(.tail)
          .textSelection(.enabled)
          .help(query)
      } else {
        Text("Query not recorded")
          .font(.small)
          .foregroundStyle(Color.foregroundSubtle)
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.xs)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.inputBackground)
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm))
    .accessibilityLabel(query.map { "Query: \($0)" } ?? "Query not recorded")
  }

  private var header: some View {
    HStack(spacing: 0) {
      Color.clear.frame(width: Self.markerWidth)
      ForEach(Array(columns.enumerated()), id: \.offset) { _, name in
        Text(name)
          .font(.small.weight(.semibold))
          .foregroundStyle(sideColumns.contains(name) ? sideTint : Color.foreground)
          .lineLimit(1)
          .truncationMode(.tail)
          .padding(.horizontal, Spacing.xs)
          .frame(width: Self.columnWidth, height: Self.rowHeight, alignment: .leading)
          .background(sideColumns.contains(name) ? sideTint.opacity(0.15) : Color.clear)
      }
    }
    .background(Color.tableHeaderBackground)
  }

  private func rowView(_ row: ResultCompareRow, columnIndex: [String: Int]) -> some View {
    let values = result.rows.indices.contains(row.index) ? result.rows[row.index] : []
    let changedColumns: Set<String> =
      if case .changed(let columns) = row.kind { columns } else { [] }
    return HStack(spacing: 0) {
      marker(row.kind)
        .font(.monoSmall)
        .frame(width: Self.markerWidth, height: Self.rowHeight)
      ForEach(Array(columns.enumerated()), id: \.offset) { _, name in
        let value = columnIndex[name].flatMap { values.indices.contains($0) ? values[$0] : nil }
        Text(value.map(Self.text) ?? "")
          .font(.monoSmall)
          .foregroundStyle(value == .null ? Color.foregroundSubtle : Color.foreground)
          .lineLimit(1)
          .truncationMode(.tail)
          .padding(.horizontal, Spacing.xs)
          .frame(width: Self.columnWidth, height: Self.rowHeight, alignment: .leading)
          .background(changedColumns.contains(name) ? Color.warning.opacity(0.25) : Color.clear)
      }
    }
    .background(row.kind == .sideOnly ? sideTint.opacity(0.12) : Color.clear)
  }

  @ViewBuilder
  private func marker(_ kind: ResultCompareRow.Kind) -> some View {
    switch kind {
    case .sideOnly: Text(sideMarker).foregroundStyle(sideTint)
    case .changed: Text("~").foregroundStyle(Color.warning)
    case .unchanged: Color.clear
    }
  }

  /// JSON shows its text (the grid shows a `{...}` preview)
  private static func text(_ value: CellValue) -> String {
    if case .json(let json) = value { return json }
    return value.displayString
  }

  private static func firstIndexByName(_ names: [String]) -> [String: Int] {
    var index: [String: Int] = [:]
    for (position, name) in names.enumerated() where index[name] == nil {
      index[name] = position
    }
    return index
  }
}
