//
//  HistoryRow.swift
//  Dblore
//
//  One recorded statement in the history sidebar
//

import SwiftUI

struct HistoryRow: View {
  let entry: QueryHistoryEntry
  /// Clock for the footer. The list passes one shared minute tick.
  var now: Date = Date()
  /// Odd rows, matching the result grid.
  var isAlternate = false
  let onInsert: () -> Void
  let onViewDetail: () -> Void
  let onCopy: () -> Void
  let onDelete: () -> Void

  @State private var isHovering = false
  @State private var isHoveringInsert = false
  @State private var isHoveringDetail = false

  private var showsActions: Bool { isHovering || isHoveringInsert || isHoveringDetail }

  /// Transaction summaries are labels. Insert and Copy would put non-SQL where it can be run.
  private var canReplay: Bool { !QueryHistoryEntry.isTransactionSummary(entry.sql) }

  var body: some View {
    HStack(alignment: .top, spacing: Spacing.xs) {
      Circle()
        .fill(statusColor)
        .frame(width: 6, height: 6)
        .padding(.top, 4.5)
        .accessibilityLabel(statusName)

      VStack(alignment: .leading, spacing: Spacing.xxs) {
        sqlPreview
          .padding(.trailing, showsActions ? HistoryHoverButton.contentReserve : 0)

        HStack(spacing: Spacing.xs) {
          Text(durationLabel)
          Text("·")
          Text(HistoryRelativeTime.label(from: entry.executedAt, now: now))
            .layoutPriority(1)
          if let kind = HistoryRowLabels.kindLabel(entry.kind) {
            historyBadge(kind)
          }
          historyBadge(HistoryRowLabels.sourceLabel(entry.source))
        }
        .font(.caption)
        .foregroundColor(.foregroundMuted)
        .lineLimit(1)
        .padding(.trailing, showsActions ? HistoryHoverButton.contentReserve : 0)
      }
      .help(entry.connectionLabel)
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.xsm)
    .frame(
      maxWidth: .infinity, minHeight: showsActions ? Self.hoveredMinHeight : 0, alignment: .top
    )
    .contentShape(Rectangle())
    .onTapGesture(count: 2) {
      if canReplay {
        onInsert()
      } else {
        onViewDetail()
      }
    }
    .background {
      if isAlternate {
        Color.tableRowAlternate
      } else {
        Color.cellBackground
      }
      if showsActions {
        Color.cellBackgroundHover.opacity(0.5)
      }
    }
    .overlay(alignment: .topTrailing) {
      if showsActions {
        VStack(spacing: Spacing.xxs) {
          if canReplay {
            HistoryHoverButton(
              systemName: "text.badge.plus",
              help: "Insert into the current editor",
              action: onInsert,
              isHovering: $isHoveringInsert
            )
          }
          HistoryHoverButton(
            systemName: "magnifyingglass",
            help: "View detail",
            action: onViewDetail,
            isHovering: $isHoveringDetail
          )
        }
        .padding(.top, Spacing.xsm)
        .padding(.trailing, Spacing.md)
        .transition(.opacity)
      }
    }
    .animation(.easeOut(duration: 0.12), value: showsActions)
    .onHover { isHovering = $0 }
    .contextMenu {
      if canReplay {
        Button("Insert") { onInsert() }
        Button("Copy") { onCopy() }
      }
      Button("View Detail") { onViewDetail() }
      Divider()
      Button("Delete", role: .destructive) { onDelete() }
    }
  }

  /// At most two non-empty lines. A long single line may wrap to the second.
  private var sqlPreview: some View {
    let lines = HistorySQLPreview.lines(from: entry.sql)
    return VStack(alignment: .leading, spacing: 1) {
      if let first = lines.first {
        Text(first)
          .lineLimit(lines.count > 1 ? 1 : 2)
          .truncationMode(.tail)
      }
      if lines.count > 1 {
        Text(lines[1])
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
    .font(.monoSmall)
    .foregroundColor(.foreground)
    .multilineTextAlignment(.leading)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var statusColor: Color {
    entry.status == .success ? .success : .destructive
  }

  private var statusName: String {
    switch entry.status {
    case .success: "Succeeded"
    case .error: "Failed"
    case .cancelled: "Cancelled"
    }
  }

  private var durationLabel: String {
    CellResultViews.formatExecutionTime(Double(entry.durationMs) / 1_000)
  }

  /// Same capsule tokens as the filter row. Kind does not pick a color.
  private func historyBadge(_ title: String) -> some View {
    Text(title)
      .font(.caption2)
      .foregroundColor(.foregroundMuted)
      .lineLimit(1)
      .padding(.horizontal, Spacing.xs)
      .background(Capsule().fill(Color.inputBackground))
      .overlay(Capsule().strokeBorder(Color.border, lineWidth: 1))
  }

  /// Fits the insert button and the detail button under it.
  private static let hoveredMinHeight: CGFloat = 56
}

/// Minute-resolution age. Under a minute stays "just now", so the row does not tick each second.
enum HistoryRelativeTime {
  static func label(from date: Date, now: Date) -> String {
    let interval = now.timeIntervalSince(date)
    if interval < 60 { return "just now" }
    if interval < 3_600 {
      let minutes = Int(interval / 60)
      return "\(minutes) minute\(minutes == 1 ? "" : "s") ago"
    }
    if interval < 86_400 {
      let hours = Int(interval / 3_600)
      return "\(hours) hour\(hours == 1 ? "" : "s") ago"
    }
    let days = Int(interval / 86_400)
    if days < 7 {
      return "\(days) day\(days == 1 ? "" : "s") ago"
    }
    return dayFormatter.string(from: date)
  }

  private static let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter
  }()
}

/// Visible kind and source badges. Nil kind has no kind label.
nonisolated enum HistoryRowLabels: Sendable {
  static func kindLabel(_ kind: QueryHistoryEntry.Kind?) -> String? {
    switch kind {
    case .read: "Read"
    case .write: "Write"
    case .schema: "Schema"
    case .transaction: "Transaction"
    case .other: "Other"
    case nil: nil
    }
  }

  static func sourceLabel(_ source: QueryHistoryEntry.Source) -> String {
    switch source {
    case .cell: "Cell"
    case .editor: "Editor"
    case .dataViewerEdit: "Data Viewer Edit"
    case .dataImport: "Data Import"
    }
  }
}

/// Up to two non-empty lines of recorded SQL.
/// The second line always ends with "..." so the row reads as a preview.
nonisolated enum HistorySQLPreview {
  static func lines(from sql: String) -> [String] {
    let lines =
      sql.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    guard let first = lines.first else { return [] }
    guard lines.count > 1 else { return [first] }
    var second = lines[1]
    if !second.hasSuffix("...") {
      second += "..."
    }
    return [first, second]
  }
}

/// Icon button shown on the trailing edge of a hovered history row.
private struct HistoryHoverButton: View {
  /// Clears the SQL while the buttons sit on the first line.
  static let contentReserve: CGFloat = 26

  let systemName: String
  let help: String
  let action: () -> Void
  @Binding var isHovering: Bool

  var body: some View {
    Button(action: action) {
      Image(systemName: systemName)
    }
    .buttonStyle(GhostButtonStyle(iconOnly: true, hPadding: 4, vPadding: 4))
    .controlSize(.small)
    .help(help)
    .accessibilityLabel(help)
    .onHover { isHovering = $0 }
  }
}
