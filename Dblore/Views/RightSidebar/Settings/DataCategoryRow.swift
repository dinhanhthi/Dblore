//
//  DataCategoryRow.swift
//  Dblore
//
//  One local-data category in Settings: size, export, clear, and history retention.
//

import AppKit
import SwiftUI

/// Byte and item-count text for the data settings lists.
enum DataByteCount {
  static func text(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  static func items(_ count: Int) -> String {
    count == 1 ? "1 item" : "\(count) items"
  }

  static func summary(_ summary: LocalDataSummary) -> String {
    "\(text(summary.bytes)) · \(items(summary.itemCount))"
  }
}

/// Icon, title, size, and actions for one category. Query history also hosts retention.
struct DataCategoryRow: View {
  let row: DataSettingsRow
  var isBusy: Bool
  let onExport: () -> Void
  let onClear: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
        Image(systemName: row.category.symbolName)
          .font(.bodyText)
          .foregroundColor(.foregroundMuted)
          .frame(width: 16)

        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text(row.category.title)
            .font(.bodyText)
            .foregroundColor(.foreground)
          Text(row.category.description)
            .font(.small)
            .foregroundColor(.foregroundSubtle)
        }

        Spacer(minLength: Spacing.sm)

        sizeLabel
      }

      if row.category == .queryHistory {
        HistoryRetentionControls()
      }

      if let error = row.error {
        Text(error)
          .font(.small)
          .foregroundColor(.destructive)
          .textSelection(.enabled)
      }

      HStack(spacing: Spacing.sm) {
        if row.summary?.location != nil {
          Button("Reveal in Finder", action: reveal)
            .buttonStyle(GhostButtonStyle())
            .controlSize(.small)
            .linkPointer()
        }
        Button("Export…", action: onExport)
          .buttonStyle(GhostButtonStyle())
          .controlSize(.small)
          .disabled(isBusy || row.loading)
          .linkPointer()
        Button("Clear…", action: onClear)
          .buttonStyle(DangerButtonStyle())
          .controlSize(.small)
          .disabled(isBusy || row.loading)
          .linkPointer()
      }
    }
  }

  @ViewBuilder
  private var sizeLabel: some View {
    if row.loading && row.summary == nil {
      ProgressView()
        .controlSize(.small)
    } else if let summary = row.summary {
      Text(DataByteCount.summary(summary))
        .font(.monoSmall)
        .foregroundColor(.foregroundMuted)
        .monospacedDigit()
    }
  }

  private func reveal() {
    guard let location = row.summary?.location else { return }
    NSWorkspace.shared.activateFileViewerSelecting([location])
  }
}

/// Retention for recorded statements. Allowed day values are clamped by `AppSettings`.
private struct HistoryRetentionControls: View {
  @Bindable private var appSettings = AppSettings.shared

  private var entryRange: ClosedRange<Int> { AppSettings.historyMaxEntriesRange }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      SettingsToggle(
        title: "Record query history",
        description: "Saves statements you run so they show up in the History tab.",
        isOn: $appSettings.historyEnabled
      )

      HStack(spacing: Spacing.sm) {
        Text("Keep for")
          .font(.bodyText)
          .foregroundColor(.foreground)
        Spacer(minLength: Spacing.sm)
        Picker("Keep for", selection: $appSettings.historyRetentionDays) {
          Text("7 days").tag(7)
          Text("30 days").tag(30)
          Text("90 days").tag(90)
          Text("365 days").tag(365)
          Text("Forever").tag(0)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
      }

      HStack(spacing: Spacing.sm) {
        Text("Max entries")
          .font(.bodyText)
          .foregroundColor(.foreground)
        Spacer(minLength: Spacing.sm)
        TextField(
          "\(AppSettings.defaultHistoryMaxEntries)",
          value: $appSettings.historyMaxEntries,
          format: .number.grouping(.never)
        )
        .textFieldStyle(.plain)
        .inputCapsuleStyle()
        .font(.monoSmall)
        .frame(width: 96)
      }

      Text(
        "Between \(entryRange.lowerBound.formatted()) and \(entryRange.upperBound.formatted()) statements. Forever keeps history until you clear it, still capped by max entries."
      )
      .font(.small)
      .foregroundColor(.foregroundSubtle)
    }
    .padding(.leading, 16 + Spacing.sm)
  }
}
