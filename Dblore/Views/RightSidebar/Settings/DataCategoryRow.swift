//
//  DataCategoryRow.swift
//  Dblore
//
//  One local-data category in Settings: size, export, clear, and history and Data Rewind
//  retention.
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

/// Icon, title, size, and actions for one category. Query history and Data Rewind also host
/// their recording switch and retention.
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

      if let error = row.error {
        Text(error)
          .font(.bodyText)
          .foregroundColor(.destructive)
          .textSelection(.enabled)
          .padding(.leading, Self.descriptionIndent)
      }

      actionButtons

      if row.category == .queryHistory {
        HistoryRetentionControls(isBusy: isBusy || row.loading, onClear: onClear)
          .padding(.leading, Self.descriptionIndent)
      }

      if row.category == .dataRewind {
        RewindRetentionControls(isBusy: isBusy || row.loading, onDelete: onClear)
          .padding(.leading, Self.descriptionIndent)
      }
    }
  }

  /// Lines up with the description, which starts after the category icon.
  private static let descriptionIndent: CGFloat = 16 + Spacing.sm

  private var actionButtons: some View {
    HStack(spacing: Spacing.sm) {
      if row.summary?.location != nil {
        Button("Reveal in Finder", action: reveal)
          .buttonStyle(FilledSecondaryButtonStyle())
          .linkPointer()
      }
      // Row data never leaves this Mac through an export
      if !row.category.isExcludedFromBackup {
        Button("Export", action: onExport)
          .buttonStyle(FilledSecondaryButtonStyle())
          .disabled(isBusy || row.loading)
          .linkPointer()
      }
      if row.category != .queryHistory && row.category != .dataRewind {
        Button("Clear", action: onClear)
          .buttonStyle(DangerButtonStyle())
          .disabled(isBusy || row.loading)
          .linkPointer()
      }
    }
    .padding(.leading, Self.descriptionIndent)
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
  @Environment(\.pixelLength) private var pixelLength

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
    // White in light so the box stands off the tinted card; same as before in dark
    .background(Color.panelBackground, in: RoundedRectangle(cornerRadius: CornerRadius.md))
    .overlay(
      RoundedRectangle(cornerRadius: CornerRadius.md)
        .strokeBorder(Color.border, lineWidth: pixelLength)
    )
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

/// Recording switch and retention for Data Rewind. Days are clamped by `AppSettings`.
private struct RewindRetentionControls: View {
  var isBusy: Bool
  let onDelete: () -> Void

  @Bindable private var appSettings = AppSettings.shared
  @Environment(\.pixelLength) private var pixelLength

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      SettingsToggle(
        title: "Record Data Rewind",
        description:
          "Reads each row before and after a data viewer edit, so the edit can be undone later.",
        isOn: $appSettings.rewindEnabled
      )

      HStack(spacing: Spacing.sm) {
        Text("Keep for")
          .font(.bodyText)
          .foregroundColor(.foreground)
        Spacer(minLength: Spacing.sm)
        CapsuleDropdown(
          title: "\(appSettings.rewindRetentionDays) days",
          accessibilityLabel: "Keep Data Rewind for",
          options: AppSettings.rewindRetentionChoices,
          optionTitle: { "\($0) days" },
          isSelected: { $0 == appSettings.rewindRetentionDays },
          onSelect: { appSettings.rewindRetentionDays = $0 }
        )
      }

      Text(
        "Up to \(DataByteCount.text(RewindStore.defaultMaxBytes)) of row data is kept; the oldest edits go first."
      )
      .font(.bodyText)
      .foregroundColor(.foregroundSubtle)

      Button("Delete", action: onDelete)
        .buttonStyle(DangerButtonStyle())
        .disabled(isBusy)
        .linkPointer()
    }
    .padding(Spacing.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    // Same box as query history retention
    .background(Color.panelBackground, in: RoundedRectangle(cornerRadius: CornerRadius.md))
    .overlay(
      RoundedRectangle(cornerRadius: CornerRadius.md)
        .strokeBorder(Color.border, lineWidth: pixelLength)
    )
  }
}
