//
//  ConnectionImportSheet.swift
//  Dblore
//
//  Import connections from a URI, .pgpass, DBeaver, TablePlus or DataGrip. The sheet attaches to
//  the frontmost document window (above any modal on it), so the Welcome screen, the connection
//  form and the File menu all open the same sheet. Imported content is external input: rows are
//  shown as plain text and never include passwords.
//

import AppKit
import SwiftUI

// MARK: - Pure helpers

/// How a source is read.
nonisolated enum ImportSourcePicker: Equatable, Sendable {
  /// Typed or pasted text only (connection URI).
  case textOnly
  case file
  case folder
}

nonisolated extension ImportSource {
  /// Order of the source picker.
  static let sheetOrder: [ImportSource] = [.uri, .pgpass, .dbeaver, .tablePlus, .dataGrip]

  var title: String {
    switch self {
    case .uri: "Connection URI"
    case .pgpass: ".pgpass"
    case .dbeaver: "DBeaver"
    case .tablePlus: "TablePlus"
    case .dataGrip: "DataGrip"
    }
  }

  var hint: String {
    switch self {
    case .uri: "Paste a postgresql:// connection URI."
    case .pgpass: "Choose your .pgpass file or paste its contents."
    case .dbeaver:
      "Choose your DBeaver workspace's .dbeaver folder (e.g. ~/Library/DBeaverData/workspace6/General/.dbeaver)."
    case .tablePlus:
      "Choose Connections.plist in ~/Library/Application Support/com.tinyapp.TablePlus/Data."
    case .dataGrip: "Choose the project's .idea folder."
    }
  }

  var picker: ImportSourcePicker {
    switch self {
    case .uri: .textOnly
    case .pgpass, .tablePlus: .file
    case .dbeaver, .dataGrip: .folder
    }
  }

  /// Sources parsed from typed or pasted text.
  var acceptsText: Bool { self == .uri || self == .pgpass }
}

/// Badge on a preview row.
nonisolated enum ImportBadge: Hashable, Sendable {
  case password
  case noPassword
  case ssh
  case sshKeyNeeded
  case alreadySaved
  case duplicateInFile

  var title: String {
    switch self {
    case .password: "Password"
    case .noPassword: "No password"
    case .ssh: "SSH"
    case .sshKeyNeeded: "SSH key needed"
    case .alreadySaved: "Already saved"
    case .duplicateInFile: "Duplicate in file"
    }
  }
}

/// Sheet text that depends only on counts and row flags.
nonisolated enum ConnectionImportText {
  static func footer(selected: Int, freeSlots: Int) -> String {
    "\(selected) selected · \(freeSlots) free slot\(freeSlots == 1 ? "" : "s")"
  }

  static func overLimit(freeSlots: Int) -> String {
    freeSlots == 0
      ? "No more connections can be saved; the selected ones will be skipped."
      : "Only \(freeSlots) more connection\(freeSlots == 1 ? "" : "s") can be saved; the rest will be skipped."
  }

  static func badges(for row: ImportRow) -> [ImportBadge] {
    var badges: [ImportBadge] = [row.hasPassword ? .password : .noPassword]
    if row.hasSSH { badges.append(.ssh) }
    if row.sshNeedsKey { badges.append(.sshKeyNeeded) }
    switch row.duplicateReason {
    case .alreadySaved: badges.append(.alreadySaved)
    case .duplicateInFile: badges.append(.duplicateInFile)
    case nil: break
    }
    return badges
  }
}

// MARK: - Presenter

/// Attaches the import sheet to the frontmost document window, opening the Welcome window first
/// when none is open. One sheet at a time.
enum ConnectionImportPresenter {
  private static var sheet: NSWindow?

  static func present() {
    if let sheet {
      // The host window closed with the sheet on it: forget the stale sheet.
      guard sheet.sheetParent == nil else {
        sheet.makeKeyAndOrderFront(nil)
        return
      }
      self.sheet = nil
    }
    if let host = hostWindow() {
      attach(to: host)
      return
    }
    guard let welcome = NewWindowStore.shared.openWelcomeWindow(frame: .zero) else { return }
    // Let the new window finish showing before a sheet attaches to it.
    Task { @MainActor in attach(to: welcome) }
  }

  private static func attach(to host: NSWindow) {
    guard sheet == nil else { return }
    let view = ConnectionImportSheet(sheetWindow: { sheet }, onClose: close)
    let window = NSWindow(contentViewController: NSHostingController(rootView: view))
    sheet = window
    host.beginSheet(window)
  }

  static func close() {
    guard let sheet else { return }
    self.sheet = nil
    if let parent = sheet.sheetParent {
      parent.endSheet(sheet)
    } else {
      sheet.orderOut(nil)
    }
  }

