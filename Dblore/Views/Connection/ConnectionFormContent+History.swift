//
//  ConnectionFormContent+History.swift
//  Dblore
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
      Menu {
        ForEach(historyForSelectedType()) { entry in
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
              .linkPointer()
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
      .linkPointer()
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
      Text(
        "This removes the connection from Recent connections. Its saved certificate is removed when no other Recent connection uses it."
      )
    }
  }

  var selectedHistoryEntry: ConnectionHistoryEntry? {
    historyForSelectedType().first { $0.id == getSelectedHistoryId() }
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
    setFieldsEngine(entry.config.databaseType)
    connectionConfig = entry.config
    resetCertificateDraft()

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
      resetCertificateDraft()
    }
  }

  func clearAllHistory() {
    SessionManager.clearAllHistory()
    loadConnectionHistory()
    setSelectedHistoryId(nil)
    connectionConfig = ConnectionConfig()
    resetCertificateDraft()
  }
}
