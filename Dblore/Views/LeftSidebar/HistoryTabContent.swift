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
        scopeMenu
      }
      Divider()
      content
    }
    .onAppear {
      Task {
        await workspaceManager.refreshHistory()
        hasLoaded = true
      }
    }
  }

  /// Same capsule as the Chart and Explain menus, so the menu opens under the button.
  private var scopeMenu: some View {
    Menu {
      scopeButton(.all, title: "All")
      scopeButton(.connection, title: "This Connection")
      scopeButton(.workspace, title: "This Workspace")
    } label: {
      HStack(spacing: Spacing.xs) {
        Text(scopeTitle(historyList.scope))
          .font(.system(size: 11))
          .foregroundStyle(Color.foreground)
          .lineLimit(1)
        Image(systemName: "chevron.down")
          .font(.system(size: 9))
          .foregroundStyle(Color.foregroundMuted)
      }
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xs)
      .background(Capsule().fill(Color.inputBackground))
      .overlay(Capsule().stroke(Color.border, lineWidth: 1))
    }
    .buttonStyle(.plain)
    .linkPointer()
    .fixedSize()
    .help("History scope")
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

  private func scopeTitle(_ scope: HistoryScope) -> String {
    switch scope {
    case .all: "All"
    case .connection: "This Connection"
    case .workspace: "This Workspace"
    }
  }

  @ViewBuilder
  private var content: some View {
    if historyList.results.isEmpty && (historyList.isLoading || !hasLoaded) {
      loadingState
    } else if historyList.results.isEmpty {
      if queryIsBlank && historyList.scope == .all {
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
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(Array(historyList.results.enumerated()), id: \.element.id) { index, entry in
          VStack(spacing: 0) {
            HistoryRow(
              entry: entry,
              isAlternate: index % 2 == 1,
              onInsert: { workspaceManager.insertHistory(entry) },
              onRunInNewCell: { workspaceManager.runHistoryInNewCell(entry) },
              onCopy: { workspaceManager.copyHistory(entry) },
              onDelete: { Task { await workspaceManager.deleteHistory(ids: [entry.id]) } }
            )
            if entry.id != historyList.results.last?.id {
              Color.border.frame(height: 1)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .onAppear {
            guard entry.id == historyList.results.last?.id else { return }
            Task { await historyList.loadMore() }
          }
        }
      }
      .padding(.vertical, Spacing.sm)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