  /// The frontmost visible document window, descending into the sheets already attached to it.
  private static func hostWindow() -> NSWindow? {
    let candidates = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 } + NSApp.orderedWindows
    var window = candidates.lazy.map(rootWindow).first { $0.isVisible && $0.isDbloreDocumentWindow }
    while let attached = window?.attachedSheet {
      window = attached
    }
    return window
  }

  private static func rootWindow(_ window: NSWindow) -> NSWindow {
    var root = window
    while let parent = root.sheetParent {
      root = parent
    }
    return root
  }
}

// MARK: - Sheet

struct ConnectionImportSheet: View {
  /// The window hosting this sheet, for the open panel.
  let sheetWindow: () -> NSWindow?
  let onClose: () -> Void

  @State private var model = ConnectionImportModel()
  @State private var text = ""
  @State private var chosenName: String?
  @State private var isImporting = false

  var body: some View {
    VStack(spacing: 0) {
      GenericModalHeader(
        title: "Import Connections", titleIcon: "square.and.arrow.down", onClose: close)

      VStack(alignment: .leading, spacing: Spacing.md) {
        sourceSection
        statusSection
        previewSection
      }
      .padding(Spacing.md)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

      footer
    }
    .frame(width: 620, height: 600)
    .background(Color.appBackground)
  }

  // MARK: Source

  private var sourceBinding: Binding<ImportSource> {
    Binding(
      get: { model.source },
      set: { newValue in
        guard newValue != model.source else { return }
        model.source = newValue
        model.reset()
        text = ""
        chosenName = nil
      })
  }

  private var sourceSection: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      CapsuleTabPicker(selection: sourceBinding, tabs: ImportSource.sheetOrder, height: 32) {
        Text($0.title)
      }

      Text(model.source.hint)
        .font(.small)
        .foregroundColor(.foregroundMuted)
        .fixedSize(horizontal: false, vertical: true)

