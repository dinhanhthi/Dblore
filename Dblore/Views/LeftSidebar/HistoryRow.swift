//
//  HistoryRow.swift
//  Dblore
//
//  One recorded statement in the history sidebar
//

import SwiftUI

struct HistoryRow: View {
  let entry: QueryHistoryEntry
  /// Odd rows, matching the result grid.
  var isAlternate = false
  let onInsert: () -> Void
  let onRunInNewCell: () -> Void
  let onCopy: () -> Void
  let onDelete: () -> Void

  @State private var isHovering = false

  var body: some View {
    HStack(alignment: .top, spacing: Spacing.xs) {
      Circle()
        .fill(statusColor)
        .frame(width: 6, height: 6)
        .padding(.top, 5)
        .accessibilityLabel(statusName)

      VStack(alignment: .leading, spacing: Spacing.xxs) {
        Text(sqlPreview)
          .font(.mono)
          .foregroundColor(.foreground)
          .lineLimit(2)
          .multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .leading)

        HStack(spacing: Spacing.xs) {
          Text(durationLabel)
          Text("·")
          Text(entry.executedAt, style: .relative)
        }
        .font(.caption)
        .foregroundColor(.foregroundMuted)
        .lineLimit(1)
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.xs)
    .contentShape(Rectangle())
    .onTapGesture(count: 2) { onInsert() }
    .background {
      if isAlternate {
        Color.tableRowAlternate
      } else {
        Color.cellBackground
      }
      if isHovering {
        Color.cellBackgroundHover.opacity(0.5)
      }
    }
    .onHover { isHovering = $0 }
    .help(entry.connectionLabel)
    .contextMenu {
      Button("Insert") { onInsert() }
      Button("Run in New Cell") { onRunInNewCell() }
      Button("Copy") { onCopy() }
      Divider()
      Button("Delete", role: .destructive) { onDelete() }
    }
  }

  /// First non-empty line, wrapped to two lines by the text view.
  private var sqlPreview: String {
    let trimmed = entry.sql.trimmingCharacters(in: .whitespacesAndNewlines)
    let firstLine =
      trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
    let line = firstLine.trimmingCharacters(in: .whitespaces)
    return line.isEmpty ? trimmed : line
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
}
