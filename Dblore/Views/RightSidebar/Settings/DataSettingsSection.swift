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
  @State private var exportTask: Task<Void, Never>?
  @State private var showsExportProgress = false

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
            writeExportAll(chosen, to: url)
          }
        }
      } onCancel: {
        exportSheet = nil
      }
    }
    .sheet(isPresented: $showsExportProgress) {
      DataExportProgressSheet(model: model) { exportTask?.cancel() }
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
          WorkspaceWindowManager.shared.showToast("Import finished.", type: .success)
        },
        onFailed: { message in
          request.access.release()
          importRequest = nil
          WorkspaceWindowManager.shared.showToast(message, type: .error)
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
      "\(clearVerb) \(pendingClear?.title ?? "data")?",
      isPresented: clearIsPresented,
      titleVisibility: .visible
    ) {
      Button(clearVerb, role: .destructive) { confirmClear() }
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
      switch item.kind {
      case .clientCertificate:
        Text("Deletes the saved client certificate and private key for account \(item.account).")
      case .sshCredential:
        Text("Deletes the saved SSH password or private key for account \(item.account).")
      case .sshHostKey:
        Text("Forgets the trusted SSH host key for account \(item.account).")
      default:
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
              Text(showsKindFirst(item) ? dataSecretKindTitle(item.kind) : item.label)
                .font(.bodyText)
                .foregroundColor(.foreground)
              Text(
                showsKindFirst(item)
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

  /// Accounts of these kinds are encoded identities, so the kind is the readable title.
  private func showsKindFirst(_ item: SecretItem) -> Bool {
    [.clientCertificate, .sshCredential, .sshHostKey].contains(item.kind)
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

  /// The Data Rewind row's button says "Delete", so its dialog does too
  private var clearVerb: String {
    pendingClear == .dataRewind ? "Delete" : "Clear"
  }

  private func confirmClear() {
    guard let category = pendingClear else { return }
    let token = model.prepareClear(category)
    Task { await model.clear(category, confirmed: token) }
  }

  private func export(_ category: LocalDataCategory) {
    let name = "\(category.title).dblorebackup"
    presentSavePanel(named: name) { url in
      runExport(to: url, finished: "Exported \(category.title).") {
        try await model.export(category, to: url)
      }
    }
  }

  /// Full selection uses `exportAll` so local models follow the checkbox (off by default).
  /// Categories a backup never holds (Data Rewind) are not offered.
  private func writeExportAll(_ selected: Set<LocalDataCategory>, to url: URL) {
    let includeModels = selected.contains(.localModels)
    let others = selected.subtracting([.localModels])
    let availableOthers = Set(model.rows.map(\.category).filter { !$0.isExcludedFromBackup })
      .subtracting([.localModels])
    runExport(to: url, finished: "Export finished.") {
      if others == availableOthers {
        try await model.exportAll(includeModels: includeModels, to: url)
      } else {
        var categories = LocalDataCategory.allCases.filter { others.contains($0) }
        if includeModels { categories.append(.localModels) }
        try await model.export(categories, to: url)
      }
    }
  }

  /// Runs an export that the progress sheet can cancel. The sheet waits a moment so a quick
  /// export does not flash it. Success and cancel toast; an error stays under the buttons.
  private func runExport(
    to url: URL, finished: String, work: @escaping @MainActor () async throws -> Void
  ) {
    let access = SecurityScopedAccessToken(url: url)
    busy = true
    notice = nil
    exportTask = Task {
      let reveal = Task {
        try? await Task.sleep(for: .milliseconds(300))
        if !Task.isCancelled { showsExportProgress = true }
      }
      var failure: Error?
      do {
        try await work()
      } catch {
        failure = error
      }
      // Close the progress sheet first so it does not cover the toast
      reveal.cancel()
      showsExportProgress = false
      if let failure {
        if Task.isCancelled {
          WorkspaceWindowManager.shared.showToast("Export cancelled.", type: .info)
        } else {
          notice = DataNotice(text: failure.localizedDescription, isError: true)
        }
      } else {
        WorkspaceWindowManager.shared.showToast(finished, type: .success)
      }
      access.release()
      busy = false
      exportTask = nil
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
          notice = DataNotice(text: error.localizedDescription, isError: true)
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
      list.append(
        DataRewindLocalDataProvider(store: RewindStore.shared, fileURL: RewindStore.defaultURL))
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
enum DataSettingsGroup: CaseIterable {
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
    case .queryHistory, .dataRewind, .connectionHistory, .recentItems: .history
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
  case .sshCredential: "SSH credentials"
  case .sshHostKey: "Trusted SSH host keys"
  }
}

/// Category checkboxes. Local models start unchecked and are labeled with their size.
/// Categories a backup never holds are left out.
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
      initialValue: Set(
        model.rows.map(\.category).filter { $0 != .localModels && !$0.isExcludedFromBackup }))
  }

  private var rows: [DataSettingsRow] {
    model.rows.filter { !$0.category.isExcludedFromBackup }
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
          ForEach(rows) { row in
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

/// Shown while an export runs: the current step, a bar over all steps, and Cancel.
/// Cancel stops after the step in progress and deletes the partial package.
private struct DataExportProgressSheet: View {
  var model: DataSettingsModel
  var onCancel: () -> Void

  @State private var cancelling = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Exporting")
        .font(.subheading)
        .foregroundColor(.foreground)
        .modalBarPadding(vertical: Spacing.sm)

      Divider()

      VStack(alignment: .leading, spacing: Spacing.sm) {
        ProgressView(value: fraction)
          .progressViewStyle(.linear)
        Text(stepText)
          .font(.bodyText)
          .foregroundColor(.foregroundSubtle)
          .lineLimit(1)
      }
      .padding(Spacing.md)
      .frame(maxWidth: .infinity, alignment: .leading)

      Divider()

      HStack {
        Spacer()
        Button(cancelling ? "Cancelling…" : "Cancel") {
          cancelling = true
          onCancel()
        }
        .buttonStyle(GhostButtonStyle())
        .disabled(cancelling)
        .keyboardShortcut(.cancelAction)
      }
      .modalBarPadding()
    }
    .frame(width: 400)
    .background(Color.appBackground)
    .interactiveDismissDisabled()
  }

  private var fraction: Double {
    guard let progress = model.exportProgress, progress.total > 0 else { return 0 }
    return Double(progress.completed) / Double(progress.total)
  }

  private var stepText: String {
    if cancelling { return "Stopping after the current step…" }
    guard let progress = model.exportProgress else { return "Finishing…" }
    guard let category = progress.category else { return "Checking the backup for secrets…" }
    return "\(category.title) (\(progress.completed + 1) of \(progress.total - 1))"
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
