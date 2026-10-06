//
//  DataSettingsSection.swift
//  Dblore
//
//  Settings → Data: size, export, import, and confirmed removal of local data.
//  Secret values are never shown. Safe Mode removal goes through the settings model.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
  static let dbloreBackup = UTType(exportedAs: "ace.thi.dblore.backup", conformingTo: .package)
}

struct DataSettingsSection: View {
  @Bindable var model: DataSettingsModel

  @State private var exportSheet: SheetToken?
  @State private var clearSheet: SheetToken?
  @State private var importRequest: DataImportRequest?
  @State private var pendingClear: LocalDataCategory?
  @State private var pendingSecret: SecretItem?
  @State private var busy = false
  @State private var notice: DataNotice?

  init(model: DataSettingsModel = DataSettingsProduction.model) {
    self.model = model
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      SettingsGroupCard(title: "On this Mac", accessory: { totalSize }) {
        headerActions
      }
      ForEach(DataSettingsGroup.allCases, id: \.self) { group in
        groupCard(group)
      }
      SettingsGroupCard(title: "Saved credentials") {
        secrets
      }
    }
    .task { await model.refresh() }
    .onReceive(NotificationCenter.default.publisher(for: .localDataChanged)) { _ in
      Task { await model.refresh() }
    }
    .sheet(item: $exportSheet) { _ in
      DataExportAllSheet(model: model) { selected in
        exportSheet = nil
        let chosen = selected
        Task { @MainActor in
          await Task.yield()
          presentSavePanel(named: "Dblore Backup.dblorebackup") { url in
            await writeExportAll(chosen, to: url)
          }
        }
      } onCancel: {
        exportSheet = nil
      }
    }
    .sheet(item: $importRequest) { request in
      DataImportSheet(
        url: request.url,
        manifest: request.manifest,
        model: model,
        onCancel: {
          request.access.release()
          importRequest = nil
        },
        onImported: {
          request.access.release()
          importRequest = nil
          notice = DataNotice(text: "Import finished.", isError: false)
        }
      )
    }
    .sheet(item: $clearSheet) { _ in
      DataClearAllSheet(model: model) {
        clearSheet = nil
        let failed = model.error != nil || model.rows.contains { $0.error != nil }
        notice = DataNotice(
          text: failed ? "Some data could not be cleared." : "Local data cleared.",
          isError: failed
        )
      } onCancel: {
        clearSheet = nil
      }
    }
    .confirmationDialog(
      "Clear \(pendingClear?.title ?? "data")?",
      isPresented: clearIsPresented,
      titleVisibility: .visible
    ) {
      Button("Clear", role: .destructive) { confirmClear() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This removes \(pendingClear?.title ?? "this category") from this Mac.")
    }
    .confirmationDialog(
      "Delete saved item?",
      isPresented: secretIsPresented,
      titleVisibility: .visible,
      presenting: pendingSecret
    ) { item in
      Button("Delete", role: .destructive) {
        let token = model.prepareDeleteSecret(item)
        Task { await model.deleteSecret(item, confirmed: token) }
      }
      Button("Cancel", role: .cancel) {}
    } message: { item in
      if item.kind == .clientCertificate {
        Text("Deletes the saved client certificate and private key for account \(item.account).")
      } else {
        Text(
          "Removes \(item.label) (\(dataSecretKindTitle(item.kind))). The saved value is deleted.")
      }
    }
  }

