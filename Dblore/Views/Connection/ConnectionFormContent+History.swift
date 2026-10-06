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
              Text(DropdownTitle.singleLine(entry.config.name))
                .font(.body)

              historyShield(for: entry.config)
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
          prepareClearAllHistory()
        }
      } label: {
        HStack {
          Text(DropdownTitle.singleLine(selectedHistoryEntry?.config.name ?? "Select a connection"))
            .lineLimit(1)
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
    .confirmationDialog(
      "Clear All History?",
      isPresented: showClearAllConfirmationBinding,
      titleVisibility: .visible
    ) {
      Button("Clear All History", role: .destructive) {
        clearAllHistory()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "This removes every connection from Recent connections. Saved passwords and certificates for those connections are removed too."
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
      connectionConfig = Self.newFormDraft()
      resetCertificateDraft()
    }
  }

  func clearAllHistory() {
    SessionManager.clearAllHistory()
    loadConnectionHistory()
    setSelectedHistoryId(nil)
    connectionConfig = Self.newFormDraft()
    resetCertificateDraft()
  }

  /// Shield for any resolved style other than Immediate. Password tint only for Password.
  @ViewBuilder
  func historyShield(for config: ConnectionConfig) -> some View {
    let style = config.resolvedCommitStyle(fallback: AppSettings.shared.commitStyle)
    if style != .immediate {
      Image(systemName: style == .password ? "lock.shield.fill" : "exclamationmark.triangle.fill")
        .foregroundColor(style == .password ? .accent : .warning)
        .font(.caption)
    }
  }
}
