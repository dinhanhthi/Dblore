//
//  QueryInsightsView.swift
//  Dblore
//
//  Query Insights sheet of the History tab: run statistics per statement fingerprint over the
//  last 24 hours, 7 days or 30 days (at most 50,000 runs), for every connection or one.
//  The store read runs on its actor and the aggregation off the main actor, with a loading
//  state meanwhile. Open in Editor inserts the newest run, as the history list's Insert does.
//

import SwiftUI

struct QueryInsightsView: View {
  @Bindable var workspaceManager: WorkspaceManager
  let onClose: () -> Void

  @State private var window: QueryInsightsWindow = .day
  /// Nil for every connection
  @State private var connectionKey: String?
  /// From the last read of every connection, so picking one keeps the others in the menu
  @State private var connections: [QueryInsightsConnection] = []
  @State private var insights: [QueryInsight] = []
  @State private var runCount = 0
  @State private var isLoading = true
  @State private var loadFailed = false
  /// Bumped by Retry so the load task runs again with the same filters
  @State private var reloads = 0
  @State private var sortKey: SortKey = .count
  @State private var ascending = false
  @State private var selection: QueryInsight.ID?

  private var historyEnabled: Bool { AppSettings.shared.historyEnabled }

  private var request: LoadRequest {
    LoadRequest(
      window: window, connectionKey: connectionKey, historyEnabled: historyEnabled,
      reloads: reloads)
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      footer
    }
    .frame(width: 920, height: 580)
    .background(Color.appBackground)
    .task(id: request) { await load() }
  }

  // MARK: - Header and footer

  private var header: some View {
    HStack(spacing: Spacing.sm) {
      Text("Query Insights")
        .font(.subheading)
        .foregroundColor(.foreground)
      Spacer()
      Picker("Window", selection: $window) {
        ForEach(QueryInsightsWindow.allCases, id: \.self) { window in
          Text(window.title).tag(window)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      .help("Time window")
      connectionMenu
      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .semibold))
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .help("Close")
    }
    .modalBarPadding(vertical: Spacing.sm)
  }

  /// Same capsule as the History tab's filter menu
  private var connectionMenu: some View {
    Menu {
      Toggle(
        "All Connections",
        isOn: Binding(get: { connectionKey == nil }, set: { _ in connectionKey = nil }))
      if !connections.isEmpty {
        Divider()
      }
      ForEach(connections) { connection in
        Toggle(
          connection.label,
          isOn: Binding(
            get: { connectionKey == connection.key }, set: { _ in connectionKey = connection.key }
          ))
      }
    } label: {
      HStack(spacing: Spacing.xs) {
        Text(connectionTitle)
          .font(.system(size: 11))
          .foregroundStyle(Color.foreground)
          .lineLimit(1)
          .truncationMode(.middle)
        Image(systemName: "chevron.down")
          .font(.system(size: 9))
          .foregroundStyle(Color.foregroundMuted)
      }
      .padding(.horizontal, Spacing.sm)
      .frame(height: SidebarFilterMetrics.controlHeight)
      .background(Capsule().fill(Color.controlBackground))
      .overlay(HairlineBorder(shape: Capsule()))
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .linkPointer()
    .fixedSize()
    .frame(maxWidth: 220)
    .help("Connection")
    .accessibilityLabel("Connection: \(connectionTitle)")
  }

  private var connectionTitle: String {
    guard let connectionKey else { return "All Connections" }
    return connections.first { $0.key == connectionKey }?.label ?? "One Connection"
  }

  private var footer: some View {
    HStack(spacing: Spacing.sm) {
      Text(footerText)
        .font(.small)
        .foregroundColor(.foregroundMuted)
        .lineLimit(1)
      Spacer()
      Button("Close", action: onClose)
        .buttonStyle(GhostButtonStyle())
        .keyboardShortcut(.cancelAction)
      Button("Open in Editor") {
        if let selected { open(selected) }
      }
      .buttonStyle(PrimaryButtonStyle())
      .disabled(selected == nil || !canInsert)
      .help(canInsert ? "Insert the newest run into the current editor" : "Open an editor first")
    }
    .modalBarPadding()
  }

  private var footerText: String {
    guard !isLoading, historyEnabled, runCount > 0 else { return "" }
    let runs = "\(runCount.formatted()) run\(runCount == 1 ? "" : "s")"
    let statements = "\(insights.count.formatted()) statement\(insights.count == 1 ? "" : "s")"
    let capped =
      runCount >= QueryInsightsAggregator.maxRows
      ? " (the newest \(QueryInsightsAggregator.maxRows.formatted()))" : ""
    return "\(runs)\(capped), \(statements)"
  }

  private var selected: QueryInsight? {
    selection.flatMap { id in insights.first { $0.id == id } }
  }

  /// The tab has an editor or a selected cell to insert into
  private var canInsert: Bool {
    workspaceManager.activeViewModel?.canInsertText == true
  }

  private func open(_ insight: QueryInsight) {
    guard canInsert else { return }
    workspaceManager.insertHistory(insight.latest)
    onClose()
  }

  // MARK: - Content

  @ViewBuilder
  private var content: some View {
    if !historyEnabled {
      emptyState("Query history is off", showsSettings: true)
    } else if isLoading {
      MongoOverviewPlaceholder(text: "Aggregating query history…", isLoading: true)
    } else if loadFailed {
      MongoOverviewPlaceholder(
        text: "Query history could not be read", isError: true, retry: { reloads += 1 })
    } else if insights.isEmpty {
      emptyState("No queries in the \(window.phrase)", showsSettings: false)
    } else {
      table
    }
  }

  private func emptyState(_ text: String, showsSettings: Bool) -> some View {
    VStack(spacing: Spacing.sm) {
      Image(systemName: "clock")
        .font(.system(size: 24))
        .foregroundColor(.foregroundSubtle)
      Text(text)
        .font(.caption)
        .foregroundColor(.foregroundMuted)
      if showsSettings {
        Button {
          onClose()
          NotificationCenter.default.post(
            name: .openSettings, object: nil,
            userInfo: [SettingsPage.userInfoKey: SettingsPage.data.rawValue])
        } label: {
          Label("Data settings", systemImage: "externaldrive")
        }
        .buttonStyle(SecondaryButtonStyle())
        .controlSize(.small)
      }
    }
  }

  private var table: some View {
    let rows = sortedInsights
    let now = Date()
    return VStack(spacing: 0) {
      tableHeader
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(Array(rows.enumerated()), id: \.element.id) { position, insight in
            row(insight, now: now)
              .structureTableRow(isFirst: position == 0)
              .background(selection == insight.id ? Color.selectionFill : Color.clear)
              .contentShape(Rectangle())
              .onTapGesture(count: 2) { open(insight) }
              .simultaneousGesture(TapGesture().onEnded { selection = insight.id })
              .contextMenu {
                Button("Open in Editor") { open(insight) }
                  .disabled(!canInsert)
              }
          }
        }
      }
    }
    .background(Color.cardBackground)
  }

  private var tableHeader: some View {
    HStack(spacing: Spacing.sm) {
      sortButton("Query", .query, alignment: .leading)
        .frame(minWidth: InsightsWidth.queryMin, maxWidth: .infinity, alignment: .leading)
      ForEach(SortKey.numberColumns, id: \.self) { key in
        sortButton(key.title, key, alignment: .trailing)
          .frame(width: key.width, alignment: .trailing)
          .structureColumnDivider()
      }
    }
    .structureTableHeader()
  }

  private func sortButton(_ title: String, _ key: SortKey, alignment: Alignment) -> some View {
    Button {
      if sortKey == key {
        ascending.toggle()
      } else {
        sortKey = key
        // Text reads A to Z first, numbers and dates largest first
        ascending = key == .query
      }
    } label: {
      HStack(spacing: Spacing.xxs) {
        Text(title)
        if sortKey == key {
          Image(systemName: ascending ? "chevron.up" : "chevron.down")
            .font(.system(size: 8, weight: .semibold))
        }
      }
      .frame(maxWidth: .infinity, alignment: alignment)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Sort by \(title.lowercased())")
  }

  private func row(_ insight: QueryInsight, now: Date) -> some View {
    HStack(spacing: Spacing.sm) {
      HStack(spacing: Spacing.xs) {
        // A fingerprint is one line; long SQL shows its first lines, as the history list does
        Text(
          insight.isFingerprinted
            ? String(insight.text.prefix(400))
            : HistorySQLPreview.lines(from: String(insight.text.prefix(2_000)))
              .joined(separator: " ")
        )
        .font(.monoSmall)
        .foregroundColor(.structureCellForeground)
        .lineLimit(2)
        .truncationMode(.tail)
        .help(insight.latest.connectionLabel)
        if !insight.isFingerprinted {
          Text("Exact text")
            .font(.caption2)
            .foregroundColor(.foregroundMuted)
            .lineLimit(1)
            .padding(.horizontal, Spacing.xs)
            .background(Capsule().fill(Color.inputBackground))
            .overlay(HairlineBorder(shape: Capsule()))
            .fixedSize()
            .help("Over 100,000 characters: grouped by its exact text, not by fingerprint")
        }
      }
      .frame(minWidth: InsightsWidth.queryMin, maxWidth: .infinity, alignment: .leading)
      ForEach(SortKey.numberColumns, id: \.self) { key in
        Text(value(key, of: insight, now: now))
          .font(.structureField)
          .foregroundColor(.structureCellMuted)
          .monospacedDigit()
          .lineLimit(1)
          .frame(width: key.width, alignment: .trailing)
      }
    }
  }

  private func value(_ key: SortKey, of insight: QueryInsight, now: Date) -> String {
    switch key {
    case .query: insight.text
    case .count: insight.count.formatted()
    case .average: CellResultViews.formatExecutionTime(insight.averageMs / 1_000)
    case .p95: CellResultViews.formatExecutionTime(Double(insight.p95Ms) / 1_000)
    case .max: CellResultViews.formatExecutionTime(Double(insight.maxMs) / 1_000)
    case .errorRate: insight.errorRate.formatted(.percent.precision(.fractionLength(0...1)))
    case .lastRun: HistoryRelativeTime.label(from: insight.lastRun, now: now)
    }
  }

  private var sortedInsights: [QueryInsight] {
    insights.sorted { ascending ? sortKey.precedes($0, $1) : sortKey.precedes($1, $0) }
  }

  // MARK: - Loading

  /// Reads the window on the store's actor, then aggregates off the main actor. A filter change
  /// cancels this task (`task(id:)`), and a cancelled load leaves the state to the next one.
  private func load() async {
    guard historyEnabled, let store = workspaceManager.resolvedHistoryBrowser() else {
      insights = []
      runCount = 0
      isLoading = false
      return
    }
    isLoading = true
    loadFailed = false
    let since = Date().addingTimeInterval(-window.duration)
    let key = connectionKey
    do {
      let rows = try await store.entries(since: since, connectionKey: key)
      let summary = await QueryInsightsAggregator.summary(of: rows)
      guard !Task.isCancelled else { return }
      insights = summary.insights
      runCount = rows.count
      if key == nil { connections = summary.connections }
      if let selection, !summary.insights.contains(where: { $0.id == selection }) {
        self.selection = nil
      }
    } catch {
      guard !Task.isCancelled else { return }
      insights = []
      runCount = 0
      loadFailed = true
      await AppLogger.shared.error(
        "Query insights read failed: \(error.localizedDescription)", category: "History")
    }
    isLoading = false
  }

  private struct LoadRequest: Equatable {
    let window: QueryInsightsWindow
    let connectionKey: String?
    let historyEnabled: Bool
    let reloads: Int
  }

  fileprivate enum SortKey: Hashable {
    case query, count, average, p95, max, errorRate, lastRun

    static let numberColumns: [SortKey] = [.count, .average, .p95, .max, .errorRate, .lastRun]

    var title: String {
      switch self {
      case .query: "Query"
      case .count: "Runs"
      case .average: "Avg"
      case .p95: "p95"
      case .max: "Max"
      case .errorRate: "Errors"
      case .lastRun: "Last Run"
      }
    }

    var width: CGFloat {
      self == .lastRun ? InsightsWidth.lastRun : InsightsWidth.number
    }

    /// `a` before `b` in ascending order
    func precedes(_ a: QueryInsight, _ b: QueryInsight) -> Bool {
      switch self {
      case .query: a.text.localizedStandardCompare(b.text) == .orderedAscending
      case .count: a.count < b.count
      case .average: a.averageMs < b.averageMs
      case .p95: a.p95Ms < b.p95Ms
      case .max: a.maxMs < b.maxMs
      case .errorRate: a.errorRate < b.errorRate
      case .lastRun: a.lastRun < b.lastRun
      }
    }
  }
}

/// The windows Query Insights reads, back from now
enum QueryInsightsWindow: CaseIterable, Hashable {
  case day, week, month

  var title: String {
    switch self {
    case .day: "24 h"
    case .week: "7 d"
    case .month: "30 d"
    }
  }

  /// For "No queries in the …"
  var phrase: String {
    switch self {
    case .day: "last 24 hours"
    case .week: "last 7 days"
    case .month: "last 30 days"
    }
  }

  var duration: TimeInterval {
    switch self {
    case .day: 24 * 60 * 60
    case .week: 7 * 24 * 60 * 60
    case .month: 30 * 24 * 60 * 60
    }
  }
}

private enum InsightsWidth {
  static let queryMin: CGFloat = 280
  static let number: CGFloat = 72
  static let lastRun: CGFloat = 110
}
