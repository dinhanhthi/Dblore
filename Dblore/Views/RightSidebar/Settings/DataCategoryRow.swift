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
            .font(.bodyText)
            .foregroundColor(.foregroundSubtle)
        }

        Spacer(minLength: Spacing.sm)

        sizeLabel
      }

      if row.category == .queryHistory {
        HistoryRetentionControls(isBusy: isBusy || row.loading, onClear: onClear)
      }

      if let error = row.error {
        Text(error)
          .font(.bodyText)
          .foregroundColor(.destructive)
          .textSelection(.enabled)
      }

      HStack(spacing: Spacing.sm) {
        if row.summary?.location != nil {
          Button("Reveal in Finder", action: reveal)
            .buttonStyle(FilledSecondaryButtonStyle())
            .linkPointer()
        }
        Button("Export", action: onExport)
          .buttonStyle(FilledSecondaryButtonStyle())
          .disabled(isBusy || row.loading)
          .linkPointer()
        if row.category != .queryHistory {
          Button("Clear", action: onClear)
            .buttonStyle(DangerButtonStyle())
            .disabled(isBusy || row.loading)
            .linkPointer()
        }
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
        .font(.mono)
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
  var isBusy: Bool
  let onClear: () -> Void

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
        CapsuleDropdown(
          title: retentionTitle(appSettings.historyRetentionDays),
          accessibilityLabel: "Keep for",
          options: Self.retentionOptions,
          optionTitle: retentionTitle,
          isSelected: { $0 == appSettings.historyRetentionDays },
          onSelect: { appSettings.historyRetentionDays = $0 }
        )
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
        .numberInputCapsuleStyle()
        .frame(width: 96)
        Stepper(
          "",
          onIncrement: {
            appSettings.historyMaxEntries = AppSettings.steppedHistoryMaxEntries(
              appSettings.historyMaxEntries, up: true)
          },
          onDecrement: {
            appSettings.historyMaxEntries = AppSettings.steppedHistoryMaxEntries(
              appSettings.historyMaxEntries, up: false)
          }
        )
        .compactStepperStyle()
      }

      Text(
        "Between \(entryRange.lowerBound.formatted()) and \(entryRange.upperBound.formatted()) statements. Older rows past this limit are deleted. Forever still stops at the limit."
      )
      .font(.bodyText)
      .foregroundColor(.foregroundSubtle)

      Button("Clear history", action: onClear)
        .buttonStyle(DangerButtonStyle())
        .disabled(isBusy)
        .linkPointer()
    }
    .padding(Spacing.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.appBackground, in: RoundedRectangle(cornerRadius: CornerRadius.md))
  }

  private static let retentionOptions = [7, 30, 90, 365, 0]

  private func retentionTitle(_ days: Int) -> String {
    switch days {
    case 7: "7 days"
    case 30: "30 days"
    case 90: "90 days"
    case 365: "365 days"
    case 0: "Forever"
    default: "\(days) days"
    }
  }
}
