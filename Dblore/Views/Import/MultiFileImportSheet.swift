import Foundation
import SwiftUI

/// Several CSV, TSV and JSON files, or a folder of them, into the tables of one schema in the
/// active tab: one summary, one Safe Mode decision and one transaction for every file.
struct MultiFileImportSheet: View {
  let viewModel: NotebookViewModel
  let model: MultiFileImportModel
  /// The table whose menu opened the import: a single file goes into it
  var table: DatabaseTable? = nil
  @Binding var isPresented: Bool
  @Binding var isBusy: Bool

  private static let contentEndAnchor = "multi-import-content-end"

  /// The file whose columns the one-file sheet edits in place of the list
  @State private var editedEntry: MultiFileImportEntry?
  @State private var didSubmit = false
  @State private var importTask: Task<Void, Never>?
  @State private var loadTask: Task<Void, Never>?

  var body: some View {
    VStack(spacing: 0) {
      if let editedEntry {
        TableImportSheet(
          viewModel: viewModel,
          isPresented: Binding(get: { true }, set: { if !$0 { endEdit(editedEntry) } }),
          isBusy: .constant(false), tables: model.tables, editedModel: editedEntry.model)
      } else {
        fileList
      }
    }
    .background(Color.cardBackground)
    // A table menu's import of one file goes into that table, whatever the file's name
    .onChange(of: model.entries.map(\.id)) { _, _ in preselectTable() }
    .onChange(of: isPresented) { _, presented in
      if !presented && !didSubmit { stop() }
    }
  }