  @ViewBuilder
  private func groupCard(_ group: DataSettingsGroup) -> some View {
    let rows = group.categories.compactMap(row(for:))
    if !rows.isEmpty {
      SettingsGroupCard(title: group.title) {
        VStack(alignment: .leading, spacing: Spacing.md) {
          ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            if index > 0 {
              Divider()
            }
            DataCategoryRow(
              row: row,
              isBusy: busy,
              onExport: { export(row.category) },
              onClear: { pendingClear = row.category }
            )
          }
        }
      }
    }
  }

  private func row(for category: LocalDataCategory) -> DataSettingsRow? {
    model.rows.first { $0.category == category }
  }

  /// Sits on the "On this Mac" title row, to the right of the title.
  private var totalSize: some View {
    HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
      Text("Total size")
        .font(.bodyText)
        .foregroundColor(.foregroundMuted)
      if model.rows.contains(where: \.loading) {
        ProgressView()
          .controlSize(.small)
      }
      Text(DataByteCount.text(model.totalBytes))
        .font(.mono)
        .foregroundColor(.foreground)
        .monospacedDigit()
    }
  }

  private var headerActions: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack(spacing: Spacing.sm) {
        Button("Export All") { exportSheet = SheetToken() }
          .buttonStyle(PrimaryButtonStyle())
          .disabled(busy)
          .linkPointer()
        Button("Import", action: openImport)
          .buttonStyle(FilledSecondaryButtonStyle())
          .disabled(busy)
          .linkPointer()
        Button("Clear All") { clearSheet = SheetToken() }
          .buttonStyle(DangerButtonStyle())
          .disabled(busy)
          .linkPointer()
      }
      if let notice {
        Text(notice.text)
          .font(.bodyText)
          .foregroundColor(notice.isError ? .destructive : .success)
          .textSelection(.enabled)
      }
    }
  }

  private var secrets: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("Account names only. Credential contents stay in the Keychain until you delete them.")
        .font(.bodyText)
        .foregroundColor(.foregroundSubtle)

      if let error = model.error {
        Text(error)
          .font(.bodyText)
          .foregroundColor(.destructive)
          .textSelection(.enabled)
      }

      if model.secrets.isEmpty {
        Text("No saved credentials.")
          .font(.bodyText)
          .foregroundColor(.foregroundMuted)
      } else {
        ForEach(model.secrets) { item in
          HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
              Text(item.kind == .clientCertificate ? "Client certificate" : item.label)
                .font(.bodyText)
                .foregroundColor(.foreground)
              Text(
                item.kind == .clientCertificate
                  ? "Account: \(item.account)" : dataSecretKindTitle(item.kind)
              )
              .font(.bodyText)
              .foregroundColor(.foregroundSubtle)
            }
            Spacer(minLength: Spacing.sm)
            Button("Delete") { pendingSecret = item }
              .buttonStyle(DangerButtonStyle())
              .disabled(busy)
              .linkPointer()
          }
        }
      }
    }
  }

  private var clearIsPresented: Binding<Bool> {
    Binding(
      get: { pendingClear != nil },
      set: { if !$0 { pendingClear = nil } }
    )
  }

  private var secretIsPresented: Binding<Bool> {
    Binding(
      get: { pendingSecret != nil },
      set: { if !$0 { pendingSecret = nil } }
    )
  }

  private func confirmClear() {
    guard let category = pendingClear else { return }
    let token = model.prepareClear(category)
    Task { await model.clear(category, confirmed: token) }
  }

  private func export(_ category: LocalDataCategory) {
    let name = "\(category.title).dblorebackup"
    presentSavePanel(named: name) { url in
      await writeExport(category, to: url)
    }
  }

  private func writeExport(_ category: LocalDataCategory, to url: URL) async {
    let access = SecurityScopedAccessToken(url: url)
    defer { access.release() }
    busy = true
    defer { busy = false }
    do {
      try await model.export(category, to: url)
      notice = DataNotice(text: "Exported \(category.title).", isError: false)
    } catch {
      notice = DataNotice(text: dataBackupMessage(error), isError: true)
    }
  }

  /// Full selection uses `exportAll` so local models follow the checkbox (off by default).
  private func writeExportAll(_ selected: Set<LocalDataCategory>, to url: URL) async {
    let access = SecurityScopedAccessToken(url: url)
    defer { access.release() }
    busy = true
    defer { busy = false }
    let includeModels = selected.contains(.localModels)
    let others = selected.subtracting([.localModels])
    let availableOthers = Set(model.rows.map(\.category)).subtracting([.localModels])
    do {
      if others == availableOthers {
        try await model.exportAll(includeModels: includeModels, to: url)
      } else {
        var categories = LocalDataCategory.allCases.filter { others.contains($0) }
        if includeModels { categories.append(.localModels) }
        try await model.export(categories, to: url)
      }
      notice = DataNotice(text: "Export finished.", isError: false)
    } catch {
      notice = DataNotice(text: dataBackupMessage(error), isError: true)
    }
  }

  private func openImport() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.dbloreBackup]
    panel.allowsMultipleSelection = false
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.prompt = "Import"
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      let access = SecurityScopedAccessToken(url: url)
      Task { @MainActor in
        do {
          let manifest = try LocalDataBackup.inspect(url)
          importRequest = DataImportRequest(access: access, manifest: manifest)
          notice = nil
        } catch {
          access.release()
          notice = DataNotice(text: dataBackupMessage(error), isError: true)
        }
      }
    }
  }

  private func presentSavePanel(named name: String, write: @escaping @MainActor (URL) async -> Void)
  {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.dbloreBackup]
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false
    panel.nameFieldStringValue = name
    panel.prompt = "Export"
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      Task { @MainActor in
        await write(url)
      }
    }
  }
}

