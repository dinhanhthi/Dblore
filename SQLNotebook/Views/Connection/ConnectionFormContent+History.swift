//
//  ConnectionFormContent+History.swift
//  SQLNotebook
//
//  Connection history management
//

import SwiftUI

// MARK: - Connection History Extension

extension ConnectionFormContent {

  /// Connection history dropdown section
  @ViewBuilder
  func connectionHistorySection() -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text("Recent Connections")
        .font(.caption)
        .foregroundColor(.foregroundMuted)

      Menu {
        ForEach(getConnectionHistory()) { entry in
          Button(action: {
            loadConnection(entry)
          }) {
            HStack {
              // Connection name
              Text(entry.config.name)
                .font(.body)

              // Security indicators
              if let mode = entry.config.safeMode, mode != .silent {
                Image(
                  systemName: mode.requiresPassword
                    ? "lock.shield.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundColor(mode.requiresPassword ? .accent : .warning)
                .font(.caption)
              }
              if entry.config.protectionLevel != .none {
                Image(systemName: entry.config.protectionLevel.iconName)
                  .foregroundColor(
                    entry.config.protectionLevel == .readOnly ? .warning : .secondary
                  )
                  .font(.caption)
              }

              Spacer()

              Button(action: {
                prepareDeleteConnection(entry.id)
              }) {
                Image(systemName: "trash")
                  .foregroundColor(.destructive)
              }
              .buttonStyle(.plain)
              .pointerStyle(.link)
            }
          }
        }

        Divider()

        Button("Clear All History", role: .destructive) {
          clearAllHistory()
        }
      } label: {
        HStack {
          Text(selectedHistoryEntry?.config.name ?? "Select a connection")
            .foregroundColor(selectedHistoryEntry != nil ? .foreground : .foregroundMuted)
          Spacer()
          Image(systemName: "chevron.up.chevron.down")
            .font(.caption)
            .foregroundColor(.foregroundMuted)
        }
        .dropdownCapsuleStyle()
      }
      .buttonStyle(.plain)
      .pointerStyle(.link)
    }
    .confirmationDialog(
      "Delete Connection?",
      isPresented: showDeleteConfirmationBinding,
      titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) {
        if let id = getEntryToDelete() {
          deleteConnection(id)
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This will remove the connection from history and delete the saved password.")
    }
  }

  var selectedHistoryEntry: ConnectionHistoryEntry? {
    getConnectionHistory().first { $0.id == getSelectedHistoryId() }
  }

  func loadConnectionHistory() {
    setConnectionHistory(SessionManager.loadHistory())
    if let mostRecent = getConnectionHistory().first {
      setSelectedHistoryId(mostRecent.id)
      loadConnection(mostRecent)
    }
  }

  func loadConnection(_ entry: ConnectionHistoryEntry) {
    setSelectedHistoryId(entry.id)
    connectionConfig = entry.config

    if getInputMode() == .connectionString {
      setConnectionString(generateConnectionString())
    }
    updateConnectionStringSSLMode(entry.config.sslMode)
    clearTestResult()
    clearParseError()
  }

  func deleteConnection(_ id: UUID) {
    SessionManager.removeConnection(id: id)
    loadConnectionHistory()

    if getSelectedHistoryId() == id {
      setSelectedHistoryId(nil)
      connectionConfig = ConnectionConfig()
    }
  }

  func clearAllHistory() {
    SessionManager.clearAllHistory()
    loadConnectionHistory()
    setSelectedHistoryId(nil)
    connectionConfig = ConnectionConfig()
  }
}
