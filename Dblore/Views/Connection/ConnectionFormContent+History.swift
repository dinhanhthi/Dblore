//
//  ConnectionFormContent+History.swift
//  Dblore
//
//  Connection history management
//

import AppKit
import SwiftUI

// MARK: - Connection History Extension

extension ConnectionFormContent {

  /// Connection history dropdown section
  @ViewBuilder
  func connectionHistorySection() -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Menu {
        let groups = ConnectionAppearance.grouped(historyForSelectedType())
        ForEach(groups, id: \.name) { group in
          if let name = group.name {
            Section(name) { historyRows(group.entries) }
          } else {
            historyRows(group.entries)
          }
        }

        Divider()

        Button("Import Connections...") {
          ConnectionImportPresenter.present()
        }

        Button("Clear All History", role: .destructive) {
          prepareClearAllHistory()
        }
      } label: {
        HStack {
          if let color = selectedHistoryEntry?.config.colorTag {
            Circle()
              .fill(color.tagColor)
              .frame(width: 8, height: 8)
              .accessibilityLabel("Color \(color.rawValue)")
          }
          Text(selectedHistoryEntry.map { historyTitle($0.config) } ?? "Select a connection")
            .lineLimit(1)
            .foregroundColor(selectedHistoryEntry != nil ? .foreground : .foregroundMuted)
          if selectedHistoryEntry?.config.isLocked == true {
            lockMark
          }
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

  /// Menu rows of the recent connections, each with its color dot when it has one.
  @ViewBuilder
  func historyRows(_ entries: [ConnectionHistoryEntry]) -> some View {
    ForEach(entries) { entry in
      Button(action: {
        loadConnection(entry)
      }) {
        // A menu item draws an icon only from the button's own Label in .titleAndIcon style
        if let color = entry.config.colorTag {
          Label {
            Text(historyTitle(entry.config))
          } icon: {
            Self.menuColorDot(color)
              .accessibilityLabel("Color \(color.rawValue)")
          }
          .labelStyle(.titleAndIcon)
        } else {
          historyRowContent(entry)
        }
      }
    }
  }

  private func historyRowContent(_ entry: ConnectionHistoryEntry) -> some View {
    HStack {
      // Connection name
      Text(historyTitle(entry.config))
        .font(.body)

      historyShield(for: entry.config)
      if entry.config.isLocked {
        lockMark
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

  /// Marks a locked row: its saved password loads only after the unlock
  private var lockMark: some View {
    Image(systemName: "lock.fill")
      .font(.caption)
      .foregroundColor(.foregroundMuted)
      .help("Locked")
      .accessibilityLabel("Locked")
  }

  /// A drawn, non-template dot: a menu item would draw a SwiftUI shape or a tinted symbol in
  /// the menu's text color.
  static func menuColorDot(_ color: AccentColor) -> Image {
    let fill = NSColor(color.tagColor)
    let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
      fill.setFill()
      NSBezierPath(ovalIn: rect).fill()
      return true
    }
    image.isTemplate = false
    return Image(nsImage: image)
  }

  /// A row saved without a name shows `database@host:port` instead of an empty title.
  func historyTitle(_ config: ConnectionConfig) -> String {
    DropdownTitle.singleLine(config.name.isEmpty ? config.displayString : config.name)
  }

  var selectedHistoryEntry: ConnectionHistoryEntry? {
    historyForSelectedType().first { $0.id == getSelectedHistoryId() }
  }

  func loadConnectionHistory() {
    setConnectionHistory(SessionManager.loadHistory())
    let opening = Self.openingHistory(
      history: getConnectionHistory(), draft: connectionConfig, opensOnDraft: opensOnDraft)
    // Only a draft form writes the selection here; a fresh form keeps it for `deleteConnection`
    if let entry = opening.load {
      loadConnection(entry)
    } else if opensOnDraft {
      setSelectedHistoryId(opening.selectedHistoryId)
    }
  }

  /// Refreshes the menu after another view changed the history (e.g. an import). Keeps the
  /// form's values: `loadConnectionHistory()` would load the most recent row over them.
  func reloadHistoryList(_ note: Notification) {
    guard LocalDataCategory.notification(note, includes: .connectionHistory) else { return }
    setConnectionHistory(SessionManager.loadHistory())
  }

  /// The selection and the fields switch at once. A row whose lock is not unlocked in this
  /// session fills no password (a cached one may predate a relock) and no client certificate
  /// draft: it asks on this form's window and loads both only after the unlock; cancel keeps
  /// the row selected with an empty password and the saved certificate untouched.
  func loadConnection(_ entry: ConnectionHistoryEntry) {
    let blocked = LockCenter.shared.registry.refusal(for: entry.config) != nil
    setSelectedHistoryId(entry.id)
    setFieldsEngine(entry.config.databaseType)
    connectionConfig = entry.config
    if blocked {
      connectionConfig.password = ""
    }
    resetCertificateDraft()

    if getInputMode() == .connectionString {
      setConnectionString(generateConnectionString())
    }
    updateConnectionStringSSLMode(entry.config.sslMode)
    clearTestResult()
    clearParseError()
    if blocked {
      unlockSavedPassword(of: entry)
    }
  }

  private func unlockSavedPassword(of entry: ConnectionHistoryEntry) {
    Task {
      guard
        await LockCenter.shared.requestUnlock(
          for: entry.config, reason: "Unlock \(entry.shortDisplayName) to use it",
          anchor: hostWindow.window),
        // Not when another row was chosen while the prompt was open
        getSelectedHistoryId() == entry.id,
        ConnectionKeychainKey.password(for: connectionConfig) == entry.keychainKey
      else { return }
      if certificateDraftPending { restoreCertificateDraft() }
      // Nor over a password typed while the prompt was open
      guard connectionConfig.password.isEmpty else { return }
      connectionConfig = RecentManager.shared.withSavedPassword(connectionConfig)
      if getInputMode() == .connectionString {
        setConnectionString(generateConnectionString())
      }
    }
  }

  /// Deleting the last row of a locked connection would drop its lock: a blocked row asks
  /// first, and cancel or a refusal changes nothing.
  func deleteConnection(_ id: UUID) {
    Task {
      if let entry = getConnectionHistory().first(where: { $0.id == id }) {
        guard
          await LockCenter.shared.requestUnlock(
            for: entry.config, reason: "Unlock \(entry.shortDisplayName) to remove it",
            anchor: hostWindow.window)
        else { return }
      }
      guard SessionManager.removeConnection(id: id) else { return }
      loadConnectionHistory()

      if getSelectedHistoryId() == id {
        setSelectedHistoryId(nil)
        connectionConfig = Self.newFormDraft()
        resetCertificateDraft()
      }
    }
  }

  /// Each locked connection asks first; cancel or a refusal changes nothing.
  func clearAllHistory() {
    Task {
      let registry = LockCenter.shared.registry
      for entry in getConnectionHistory() where registry.refusal(for: entry.config) != nil {
        guard
          await LockCenter.shared.requestUnlock(
            for: entry.config, reason: "Unlock \(entry.shortDisplayName) to clear the history",
            anchor: hostWindow.window)
        else { return }
      }
      guard SessionManager.clearAllHistory() else { return }
      loadConnectionHistory()
      setSelectedHistoryId(nil)
      connectionConfig = Self.newFormDraft()
      resetCertificateDraft()
    }
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