      switch model.source {
      case .uri:
        HStack(spacing: Spacing.sm) {
          TextField("postgresql://user@host:5432/database", text: $text)
            .textFieldStyle(.plain)
            .font(.monoMedium)
            .inputCapsuleStyle()
            .onSubmit(previewText)
          Button("Preview", action: previewText)
            .buttonStyle(SecondaryButtonStyle())
            .disabled(trimmedText.isEmpty || model.isLoading)
        }
      case .pgpass:
        TextEditor(text: $text)
          .font(.monoMedium)
          .scrollContentBackground(.hidden)
          .frame(height: 64)
          .textAreaCapsuleStyle()
        HStack(spacing: Spacing.sm) {
          chooseButton
          Button("Preview Pasted Text", action: previewText)
            .buttonStyle(SecondaryButtonStyle())
            .disabled(trimmedText.isEmpty || model.isLoading)
          chosenLabel
        }
      case .dbeaver, .tablePlus, .dataGrip:
        HStack(spacing: Spacing.sm) {
          chooseButton
          chosenLabel
        }
      }
    }
  }

  private var chooseButton: some View {
    Button(model.source.picker == .folder ? "Choose Folder..." : "Choose File...", action: choose)
      .buttonStyle(SecondaryButtonStyle())
      .disabled(model.isLoading)
  }

  @ViewBuilder
  private var chosenLabel: some View {
    if let chosenName {
      Text(verbatim: chosenName)
        .font(.small)
        .foregroundColor(.foregroundMuted)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }

  private var trimmedText: String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: Status

  @ViewBuilder
  private var statusSection: some View {
    if model.isLoading {
      HStack(spacing: Spacing.sm) {
        ProgressView().controlSize(.small)
        Text("Reading connections...")
          .font(.small)
          .foregroundColor(.foregroundMuted)
      }
    }
    if let message = model.errorMessage {
      HStack(alignment: .top, spacing: Spacing.sm) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundColor(.warning)
        Text(verbatim: message)
          .foregroundColor(.warning)
          .fixedSize(horizontal: false, vertical: true)
      }
      .font(.small)
    }
    if !model.warnings.isEmpty {
      DisclosureGroup {
        warningList(model.warnings)
      } label: {
        Label(
          "\(model.warnings.count) warning\(model.warnings.count == 1 ? "" : "s")",
          systemImage: "exclamationmark.triangle"
        )
        .font(.small)
        .foregroundColor(.warning)
      }
    }
  }

  private func warningList(_ warnings: [String]) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xxs) {
      ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
        Text(verbatim: "• \(warning)")
          .font(.small)
          .foregroundColor(.foregroundMuted)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.leading, Spacing.sm)
  }

  // MARK: Preview

  private var previewSection: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack {
        Text(model.rows.isEmpty ? "Connections" : "Connections (\(model.rows.count))")
          .font(.labelText)
          .foregroundColor(.foregroundMuted)
        Spacer()
        if !model.rows.isEmpty {
          Button("Select All") { model.selectAll() }
            .buttonStyle(GhostButtonStyle())
          Button("Select None") { model.deselectAll() }
            .buttonStyle(GhostButtonStyle())
        }
      }

      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(model.rows) { row in
            ImportPreviewRow(row: row, onToggle: { model.toggle(row.id) })
            if row.id != model.rows.last?.id {
              Divider()
            }
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .overlay {
        if model.rows.isEmpty && !model.isLoading {
          Text("No connections to preview yet.")
            .font(.small)
            .foregroundColor(.foregroundSubtle)
        }
      }
      .cardStyle()
    }
  }

  // MARK: Footer

  private var footer: some View {
    GenericModalFooter {
      VStack(alignment: .leading, spacing: Spacing.xxs) {
        Text(
          ConnectionImportText.footer(selected: model.selectedCount, freeSlots: model.freeSlots)
        )
        .font(.small)
        .foregroundColor(.foregroundMuted)
        if model.overLimit {
          Text(ConnectionImportText.overLimit(freeSlots: model.freeSlots))
            .font(.small)
            .foregroundColor(.warning)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer()
      Button("Cancel", action: close)
        .buttonStyle(SecondaryButtonStyle())
        .keyboardShortcut(.cancelAction)
      Button("Import", action: runImport)
        .buttonStyle(PrimaryButtonStyle())
        .disabled(model.selectedCount == 0 || model.isLoading || isImporting)
    }
  }

  // MARK: Actions

  private func previewText() {
    let value = trimmedText
    guard !value.isEmpty, !model.isLoading else { return }
    chosenName = nil
    Task { @MainActor in
      await model.loadText(value)
      // Pasted text can hold passwords: drop it once it is parsed.
      if model.errorMessage == nil { text = "" }
    }
  }

  private func close() {
    text = ""
    onClose()
  }

  private func choose() {
    let panel = NSOpenPanel()
    let picksFolder = model.source.picker == .folder
    panel.canChooseDirectories = picksFolder
    panel.canChooseFiles = !picksFolder
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    panel.treatsFilePackagesAsDirectories = true
    panel.prompt = "Choose"
    panel.message = model.source.hint

    Task { @MainActor in
      let response: NSApplication.ModalResponse
      if let window = sheetWindow() {
        response = await panel.beginSheetModal(for: window)
      } else {
        response = panel.runModal()
      }
      guard response == .OK, let url = panel.url else { return }
      chosenName = url.lastPathComponent
      text = ""
      // Panel URLs are already readable in the sandbox; scope only when the URL needs it.
      let scoped = url.startAccessingSecurityScopedResource()
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      await model.load(url: url)
    }
  }

  private func runImport() {
    guard !isImporting else { return }
    isImporting = true
    Task { @MainActor in
      let report = await model.importSelected()
      let message = model.summary(report)
      // Welcome's recent list and open connection forms reload on this.
      LocalDataNotifications.post(.connectionHistory)
      // Close first, so the toast is not under the sheet.
      close()
      WorkspaceWindowManager.shared.showToast(
        message, type: report.failed.isEmpty ? .success : .warning)
    }
  }
}

// MARK: - Preview Row

private struct ImportPreviewRow: View {
  let row: ImportRow
  let onToggle: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: Spacing.sm) {
      Toggle(
        "", isOn: Binding(get: { row.isSelected }, set: { _ in onToggle() })
      )
      .toggleStyle(.checkbox)
      .labelsHidden()
      .disabled(!row.isSelectable)

      VStack(alignment: .leading, spacing: Spacing.xxs) {
        HStack(spacing: Spacing.xs) {
          Text(verbatim: row.name)
            .font(.bodyText)
            .foregroundColor(.foreground)
            .lineLimit(1)
          Text(verbatim: row.engine)
            .font(.smallest)
            .foregroundColor(.foregroundSubtle)
          if !row.warnings.isEmpty {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.smallest)
              .foregroundColor(.warning)
              .help(row.warnings.joined(separator: "\n"))
          }
        }
        Text(verbatim: row.user.isEmpty ? row.address : "\(row.user) @ \(row.address)")
          .font(.monoSmall)
          .foregroundColor(.foregroundMuted)
          .lineLimit(1)
          .truncationMode(.middle)
        HStack(spacing: Spacing.xs) {
          ForEach(ConnectionImportText.badges(for: row), id: \.self) { badge in
            ImportBadgeView(badge: badge)
          }
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
  }
}

private struct ImportBadgeView: View {
  let badge: ImportBadge

  var body: some View {
    Text(badge.title)
      .font(.smallest)
      .foregroundColor(tint)
      .padding(.horizontal, Spacing.xsm)
      .padding(.vertical, Spacing.xxs)
      .background(Capsule().fill(tint.opacity(0.12)))
  }

  private var tint: Color {
    switch badge {
    case .password: .success
    case .noPassword: .foregroundMuted
    case .ssh: .accent
    case .sshKeyNeeded: .warning
    case .alreadySaved, .duplicateInFile: .foregroundMuted
    }
  }
}
