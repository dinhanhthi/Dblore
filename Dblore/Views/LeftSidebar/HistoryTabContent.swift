//
//  HistoryTabContent.swift
//  Dblore
//
//  History tab of the left sidebar: recorded SQL from the local store
//

import SwiftUI

struct HistoryTabContent: View {
  @Bindable var workspaceManager: WorkspaceManager

  /// Stays false until the first refresh finishes, so an empty store does not flash the empty state.
  @State private var hasLoaded = false

  private var historyList: HistoryListModel { workspaceManager.historyList }

  var body: some View {
    @Bindable var historyList = workspaceManager.historyList

    VStack(spacing: 0) {
      SidebarFilterField(text: $historyList.query) {
        HStack(spacing: Spacing.sm) {
          writesFilter
          filterMenu
        }
        .fixedSize(horizontal: true, vertical: false)
      }
      content
    }
    .onAppear {
      Task {
        await workspaceManager.refreshHistory()
        hasLoaded = true
      }
    }
  }

  /// Same capsule and height as the scope menu. On keeps `kind == write`.
  private var writesFilter: some View {
    let isOn = historyList.writesOnly
    return Button {
      historyList.writesOnly.toggle()
    } label: {
      Text("Writes")
        .font(.system(size: 11))
        .foregroundStyle(isOn ? Color.onAccent : Color.foreground)
        .lineLimit(1)
        .padding(.horizontal, Spacing.sm)
        .frame(height: SidebarFilterMetrics.controlHeight)
        .background(Capsule().fill(isOn ? Color.accent : Color.inputBackground))
        .overlay(Capsule().stroke(isOn ? Color.accent : Color.border, lineWidth: 1))
    }
    .buttonStyle(.plain)
    .linkPointer()
    .fixedSize(horizontal: true, vertical: false)
    .frame(height: SidebarFilterMetrics.controlHeight)
    .help("Show only writes")
    .accessibilityLabel("Writes")
    .accessibilityValue(isOn ? "On" : "Off")
  }

  /// Same capsule as the Chart and Explain menus, so the menu opens under the button.
  private var filterMenu: some View {
    Menu {
      Section("Scope") {
        scopeButton(.all, title: HistoryScope.all.menuTitle)
        scopeButton(.connection, title: HistoryScope.connection.menuTitle)
        scopeButton(.workspace, title: HistoryScope.workspace.menuTitle)
      }
      Section("Status") {
        statusButton(nil, title: "All Statuses")
        statusButton(.success, title: "Succeeded")
        statusButton(.error, title: "Failed")
        statusButton(.cancelled, title: "Cancelled")
      }
    } label: {
      HStack(spacing: Spacing.xs) {
        Text(filterTitle)
          .font(.system(size: 11))
          .foregroundStyle(Color.foreground)
          .lineLimit(1)
        Image(systemName: "chevron.down")
          .font(.system(size: 9))
          .foregroundStyle(Color.foregroundMuted)
      }
      .padding(.horizontal, Spacing.sm)
      .frame(height: SidebarFilterMetrics.controlHeight)
      .background(Capsule().fill(Color.inputBackground))
      .overlay(Capsule().stroke(Color.border, lineWidth: 1))
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .linkPointer()
    .fixedSize(horizontal: historyList.status == nil, vertical: false)
    .frame(maxWidth: historyList.status == nil ? nil : 116)
    .frame(height: SidebarFilterMetrics.controlHeight)
    .help(filterTitle)
    .accessibilityLabel(filterTitle)
  }

  private var filterTitle: String {
    guard let status = historyList.status else { return historyList.scope.selectedTitle }
    let statusTitle: String
    switch status {
    case .success: statusTitle = "Succeeded"
    case .error: statusTitle = "Failed"
    case .cancelled: statusTitle = "Cancelled"
    }
    return "\(historyList.scope.selectedTitle) · \(statusTitle)"
  }

  private func scopeButton(_ scope: HistoryScope, title: String) -> some View {
    Button {
      historyList.scope = scope
    } label: {
      if historyList.scope == scope {
        Label(title, systemImage: "checkmark")
      } else {
        Text(title)
      }
    }
  }

  private func statusButton(_ status: QueryHistoryEntry.Status?, title: String) -> some View {
    Button {
      historyList.status = status
    } label: {
      if historyList.status == status {
        Label(title, systemImage: "checkmark")
      } else {
        Text(title)
      }
    }
  }

  @ViewBuilder
  private var content: some View {
    if historyList.results.isEmpty && (historyList.isLoading || !hasLoaded) {
      loadingState
    } else if historyList.results.isEmpty {
      if queryIsBlank && historyList.scope == .all && historyList.status == nil
        && !historyList.writesOnly
      {
        emptyState
      } else {
        noMatchesState
      }
    } else {
      list
    }
  }

  private var queryIsBlank: Bool {
    historyList.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var loadingState: some View {
    ProgressView()
      .controlSize(.small)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var emptyState: some View {
    VStack(spacing: Spacing.sm) {
      Image(systemName: "clock")
        .font(.system(size: 24))
        .foregroundColor(.foregroundSubtle)

      Text("No query history yet")
        .font(.caption)
        .foregroundColor(.foregroundMuted)

      Button {
        NotificationCenter.default.post(
          name: .openSettings,
          object: nil,
          userInfo: [SettingsPage.userInfoKey: SettingsPage.data.rawValue]
        )
      } label: {
        Label("Data settings", systemImage: "externaldrive")
      }
      .buttonStyle(SecondaryButtonStyle())
      .controlSize(.small)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var noMatchesState: some View {
    Text("No matches")
      .font(.caption)
      .foregroundColor(.foregroundMuted)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var list: some View {
    VStack(spacing: 0) {
      // One clock for the whole list. Minute buckets avoid a per-row seconds timer.
      TimelineView(.everyMinute) { _ in
        let now = Date()
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(historyList.results.enumerated()), id: \.element.id) { index, entry in
              VStack(spacing: 0) {
                HistoryRow(
                  entry: entry,
                  now: now,
                  isAlternate: index % 2 == 1,
                  onInsert: { workspaceManager.insertHistory(entry) },
                  onViewDetail: { workspaceManager.historyDetail = entry },
                  onCopy: { workspaceManager.copyHistory(entry) },
                  onDelete: { Task { await workspaceManager.deleteHistory(ids: [entry.id]) } }
                )
                if entry.id != historyList.results.last?.id {
                  Color.border.frame(height: 1)
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .padding(.bottom, Spacing.sm)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      Divider()
      pageBar
    }
  }

  private var pageBar: some View {
    HStack(spacing: Spacing.xs) {
      pageButton(
        "chevron.left", help: "Previous page", enabled: historyList.canGoPrevious
      ) {
        await historyList.goToPage(historyList.page - 1)
      }
      Text(historyList.pageLabel)
        .font(.caption)
        .foregroundColor(.foregroundMuted)
        .lineLimit(1)
      pageButton("chevron.right", help: "Next page", enabled: historyList.canGoNext) {
        await historyList.goToPage(historyList.page + 1)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, Spacing.xs)
  }

  private func pageButton(
    _ icon: String, help: String, enabled: Bool, action: @escaping () async -> Void
  ) -> some View {
    Button(action: { Task { await action() } }) {
      Image(systemName: icon)
    }
    .buttonStyle(GhostButtonStyle(iconOnly: true))
    .controlSize(.small)
    .help(help)
    .disabled(!enabled || historyList.isLoading)
  }
}