  private var fileList: some View {
    VStack(spacing: 0) {
      GenericModalHeader(
        title: "Import Files", titleIcon: "square.and.arrow.down.on.square",
        onClose: { if !isBusy { isPresented = false } })
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: Spacing.lg) {
            filesSection
              .disabled(isBusy || model.isReviewing)
            if let progress = model.progress {
              // Same card as the summary, so the sheet does not jump when it arrives
              SettingsGroupCard(title: "Rows to import") {
                ImportLoadingRow(text: progressText(progress))
              }
            } else if model.isReviewing, let summary = model.summary {
              summarySection(summary)
            }
            if let error = model.errorMessage {
              Text(error)
                .font(.small)
                .foregroundColor(.destructive)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.md)
                .background(
                  Color.destructive.opacity(0.1),
                  in: RoundedRectangle(cornerRadius: CornerRadius.lg)
                )
                .overlay(
                  HairlineBorder(
                    shape: RoundedRectangle(cornerRadius: CornerRadius.lg),
                    color: .destructive.opacity(0.4))
                )
            }
          }
          .padding(Spacing.md)
          .frame(maxWidth: .infinity, alignment: .leading)
          .id(Self.contentEndAnchor)
        }
        .onChange(of: model.errorMessage) { _, message in
          guard message != nil else { return }
          withAnimation { proxy.scrollTo(Self.contentEndAnchor, anchor: .bottom) }
        }
        .onChange(of: model.progress != nil || model.isReviewing) { _, shows in
          guard shows else { return }
          withAnimation { proxy.scrollTo(Self.contentEndAnchor, anchor: .bottom) }
        }
      }
      .frame(maxHeight: .infinity)
      footer
    }
  }

  private var footer: some View {
    GenericModalFooter {
      Spacer()
      if model.isReviewing {
        // Nothing is written yet: Back returns to the list, Continue goes to Safe Mode
        Button("Back") { model.endReview() }
          .buttonStyle(FilledSecondaryButtonStyle())
          .disabled(isBusy)
        Button("Continue", action: continueImport)
          .buttonStyle(PrimaryButtonStyle())
          .disabled(model.notice != nil || isBusy)
      } else {
        Button("Cancel", action: cancel)
          .buttonStyle(FilledSecondaryButtonStyle())
          // The batch is with the tab: it runs to its end or its error
          .disabled(model.progress == .running)
        Button(action: startImport) {
          if isBusy {
            HStack(spacing: Spacing.sm) {
              ProgressView().controlSize(.mini)
              Text(model.progress == .running ? "Importing..." : "Reading files...")
            }
          } else {
            Text("Import")
          }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(!canImport)
      }
    }
  }

  // MARK: - Files

  private var filesSection: some View {
    SettingsGroupCard(title: "Files") {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        HStack(spacing: Spacing.sm) {
          Text(filesTitle)
            .font(.bodyText)
            .foregroundColor(model.entries.isEmpty ? .foregroundMuted : .foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
          Button("Choose Files") { chooseFiles() }
            .buttonStyle(FilledSecondaryButtonStyle())
            .disabled(model.isLoading)
        }
        Text(
          "Choose files or a folder: a folder adds its CSV, TSV and JSON files, not its "
            + "subfolders. Each file goes into the table named like it, or a new table."
        )
        .font(.small)
        .foregroundColor(.foregroundMuted)
        .fixedSize(horizontal: false, vertical: true)
        if model.isLoading && model.entries.isEmpty {
          ImportLoadingRow(text: "Listing files...")
        }
        ForEach(model.entries) { entry in
          Divider()
          entryRow(entry)
        }
      }
    }
  }

  private var filesTitle: String {
    let schema = model.schema.flatMap { $0.isEmpty ? nil : $0 }
    let into = schema.map { " into \($0)" } ?? ""
    guard !model.entries.isEmpty else { return "No files selected" }
    let included = model.includedEntries.count
    return "\(included) of \(model.entries.count) file\(model.entries.count == 1 ? "" : "s")"
      + into
  }

  private func entryRow(_ entry: MultiFileImportEntry) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack(spacing: Spacing.sm) {
        Toggle(
          "", isOn: Binding(get: { entry.isIncluded }, set: { entry.isIncluded = $0 })
        )
        .labelsHidden()
        .toggleStyle(.checkbox)
        .help("Include this file")
        Text(entry.displayName)
          .font(.bodyText)
          .foregroundColor(entry.isIncluded ? .foreground : .foregroundMuted)
          .lineLimit(1)
          .truncationMode(.middle)
          .frame(maxWidth: .infinity, alignment: .leading)
        Image(systemName: "arrow.right")
          .font(.small)
          .foregroundColor(.foregroundSubtle)
        CapsuleDropdown(
          title: destinationTitle(entry), width: 220,
          accessibilityLabel: "Destination of \(entry.displayName)",
          options: destinationOptions(entry), optionTitle: destinationLabel,
          isSelected: { entry.destinationChoiceReason == nil && $0 == entry.destination },
          onSelect: { selectDestination($0, for: entry) })
        Button("Edit") { editedEntry = entry }
          .buttonStyle(SecondaryButtonStyle())
          .disabled(entry.model.isLoading || entry.model.mappings.isEmpty)
          .help("Edit the columns of this file")
      }
      VStack(alignment: .leading, spacing: Spacing.sm) {
        if entry.model.isLoading {
          ImportLoadingRow(text: "Reading file...")
        } else if let error = entry.model.errorMessage {
          Text(error)
            .font(.small)
            .foregroundColor(.destructive)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let reason = entry.destinationChoiceReason {
          Text(reason)
            .font(.small)
            .foregroundColor(.warning)
            .fixedSize(horizontal: false, vertical: true)
        } else if !entry.destination.createsTable {
          existingRows(entry.model)
        }
      }
      // Under the file name, past the checkbox
      .padding(.leading, 24)
      .disabled(!entry.isIncluded)
    }
  }

  /// Mode and key of a file going into an existing table, as in the one-file sheet
  @ViewBuilder
  private func existingRows(_ file: TableImportModel) -> some View {
    CapsuleTabPicker(
      selection: Binding(get: { file.mode }, set: { file.selectMode($0) }),
      tabs: ImportMode.allCases, height: 26
    ) { mode in
      CapsuleTabLabel(text: TableImportSheet.modeTitle(mode), isSelected: file.mode == mode)
    }
    .fitsContent()
    .accessibilityLabel("Import mode")
    .disabled(file.offeredMatchKeys.isEmpty)
    if file.isLoadingMatchKeys {
      ImportLoadingRow(text: "Reading the keys of this table...")
    } else if let reason = file.keyedModesUnavailableReason {
      Text(reason)
        .font(.small)
        .foregroundColor(.foregroundMuted)
        .fixedSize(horizontal: false, vertical: true)
    } else if file.mode != .insert {
      HStack(spacing: Spacing.sm) {
        Text("Match rows on")
          .font(.small)
          .foregroundColor(.foregroundMuted)
        CapsuleDropdown(
          title: file.matchKey?.displayName ?? "Choose a key",
          accessibilityLabel: "Match key", options: file.offeredMatchKeys,
          optionTitle: \.displayName, isSelected: { $0 == file.matchKey },
          onSelect: { file.matchKey = $0 })
        Spacer()
      }
    }
  }

  /// A new table named like the file (unless a table has that name ignoring case, which the
  /// new one would collide with on case-insensitive databases), then the schema's tables by name
  private func destinationOptions(_ entry: MultiFileImportEntry) -> [TableImportDestination] {
    let name = entry.url.deletingPathExtension().lastPathComponent
    let tables = model.tables
      .filter { table in model.schema.map { $0 == table.schema } ?? true }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    let existing = tables.map { TableImportDestination.existing(schema: $0.schema, table: $0.name) }
    guard !tables.contains(where: { $0.name.lowercased() == name.lowercased() }) else {
      return existing
    }
    return [.new(schema: model.schema, table: name)] + existing
  }

  private func destinationLabel(_ destination: TableImportDestination) -> String {
    destination.createsTable ? "New table \(destination.table)" : destination.table
  }

  private func destinationTitle(_ entry: MultiFileImportEntry) -> String {
    entry.destinationChoiceReason == nil ? destinationLabel(entry.destination) : "Choose a table"
  }

  // MARK: - Summary

  /// Every file's counts before Safe Mode, with its refused rows and notice, and the totals
  private func summarySection(_ summary: MultiFileImportSummary) -> some View {
    SettingsGroupCard(title: "Rows to import") {
      VStack(alignment: .leading, spacing: Spacing.md) {
        let totals = summary.totals
        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text(
            "\(totals.inserts.formatted()) to insert, \(totals.updates.formatted()) to update, "
              + "\(totals.skips.formatted()) to skip, \(totals.refused.formatted()) refused"
          )
          .font(.bodyText)
          .foregroundColor(.foreground)
          Text(
            "\(summary.files.count) file\(summary.files.count == 1 ? "" : "s") in one "
              + "transaction. Refused rows are not written."
          )
          .font(.small)
          .foregroundColor(.foregroundMuted)
        }
        ForEach(summary.files.indices, id: \.self) { index in
          fileSummary(summary.files[index])
        }
        if let warning = model.implicitCommitWarning {
          Label(warning, systemImage: "exclamationmark.triangle")
            .font(.small)
            .foregroundColor(.warning)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let notice = model.notice {
          Text(notice)
            .font(.small)
            .foregroundColor(.foreground)
        } else {
          Text(
            "Nothing is written yet. Continue to import these files, or go back to change them."
          )
          .font(.small)
          .foregroundColor(.foregroundMuted)
        }
      }
    }
  }

  private func fileSummary(_ file: MultiFileImportFileSummary) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(
        "\(file.file) into "
          + (file.destination.createsTable
            ? "new table \(file.destination.table)" : file.destination.table)
      )
      .font(.small.weight(.medium))
      .foregroundColor(.foreground)
      .lineLimit(1)
      .truncationMode(.middle)
      let counts = file.counts
      Text(
        "\(counts.inserts.formatted()) to insert, \(counts.updates.formatted()) to update, "
          + "\(counts.skips.formatted()) to skip, \(counts.refused.formatted()) refused"
      )
      .font(.small)
      .foregroundColor(.foregroundMuted)
      if let match = file.match, !match.refused.isEmpty {
        ScrollView {
          VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(match.refused.indices, id: \.self) { index in
              let refusal = match.refused[index]
              Text("Row \(refusal.row.formatted()): \(refusal.reason)")
                .font(.small)
                .foregroundColor(.foreground)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .padding(Spacing.sm)
        }
        .frame(maxHeight: 100)
        .background(Color.appBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
        if match.refusedCount > match.refused.count {
          Text(
            "Showing the first \(match.refused.count.formatted()) of "
              + "\(match.refusedCount.formatted()) refused rows."
          )
          .font(.small)
          .foregroundColor(.foregroundMuted)
        }
      }
      if let notice = file.notice {
        Text(notice)
          .font(.small)
          .foregroundColor(.foreground)
      }
    }
  }

  private func progressText(_ progress: MultiFileImportProgress) -> String {
    switch progress {
    case .preparing(let file, let count): "Reading file \(file) of \(count)..."
    case .running: "Importing..."
    }
  }

  // MARK: - Actions

  private var canImport: Bool {
    let included = model.includedEntries
    return !included.isEmpty && !model.isLoading && !isBusy
      && included.allSatisfy { entry in
        let file = entry.model
        return entry.destinationChoiceReason == nil && !file.isLoading
          && !file.isLoadingMatchKeys && (file.mode == .insert || file.matchKey != nil)
      }
  }

  /// Lists the picked files and reads their previews, then the keys of the existing tables
  private func chooseFiles() {
    loadTask?.cancel()
    loadTask = Task {
      await model.pickFiles()
      guard !Task.isCancelled, let manager = viewModel.connectionManager else { return }
      await model.loadMatchKeys { try await manager.fetchTableStructure(schema: $0, table: $1) }
    }
  }

  private func preselectTable() {
    guard let table, model.entries.count == 1, let entry = model.entries.first else { return }
    entry.setDestination(.existing(schema: table.schema, table: table.name))
  }

  /// The file's table changed: its keys load again (only this file's)
  private func selectDestination(
    _ destination: TableImportDestination, for entry: MultiFileImportEntry
  ) {
    entry.setDestination(destination)
    guard let manager = viewModel.connectionManager else { return }
    Task {
      await entry.model.loadMatchKeys {
        try await manager.fetchTableStructure(schema: $0, table: $1)
      }
    }
  }

  /// Back from Edit: the mapping may have dropped a key column
  private func endEdit(_ entry: MultiFileImportEntry) {
    entry.model.syncMatchChoice()
    editedEntry = nil
  }

  /// Reads every included file and matches its rows. Writes nothing: the summary waits for
  /// Continue or Back.
  private func startImport() {
    isBusy = true
    importTask = Task {
      _ = await model.prepareImport(for: viewModel)
      isBusy = false
      importTask = nil
    }
  }

  /// The one Safe Mode decision, then every file in one transaction. The sheet closes once the
  /// tab takes the batch.
  private func continueImport() {
    isBusy = true
    importTask = Task {
      if await model.confirmImport(to: viewModel) {
        didSubmit = true
        isBusy = false
        isPresented = false
      } else {
        isBusy = false
      }
      importTask = nil
    }
  }

  private func cancel() {
    guard model.progress != .running else { return }
    stop()
    isBusy = false
    isPresented = false
  }

  private func stop() {
    importTask?.cancel()
    loadTask?.cancel()
    model.cancel()
  }
}
