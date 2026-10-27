//
//  DataImportSheet.swift
//  Dblore
//
//  Manifest summary, category choice, and a confirmed replace import.
//

import SwiftUI

/// Shown after the open panel. Import replaces the selected categories.
struct DataImportSheet: View {
  let url: URL
  let manifest: BackupManifest
  @Bindable var model: DataSettingsModel
  var onCancel: () -> Void
  var onImported: () -> Void
  /// Called with the message when the import fails; the caller closes the sheet and toasts it.
  var onFailed: (String) -> Void

  @State private var selected: Set<LocalDataCategory>
  @State private var working = false
  @Environment(\.pixelLength) private var pixelLength

  init(
    url: URL,
    manifest: BackupManifest,
    model: DataSettingsModel,
    onCancel: @escaping () -> Void,
    onImported: @escaping () -> Void,
    onFailed: @escaping (String) -> Void
  ) {
    self.url = url
    self.manifest = manifest
    self.model = model
    self.onCancel = onCancel
    self.onImported = onImported
    self.onFailed = onFailed
    let known = manifest.categories.compactMap { LocalDataCategory(rawValue: $0.id) }
      .filter { !$0.isExcludedFromBackup }
    _selected = State(initialValue: Set(known))
  }

  /// Known categories a backup may hold. A hand-made package listing Data Rewind shows nothing.
  private var entries: [BackupManifest.Category] {
    manifest.categories.filter {
      guard let category = LocalDataCategory(rawValue: $0.id) else { return false }
      return !category.isExcludedFromBackup
    }
  }

  private var versionOK: Bool { manifest.formatVersion == LocalDataBackup.formatVersion }

  private var orderedSelection: [LocalDataCategory] {
    LocalDataCategory.allCases.filter { selected.contains($0) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Import backup")
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
        VStack(alignment: .leading, spacing: Spacing.md) {
          summary
          if versionOK {
            categories
          } else {
            Text(
              "This backup uses format \(manifest.formatVersion), which this version cannot read."
            )
            .font(.small)
            .foregroundColor(.destructive)
          }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      Divider()

      VStack(alignment: .leading, spacing: Spacing.sm) {
        HStack(alignment: .top, spacing: Spacing.xs) {
          Image(systemName: "exclamationmark.triangle.fill")
          Text("Replaces current data")
        }
        .font(.small)
        .foregroundColor(.warning)
        if replacesLocks {
          Text(DataSettingsWarnings.importLocks)
            .font(.small)
            .foregroundColor(.warning)
        }

        HStack {
          Spacer()
          Button("Cancel", action: onCancel)
            .buttonStyle(GhostButtonStyle())
            .disabled(working)
          Button("Import", action: importSelected)
            .buttonStyle(PrimaryButtonStyle())
            .disabled(working || !versionOK || orderedSelection.isEmpty)
        }
      }
      .modalBarPadding()
    }
    .frame(width: 480, height: 460)
    .background(Color.appBackground)
  }

  /// Connection rows and Recents carry the locks; app settings the relock timeout
  private var replacesLocks: Bool {
    !selected.isDisjoint(with: [.connectionHistory, .recentItems, .appSettings])
  }

  private var summary: some View {
    VStack(alignment: .leading, spacing: Spacing.xxs) {
      Text(url.lastPathComponent)
        .font(.bodyText)
        .foregroundColor(.foreground)
      Text(
        "\(DataByteCount.items(entries.reduce(0) { $0 + $1.itemCount })) · \(DataByteCount.text(entries.reduce(0) { $0 + $1.byteSize }))"
      )
      .font(.monoSmall)
      .foregroundColor(.foregroundMuted)
      .monospacedDigit()
      Text("App \(manifest.appVersion) · \(manifest.created)")
        .font(.small)
        .foregroundColor(.foregroundSubtle)
    }
    .padding(Spacing.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    // Own box, so the file details read apart from the category list
    .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: CornerRadius.md))
    .overlay(
      RoundedRectangle(cornerRadius: CornerRadius.md)
        .strokeBorder(Color.border, lineWidth: pixelLength)
    )
  }

  private var categories: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      ForEach(entries, id: \.id) { entry in
        if let category = LocalDataCategory(rawValue: entry.id) {
          Toggle(isOn: isOn(category)) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
              Text(category.title)
                .font(.bodyText)
                .foregroundColor(.foreground)
              Text(
                "\(DataByteCount.text(entry.byteSize)) · \(DataByteCount.items(entry.itemCount))"
              )
              .font(.monoSmall)
              .foregroundColor(.foregroundMuted)
              .monospacedDigit()
            }
          }
          .toggleStyle(.checkbox)
          .disabled(working)
        }
      }
    }
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

  private func importSelected() {
    guard !working else { return }
    let categories = orderedSelection
    guard !categories.isEmpty else { return }
    working = true
    let token = model.prepareImport(url: url, selected: categories)
    Task {
      let results = await model.importBackup(url: url, selected: categories, confirmed: token)
      working = false
      if !results.isEmpty, results.allSatisfy(\.succeeded) {
        onImported()
        return
      }
      let failed = Set(results.filter { !$0.succeeded }.map(\.category))
      onFailed(model.rows.first { failed.contains($0.category) }?.error ?? "Import failed.")
    }
  }
}
