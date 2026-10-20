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
    if let mostRecent = getConnectionHistory().first {
      setSelectedHistoryId(mostRecent.id)
      loadConnection(mostRecent)
    }
  }

  /// Refreshes the menu after another view changed the history (e.g. an import). Keeps the
  /// form's values: `loadConnectionHistory()` would load the most recent row over them.
  func reloadHistoryList(_ note: Notification) {
    guard LocalDataCategory.notification(note, includes: .connectionHistory) else { return }
    setConnectionHistory(SessionManager.loadHistory())
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
