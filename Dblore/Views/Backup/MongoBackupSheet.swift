import Foundation
import SwiftUI

/// Back Up Database (MongoDB) in the right side panel: the collections and views of the
/// connection's database (all chosen by default), then a save panel (`<db>-<date>.ndjson`), then
/// the backup with progress and Cancel. `MongoBackupModel` reads and writes; the presenter
/// refuses to close the panel while it works (Cancel stops it, no partial file is left).
struct MongoBackupSheet: View {
  let model: MongoBackupModel
  /// Collections of the database (sidebar list)
  let collections: [String]
  /// Views of the database (sidebar list)
  let views: [String]
  @Binding var isPresented: Bool

  @State private var selected: Set<String>

  init(
    model: MongoBackupModel, collections: [String], views: [String], isPresented: Binding<Bool>
  ) {
    self.model = model
    self.collections = collections
    self.views = views
    _isPresented = isPresented
    _selected = State(initialValue: Set(collections + views))
  }

  private var names: [String] { collections + views }

  private var isRunning: Bool {
    if case .backingUp = model.state { true } else { false }
  }

  var body: some View {
    VStack(spacing: 0) {
      GenericModalHeader(
        title: "Back Up Database", titleIcon: "square.and.arrow.up", onClose: close)
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.lg) {
          collectionsSection
          fileSection
          progressSection
          messageSection
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: .infinity)
      GenericModalFooter {
        Spacer()
        Button(isRunning ? "Cancel" : "Close") {
          if isRunning {
            model.cancel()
          } else {
            close()
          }
        }
        .buttonStyle(FilledSecondaryButtonStyle())
        .disabled(model.choosingFile || model.cancelRequested)
        Button(action: start) {
          if isRunning {
            HStack(spacing: Spacing.sm) {
              ProgressView().controlSize(.mini)
              Text("Backing Up...")
            }
          } else {
            Text("Back Up...")
          }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(model.isBusy || selectedNames.isEmpty)
      }
    }
    .background(Color.cardBackground)
  }

  // MARK: - Sections

  private var collectionsSection: some View {
    SettingsGroupCard(title: "Collections and Views") {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        if names.isEmpty {
          Text("\(model.database) has no collection.")
            .font(.small)
            .foregroundColor(.foregroundMuted)
        } else {
          HStack(spacing: Spacing.sm) {
            Text("\(selectedNames.count) of \(names.count) selected")
              .font(.small)
              .foregroundColor(.foregroundMuted)
            Spacer()
            Button("Select All") { selected = Set(names) }
              .buttonStyle(GhostButtonStyle())
            Button("Select None") { selected = [] }
              .buttonStyle(GhostButtonStyle())
          }
          ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.xs) {
              ForEach(collections, id: \.self) { name in
                row(name, isView: false)
              }
              ForEach(views, id: \.self) { name in
                row(name, isView: true)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: 220)
        }
        Text(
          "A view is saved as its definition only. A view whose source is left out restores "
            + "only into a database that has that source."
        )
        .font(.small)
        .foregroundColor(.foregroundMuted)
        .fixedSize(horizontal: false, vertical: true)
      }
      .disabled(model.isBusy)
    }
  }

  private var fileSection: some View {
    SettingsGroupCard(title: "File") {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        Text(verbatim: MongoBackupModel.backupFileName(database: model.database, date: Date()))
          .font(.monoSmall)
          .foregroundColor(.foreground)
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
        Text(
          "One NDJSON file of Extended JSON: the collections with their options, indexes and "
            + "validators, the views, then every document. It holds your data as plain text: "
            + "keep the file somewhere safe. Restore it with File > Restore Backup."
        )
        .font(.small)
        .foregroundColor(.foregroundMuted)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  @ViewBuilder
  private var progressSection: some View {
    if case .backingUp(let progress) = model.state {
      VStack(alignment: .leading, spacing: Spacing.xs) {
        ProgressView(
          value: progress.collectionsTotal == 0
            ? nil : Double(progress.collectionsDone) / Double(progress.collectionsTotal)
        )
        .accessibilityLabel("Backup progress")
        Text(
          model.cancelRequested
            ? "Stopping..."
            : progress.collectionsTotal == 0
              ? "Reading the collections..."
              : "\(progress.collectionsDone) of \(progress.collectionsTotal) collections, "
                + "\(progress.documentsWritten.formatted()) documents"
        )
        .font(.monoSmall)
        .foregroundColor(.foregroundMuted)
      }
    }
  }

  @ViewBuilder
  private var messageSection: some View {
    switch model.state {
    case .done(let message): BackupMessageBox(text: message, isError: false)
    case .failed(let message): BackupMessageBox(text: message, isError: true)
    case .cancelled(let message): BackupMessageBox(text: message, isError: false)
    case .idle, .reading, .backingUp, .confirming, .restoring: EmptyView()
    }
  }

  // MARK: - Helpers

  /// The chosen names in list order (collections, then views)
  private var selectedNames: [String] {
    names.filter(selected.contains)
  }

  private func row(_ name: String, isView: Bool) -> some View {
    Toggle(
      isOn: Binding(
        get: { selected.contains(name) },
        set: { if $0 { selected.insert(name) } else { selected.remove(name) } })
    ) {
      HStack(spacing: Spacing.xs) {
        Text(verbatim: name)
          .font(.monoMedium)
          .foregroundColor(.foreground)
          .lineLimit(1)
          .truncationMode(.middle)
        if isView { CollectionFlagBadge(text: "view") }
      }
    }
    .toggleStyle(.checkbox)
  }

  private func start() {
    let names = selectedNames
    Task { await model.backUp(names: names) }
  }

  private func close() {
    guard !model.isBusy else { return }
    isPresented = false
  }
}