/// Production providers and the Keychain inventory. The test host does not open query history.
@MainActor
enum DataSettingsProduction {
  static let model = DataSettingsModel(
    providers: providers(), inventory: SecretInventoryFactory.makeDefault())

  private static func providers() -> [any LocalDataProvider] {
    let defaults = UserDefaults.standard
    let domain = Bundle.main.bundleIdentifier ?? "ace.thi.Dblore"
    var list: [any LocalDataProvider] = []
    if !SessionManager.isRunningAsTestHost {
      list.append(
        QueryHistoryLocalDataProvider(store: .shared, fileURL: queryHistoryFileURL))
    }
    let rest: [any LocalDataProvider] = [
      ConnectionHistoryLocalDataProvider(defaults: defaults, domainName: domain),
      RecentItemsLocalDataProvider(defaults: defaults, domainName: domain),
      OpenTabsLocalDataProvider(defaults: defaults, domainName: domain),
      SavedFiltersLocalDataProvider(defaults: defaults, domainName: domain),
      SchemaLayoutLocalDataProvider(defaults: defaults, domainName: domain),
      AIChatsLocalDataProvider(root: AIConversationStore.defaultRoot),
      AISettingsLocalDataProvider(defaults: defaults, domainName: domain),
      LocalModelsLocalDataProvider(root: LocalModelManager.defaultRoot),
      LogsLocalDataProvider(root: logsRoot),
      AppSettingsLocalDataProvider(defaults: defaults, domainName: domain),
    ]
    list.append(contentsOf: rest)
    return list
  }

  /// Same file `QueryHistoryStore.shared` opens.
  private static var queryHistoryFileURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Dblore", isDirectory: true)
      .appendingPathComponent("History.sqlite")
  }

  private static var logsRoot: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Dblore/Logs", isDirectory: true)
  }
}

/// Visual groups for Settings → Data. Every `LocalDataCategory` belongs to one group.
private enum DataSettingsGroup: CaseIterable {
  case history
  case workspace
  case assistant
  case app

  var title: String {
    switch self {
    case .history: "History"
    case .workspace: "Workspace"
    case .assistant: "Assistant"
    case .app: "App"
    }
  }

  var categories: [LocalDataCategory] {
    LocalDataCategory.allCases.filter { Self.group(of: $0) == self }
  }

  /// Exhaustive, so a new `LocalDataCategory` fails the build until it has a group.
  private static func group(of category: LocalDataCategory) -> DataSettingsGroup {
    switch category {
    case .queryHistory, .connectionHistory, .recentItems: .history
    case .openTabs, .savedFilters, .schemaLayout: .workspace
    case .aiChats, .aiSettings, .localModels: .assistant
    case .logs, .appSettings: .app
    }
  }
}

private struct SheetToken: Identifiable {
  let id = UUID()
}

private struct DataImportRequest: Identifiable {
  let id = UUID()
  let access: SecurityScopedAccessToken
  let manifest: BackupManifest
  var url: URL { access.url }
}

private struct DataNotice: Equatable {
  var text: String
  var isError: Bool
}

private func dataSecretKindTitle(_ kind: SecretKind) -> String {
  switch kind {
  case .dbPassword: "Database password"
  case .aiKey: "API key"
  case .chatGPTToken: "ChatGPT sign-in"
  case .safeModePassword: "Safe Mode password"
  case .clientCertificate: "Client certificate"
  }
}

private func dataBackupMessage(_ error: Error) -> String {
  guard let backup = error as? LocalDataBackupError else { return error.localizedDescription }
  switch backup {
  case .unsupportedVersion(let version):
    return "This backup uses format \(version), which this version of Dblore cannot read."
  case .missingCategory(let category):
    return "The backup is missing \(category.title)."
  case .corruptCategory(let category):
    return "The backup’s \(category.title) data is unreadable."
  case .missingProvider(let category):
    return "This app cannot restore \(category.title)."
  case .secretDetected:
    return "The backup was not written because it contained a saved password or key."
  }
}

/// Category checkboxes. Local models start unchecked and are labeled with their size.
private struct DataExportAllSheet: View {
  @Bindable var model: DataSettingsModel
  var onExport: (Set<LocalDataCategory>) -> Void
  var onCancel: () -> Void

  @State private var selected: Set<LocalDataCategory>

  init(
    model: DataSettingsModel,
    onExport: @escaping (Set<LocalDataCategory>) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.model = model
    self.onExport = onExport
    self.onCancel = onCancel
    _selected = State(
      initialValue: Set(model.rows.map(\.category).filter { $0 != .localModels }))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Export all")
          .font(.subheading)
          .foregroundColor(.foreground)
        Spacer()
        Button(action: onCancel) {
          Image(systemName: "xmark")
            .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(GhostButtonStyle(iconOnly: true))
        .help("Close")
      }
      .modalBarPadding(vertical: Spacing.sm)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.sm) {
          ForEach(model.rows) { row in
            Toggle(isOn: isOn(row.category)) {
              VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title(for: row))
                  .font(.bodyText)
                  .foregroundColor(.foreground)
                Text(row.category.description)
                  .font(.small)
                  .foregroundColor(.foregroundSubtle)
              }
            }
            .toggleStyle(.checkbox)
          }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      Divider()

      HStack {
        Spacer()
        Button("Cancel", action: onCancel)
          .buttonStyle(GhostButtonStyle())
        Button("Export") { onExport(selected) }
          .buttonStyle(PrimaryButtonStyle())
          .disabled(selected.isEmpty)
      }
      .modalBarPadding()
    }
    .frame(width: 480, height: 460)
    .background(Color.appBackground)
  }

  private func title(for row: DataSettingsRow) -> String {
    guard row.category == .localModels else { return row.category.title }
    let size = DataByteCount.text(row.summary?.bytes ?? 0)
    return "Include local AI models (\(size))"
  }

  private func isOn(_ category: LocalDataCategory) -> Binding<Bool> {
    Binding(
      get: { selected.contains(category) },
      set: { isSelected in
        if isSelected {
          selected.insert(category)
        } else {
          selected.remove(category)
        }
      }
    )
  }
}

/// Destructive confirm for every category, with a separate choice to delete Keychain items.
private struct DataClearAllSheet: View {
  @Bindable var model: DataSettingsModel
  var onFinished: () -> Void
  var onCancel: () -> Void

  @State private var alsoDeleteSecrets = false
  @State private var working = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Clear all local data?")
          .font(.subheading)
          .foregroundColor(.foreground)
        Spacer()
        Button(action: onCancel) {
          Image(systemName: "xmark")
            .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(GhostButtonStyle(iconOnly: true))
        .disabled(working)
        .help("Close")
      }
      .modalBarPadding(vertical: Spacing.sm)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.sm) {
          Text("This removes:")
            .font(.small)
            .foregroundColor(.foregroundMuted)
          VStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach(model.rows) { row in
              HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                Text("•")
                  .foregroundColor(.foregroundMuted)
                Text(row.category.title)
                  .foregroundColor(.foreground)
              }
              .font(.bodyText)
            }
          }
          .padding(.leading, Spacing.md)
          Toggle("Also delete saved credentials", isOn: $alsoDeleteSecrets)
            .toggleStyle(.checkbox)
            .font(.bodyText)
            .disabled(working)
          Text("Saved credentials are deleted only when that box is checked.")
            .font(.small)
            .foregroundColor(.foregroundSubtle)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      Divider()

      HStack {
        Spacer()
        Button("Cancel", action: onCancel)
          .buttonStyle(GhostButtonStyle())
          .disabled(working)
        Button("Clear All", action: confirm)
          .buttonStyle(DangerButtonStyle())
          .disabled(working)
      }
      .modalBarPadding()
    }
    .frame(width: 440, height: 420)
    .background(Color.appBackground)
  }

  private func confirm() {
    guard !working else { return }
    working = true
    let includeSecrets = alsoDeleteSecrets
    let token = model.prepareClearAll(includeSecrets: includeSecrets)
    Task {
      await model.clearAll(includeSecrets: includeSecrets, confirmed: token)
      working = false
      onFinished()
    }
  }
}
