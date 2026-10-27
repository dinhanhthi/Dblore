import Foundation
import SwiftUI

/// CSV, TSV, and JSON import into a new or existing table in the active tab.
struct TableImportSheet: View {
  let viewModel: NotebookViewModel
  @Binding var isPresented: Bool
  @Binding var isBusy: Bool
  var initialURL: URL? = nil
  var initialDestination: TableImportDestination? = nil
  /// Loaded schema tables. Existing-table column types decide SQLite boolean casts.
  var tables: [DatabaseTable] = []
  /// A file of a multi-file import: the sheet edits its columns, format and mode. Its file and
  /// table stay the file list's choice, and Done goes back to the list (nothing is imported here).
  var editedModel: TableImportModel? = nil

  private static let contentEndAnchor = "import-content-end"

  @State private var ownModel = TableImportModel()
  @State private var previewWidth: CGFloat = 0
  @State private var previewContentHeight: CGFloat = 0
  @State private var createsNewTable = true
  @State private var didSubmit = false
  @State private var importTask: Task<Void, Never>?
  @State private var isCancelling = false
  /// The first key load runs at once; later ones wait for typing in the table name to pause
  @State private var keysDebounce: Duration = .zero

  private let formats: [TableImportFormat] = [.csv, .tsv, .json]
  private let modes = ImportMode.allCases
  private let kinds: [ImportTypeInference.Kind] = [
    .integer, .decimal, .boolean, .date, .timestamp, .text,
  ]
  /// Row and cell caps. JSONRowsReader uses the same defaults.
  private let limits = DelimitedTextReader.Options()

  /// Width of the right sidebar the import opens in (the preview table needs room)
  static let panelWidth: CGFloat = 760

  private var model: TableImportModel { editedModel ?? ownModel }

  var body: some View {
    VStack(spacing: 0) {
      GenericModalHeader(
        title: editedModel == nil ? "Import Data" : "Edit File",
        titleIcon: "square.and.arrow.down",
        onClose: { if !isBusy { isPresented = false } })
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: Spacing.lg) {
            fileSection
            if model.fileURL != nil {
              formatSection
                .disabled(model.isReviewingMatches)
              previewSection
              mappingSection
                .disabled(model.isReviewingMatches)
              destinationSection
                .disabled(isBusy || model.isReviewingMatches || editedModel != nil)
              if !createsNewTable {
                existingRowsSection
                  .disabled(isBusy || model.isReviewingMatches)
              }
              sqlSection
              if model.isMatchingRows {
                // Same card as the summary, so the sheet does not jump when the counts arrive
                SettingsGroupCard(title: "Rows to import") {
                  ImportLoadingRow(text: "Checking which rows already exist...")
                }
              } else if model.isReviewingMatches, let summary = model.matchSummary {
                summarySection(summary)
              }
            }
            if model.isLoading || model.isImporting {
              // Indeterminate while the database runs the batch: there is no per-row progress
              ProgressView(value: model.isExecutingBatch ? nil : model.progress)
                .accessibilityLabel("Import progress")
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
          // Anchor on the padded content so the scroll ends below the bottom padding
          .id(Self.contentEndAnchor)
        }
        .onChange(of: model.errorMessage) { _, message in
          guard message != nil else { return }
          withAnimation { proxy.scrollTo(Self.contentEndAnchor, anchor: .bottom) }
        }
        // The progress bar sits below the form; bring it into view once the import starts
        .onChange(of: model.isImporting) { _, importing in
          guard importing else { return }
          withAnimation { proxy.scrollTo(Self.contentEndAnchor, anchor: .bottom) }
        }
        .onChange(of: model.isReviewingMatches) { _, reviewing in
          guard reviewing else { return }
          withAnimation { proxy.scrollTo(Self.contentEndAnchor, anchor: .bottom) }
        }
      }
      .frame(maxHeight: .infinity)
      GenericModalFooter {
        Spacer()
        if editedModel != nil {
          Button("Done") { isPresented = false }
            .buttonStyle(PrimaryButtonStyle())
        } else if model.isReviewingMatches {
          // Nothing is written yet: Back returns to the form, Continue goes to Safe Mode
          Button("Back") { model.endMatchReview() }
            .buttonStyle(FilledSecondaryButtonStyle())
          Button("Continue", action: continueImport)
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.notice != nil || isBusy)
        } else {
          Button("Cancel", action: cancelImport)
            .buttonStyle(FilledSecondaryButtonStyle())
            .disabled(isCancelling)
          Button(action: importFile) {
            if isBusy {
              HStack(spacing: Spacing.sm) {
                ProgressView().controlSize(.mini)
                Text(model.isMatchingRows ? "Checking rows..." : "Importing...")
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
    .background(Color.cardBackground)
    .onAppear {
      model.tables = tables
      if editedModel != nil { createsNewTable = model.destination.createsTable }
      if let initialDestination {
        model.destination = initialDestination
        createsNewTable = initialDestination.createsTable
      }
      if let initialURL { Task { await model.loadFile(initialURL) } }
    }
    // A new destination reloads its keys; `.task(id:)` cancels the load of the previous one
    .task(id: model.destination) { await loadMatchKeys() }
    .onChange(of: model.mappings) { _, _ in model.syncMatchChoice() }
    .onChange(of: isPresented) { _, presented in
      if !presented && !didSubmit && editedModel == nil { model.cancel() }
    }
  }

  private var fileSection: some View {
    SettingsGroupCard(title: "File") {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        HStack(spacing: Spacing.sm) {
          Text(model.fileURL?.lastPathComponent ?? "No file selected")
            .font(.bodyText)
            .foregroundColor(model.fileURL == nil ? .foregroundMuted : .foreground)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
          if editedModel == nil {
            Button("Choose File") { Task { await model.pickFile() } }
              .buttonStyle(FilledSecondaryButtonStyle())
              .disabled(model.isLoading || model.isImporting)
          }
        }
        if let size = fileSize {
          Text(DataByteCount.text(Int64(size)))
            .font(.monoSmall)
            .foregroundColor(.foregroundMuted)
          if size > 200 * 1_024 * 1_024 {
            Label(
              "Large files may take longer to import (over 200 MB)",
              systemImage: "exclamationmark.triangle"
            )
            .font(.small)
            .foregroundColor(.warning)
          }
          Text("Maximum import file size: 256 MB. Split larger files before importing.")
            .font(.small)
            .foregroundColor(.foregroundMuted)
          Text(
            "Up to \(limits.maxRows.formatted()) rows and \(limits.maxCells.formatted()) cells. "
              + "Column types are inferred from the first 100 rows."
          )
          .font(.small)
          .foregroundColor(.foregroundMuted)
        }
      }
    }
  }

  private var formatSection: some View {
    SettingsGroupCard(title: "Format") {
      HStack(spacing: Spacing.lg) {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          CapsulePickerMenu(
            title: ["CSV", "TSV", "JSON / NDJSON"][formatSelection.wrappedValue], width: 170
          ) {
            Picker("Format", selection: formatSelection) {
              Text("CSV").tag(0)
              Text("TSV").tag(1)
              Text("JSON / NDJSON").tag(2)
            }
            .pickerStyle(.inline)
            .labelsHidden()
          }
          .accessibilityLabel("Format")
        }
        if model.format != .json {
          Toggle("First row is a header", isOn: headerSelection)
            .toggleStyle(.checkbox)
            .font(.small)
        }
        Spacer()
      }
    }
  }

  private var previewSection: some View {
    SettingsGroupCard(title: "Preview (first 100 rows)") {
      if model.mappings.isEmpty {
        Text(model.isLoading ? "Reading file..." : "No rows to preview")
          .font(.small)
          .foregroundColor(.foregroundMuted)
      } else {
        ScrollView([.horizontal, .vertical]) {
          VStack(alignment: .leading, spacing: 0) {
            previewRow(model.mappings.map(\.sourceName), header: true)
            ForEach(model.previewRows.indices, id: \.self) { index in
              previewRow(
                model.previewRows[index].map { previewText($0) }, header: false)
            }
          }
          .onGeometryChange(for: CGFloat.self) {
            $0.size.height
          } action: {
            previewContentHeight = $0
          }
          // A scroll view centers content narrower than itself; pin it to the leading edge
          .frame(minWidth: previewWidth, alignment: .topLeading)
        }
        .onGeometryChange(for: CGFloat.self) {
          $0.size.width
        } action: {
          previewWidth = $0
        }
        .frame(height: min(max(previewContentHeight, 1), 172))
        .background(Color.appBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
        .overlay(HairlineBorder(shape: RoundedRectangle(cornerRadius: CornerRadius.md)))
      }
    }
  }

  /// Blank cells are bound as NULL on import, so the preview shows them as NULL.
  private func previewText(_ value: String?) -> String {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return "NULL"
    }
    return value
  }

  private func previewRow(_ values: [String], header: Bool) -> some View {
    HStack(spacing: 0) {
      ForEach(values.indices, id: \.self) { index in
        Text(values[index])
          .font(.monoSmall)
          .foregroundColor(header ? .foreground : .foregroundMuted)
          .lineLimit(1)
          .textSelection(.enabled)
          .frame(width: 170, alignment: .leading)
          .padding(.horizontal, Spacing.sm)
          .padding(.vertical, Spacing.xs)
          .overlay(alignment: .trailing) { Rectangle().fill(Color.border).frame(width: 1) }
      }
    }
    .background(header ? Color.cardHeaderBackground : Color.clear)
    .overlay(alignment: .bottom) { Rectangle().fill(Color.border).frame(height: 1) }
  }

  private var mappingSection: some View {
    SettingsGroupCard(title: "Columns") {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        ForEach(model.mappings.indices, id: \.self) { index in
          HStack(spacing: Spacing.sm) {
            Toggle("", isOn: mappingIncluded(index))
              .labelsHidden()
              .toggleStyle(.checkbox)
              .help("Include this column")
            Text(model.mappings[index].sourceName)
              .font(.small)
              .foregroundColor(.foregroundMuted)
              .lineLimit(1)
              .frame(width: 160, alignment: .leading)
            Image(systemName: "arrow.right")
              .font(.small)
              .foregroundColor(.foregroundSubtle)
            TextField("Destination column", text: mappingName(index))
              .textFieldStyle(.plain)
              .inputCapsuleStyle()
              .disabled(!model.mappings[index].included)
            CapsulePickerMenu(
              title: kinds.indices.contains(mappingKind(index).wrappedValue)
                ? kindLabel(kinds[mappingKind(index).wrappedValue]) : "", width: 125
            ) {
              Picker("Type", selection: mappingKind(index)) {
                ForEach(kinds.indices, id: \.self) { kindIndex in
                  Text(kindLabel(kinds[kindIndex])).tag(kindIndex)
                }
              }
              .pickerStyle(.inline)
              .labelsHidden()
            }
            .accessibilityLabel("Type")
            .disabled(!model.mappings[index].included)
          }
          if missingColumns.contains(index) {
            Text("Column \"\(model.mappings[index].targetName)\" does not exist in the table")
              .font(.small)
              .foregroundColor(.destructive)
          }
        }
      }
    }
  }

  private var destinationSection: some View {
    SettingsGroupCard(title: "Destination") {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        CapsuleTabPicker(selection: $createsNewTable, tabs: [true, false], height: 28) { isNew in
          CapsuleTabLabel(
            text: isNew ? "New table" : "Existing table", isSelected: createsNewTable == isNew)
        }
        .fitsContent()
        .accessibilityLabel("Destination")
        .onChange(of: createsNewTable) { _, _ in
          if editedModel == nil { updateDestination() }
        }
        HStack(spacing: Spacing.sm) {
          TextField("Schema", text: schemaName)
            .textFieldStyle(.plain)
            .inputCapsuleStyle()
          TextField("Table name", text: tableName)
            .textFieldStyle(.plain)
            .inputCapsuleStyle()
        }
      }
    }
  }

  /// Mode and key for an existing table. Only Insert without a key offered (none loaded, or a
  /// key column not imported), with the reason.
  private var existingRowsSection: some View {
    SettingsGroupCard(title: "Existing rows") {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        CapsuleTabPicker(
          selection: Binding(get: { model.mode }, set: { model.selectMode($0) }), tabs: modes,
          height: 28
        ) { mode in
          CapsuleTabLabel(text: Self.modeTitle(mode), isSelected: model.mode == mode)
        }
        .fitsContent()
        .accessibilityLabel("Import mode")
        .disabled(model.offeredMatchKeys.isEmpty)
        if model.isLoadingMatchKeys {
          ImportLoadingRow(text: "Reading the keys of this table...")
        } else if let reason = model.keyedModesUnavailableReason {
          Text(reason)
            .font(.small)
            .foregroundColor(.foregroundMuted)
            .fixedSize(horizontal: false, vertical: true)
        } else if model.mode != .insert {
          HStack(spacing: Spacing.sm) {
            Text("Match rows on")
              .font(.small)
              .foregroundColor(.foregroundMuted)
            CapsuleDropdown(
              title: model.matchKey?.displayName ?? "Choose a key",
              accessibilityLabel: "Match key", options: model.offeredMatchKeys,
              optionTitle: \.displayName, isSelected: { $0 == model.matchKey },
              onSelect: { model.matchKey = $0 })
            Spacer()
          }
        }
      }
    }
  }

  /// The counts of a keyed import before Safe Mode, with the refused rows and their reasons
  private func summarySection(_ summary: TableImportMatchSummary) -> some View {
    SettingsGroupCard(title: "Rows to import") {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        Text(
          "\(summary.newRows.formatted()) new, \(summary.existingRows.formatted()) existing, "
            + "\(summary.refusedCount.formatted()) refused"
        )
        .font(.bodyText)
        .foregroundColor(.foreground)
        Text(
          "\(summary.inserts.formatted()) to insert, \(summary.updates.formatted()) to update, "
            + "\(summary.skips.formatted()) to skip. Refused rows are not written."
        )
        .font(.small)
        .foregroundColor(.foregroundMuted)
        if !summary.refused.isEmpty {
          ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xs) {
              ForEach(summary.refused.indices, id: \.self) { index in
                let refusal = summary.refused[index]
                Text("Row \(refusal.row.formatted()): \(refusal.reason)")
                  .font(.small)
                  .foregroundColor(.foreground)
                  .textSelection(.enabled)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
            }
            .padding(Spacing.sm)
          }
          .frame(maxHeight: 140)
          .background(Color.appBackground)
          .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
          if summary.refusedCount > summary.refused.count {
            Text(
              "Showing the first \(summary.refused.count.formatted()) of "
                + "\(summary.refusedCount.formatted()) refused rows."
            )
            .font(.small)
            .foregroundColor(.foregroundMuted)
          }
        }
        if let notice = model.notice {
          Text(notice)
            .font(.small)
            .foregroundColor(.foreground)
        } else {
          Text("Nothing is written yet. Continue to import these rows, or go back to change them.")
            .font(.small)
            .foregroundColor(.foregroundMuted)
        }
      }
    }
  }

  private var sqlSection: some View {
    SettingsGroupCard(title: "SQL preview") {
      Text(createTableSQL)
        .font(.monoSmall)
        .foregroundColor(.foregroundMuted)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.sm)
        .background(Color.appBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
    }
  }

  /// Indexes of included columns whose target is missing from a loaded existing table.
  private var missingColumns: Set<Int> {
    guard !createsNewTable else { return [] }
    let name = model.destination.table.lowercased()
    let schema = model.destination.schema
    guard
      let table = tables.first(where: { candidate in
        candidate.name.lowercased() == name && (schema.map { $0 == candidate.schema } ?? true)
      })
    else { return [] }
    let known = Set(table.columns.map { $0.name.lowercased() })
    return Set(
      model.mappings.indices.filter {
        model.mappings[$0].included
          && !known.contains(
            model.mappings[$0].targetName.trimmingCharacters(in: .whitespaces).lowercased())
      })
  }

  private var canImport: Bool {
    model.fileURL != nil && !model.isLoading && !model.isImporting
      && !model.mappings.isEmpty
      && model.mappings.contains(where: \.included)
      && model.mappings.filter(\.included).allSatisfy {
        !$0.targetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
      && !model.destination.table.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && missingColumns.isEmpty
      // Update and the other keyed modes match on a key loaded for this destination
      && (model.mode == .insert || (model.matchKey != nil && !model.isLoadingMatchKeys))
  }

  private var fileSize: Int? {
    guard let url = model.fileURL else { return nil }
    return try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
  }

  private var createTableSQL: String {
    guard createsNewTable else { return modeDescription(model.mode) }
    let columns = model.mappings.filter(\.included).map {
      ImportSQLBuilder.Column(name: $0.targetName, kind: $0.kind)
    }
    guard !columns.isEmpty, !model.destination.table.isEmpty else {
      return "Choose a file and enter a table name to preview CREATE TABLE."
    }
    do {
      return try ImportSQLBuilder.createTable(
        schema: model.destination.schema, table: model.destination.table,
        columns: columns, dialect: sqlDialect
      ).sql + ";"
    } catch {
      return error.localizedDescription
    }
  }

  private var sqlDialect: SQLDialect {
    viewModel.notebook.connectionConfig?.databaseType.dialect ?? .postgresql
  }

  static func modeTitle(_ mode: ImportMode) -> String {
    switch mode {
    case .insert: "Insert"
    case .update: "Update"
    case .insertOrUpdate: "Insert or Update"
    case .insertSkippingExisting: "Insert, skip existing"
    }
  }

  private func modeDescription(_ mode: ImportMode) -> String {
    switch mode {
    case .insert: "Rows will be inserted into the existing table."
    case .update: "Rows whose key exists will be updated. The others are skipped."
    case .insertOrUpdate: "Rows whose key exists will be updated. The others are inserted."
    case .insertSkippingExisting: "Rows with a new key will be inserted. The others are skipped."
    }
  }

  private func kindLabel(_ kind: ImportTypeInference.Kind) -> String {
    switch kind {
    case .integer: "Integer"
    case .decimal: "Decimal"
    case .boolean: "Boolean"
    case .date: "Date"
    case .timestamp: "Timestamp"
    case .text: "Text"
    }
  }

  private var formatSelection: Binding<Int> {
    Binding(
      get: { formats.firstIndex(of: model.format) ?? 0 },
      set: { index in
        model.format = formats[index]
        Task { await model.reloadPreview() }
      })
  }

  private var headerSelection: Binding<Bool> {
    Binding(
      get: { model.hasHeader },
      set: { value in
        model.hasHeader = value
        Task { await model.reloadPreview() }
      })
  }

  private func mappingIncluded(_ index: Int) -> Binding<Bool> {
    Binding(
      get: { model.mappings[index].included },
      set: { model.mappings[index].included = $0 })
  }

  private func mappingName(_ index: Int) -> Binding<String> {
    Binding(
      get: { model.mappings[index].targetName },
      set: { model.mappings[index].targetName = $0 })
  }

  private func mappingKind(_ index: Int) -> Binding<Int> {
    Binding(
      get: { kinds.firstIndex(of: model.mappings[index].kind) ?? 5 },
      set: { model.mappings[index].kind = kinds[$0] })
  }

  private var schemaName: Binding<String> {
    Binding(
      get: { model.destination.schema ?? "" },
      set: { setDestination(schema: $0, table: model.destination.table) })
  }

  private var tableName: Binding<String> {
    Binding(
      get: { model.destination.table },
      set: { setDestination(schema: model.destination.schema ?? "", table: $0) })
  }

  private func updateDestination() {
    setDestination(schema: model.destination.schema ?? "", table: model.destination.table)
  }

  private func setDestination(schema: String, table: String) {
    let schema = schema.trimmingCharacters(in: .whitespacesAndNewlines)
    let optionalSchema: String? = schema.isEmpty ? nil : schema
    model.destination =
      createsNewTable
      ? .new(schema: optionalSchema, table: table)
      : .existing(schema: optionalSchema, table: table)
  }

  /// Reads the keys of an existing destination off the main actor. Typing in the table name
  /// restarts this task, so only the name the user stopped at is read.
  private func loadMatchKeys() async {
    // An edited file's keys are the file list's: its table does not change here
    guard editedModel == nil, let manager = viewModel.connectionManager else { return }
    model.tables = tables
    let delay = keysDebounce
    if !model.destination.createsTable { keysDebounce = .milliseconds(350) }
    await model.loadMatchKeys(after: delay) {
      try await manager.fetchTableStructure(schema: $0, table: $1)
    }
  }

  /// Parses the file and, for a keyed import, runs the match reads. A plain INSERT goes on to
  /// Safe Mode at once; a keyed one stops at its summary for Continue or Back.
  private func importFile() {
    isBusy = true
    model.tables = tables
    importTask = Task {
      if await model.prepareImport(for: viewModel), !model.isReviewingMatches {
        await runPreparedImport()
      } else {
        isBusy = false
      }
      importTask = nil
    }
  }

  private func continueImport() {
    isBusy = true
    importTask = Task {
      await runPreparedImport()
      importTask = nil
    }
  }

  /// The one Safe Mode decision and the batch. The sheet closes once the tab takes the batch.
  private func runPreparedImport() async {
    if await model.confirmImport(to: viewModel) {
      didSubmit = true
      isBusy = false
      isPresented = false
    } else {
      isBusy = false
    }
  }

  private func cancelImport() {
    guard !isCancelling else { return }
    guard isBusy else {
      close()
      return
    }
    if model.isExecutingBatch {
      isCancelling = true
      Task {
        if await viewModel.cancelRunningStatement(cancelQueue: false) { close() }
        isCancelling = false
      }
    } else {
      importTask?.cancel()
      close()
    }
  }

  private func close() {
    model.cancel()
    isBusy = false
    isPresented = false
  }
}

/// A loading line whose spinner fades in after 150 ms, so a fast read never flashes it
struct ImportLoadingRow: View {
  let text: String
  @State private var showsSpinner = false

  var body: some View {
    HStack(spacing: Spacing.sm) {
      ProgressView()
        .controlSize(.small)
        .opacity(showsSpinner ? 1 : 0)
        .animation(.easeIn(duration: 0.15), value: showsSpinner)
        // Opt out of the app-wide animation kill switch, only for the fade
        .transaction(value: showsSpinner) { $0.disablesAnimations = false }
      Text(text)
        .font(.small)
        .foregroundColor(.foregroundMuted)
    }
    .task {
      try? await Task.sleep(for: .milliseconds(150))
      guard !Task.isCancelled else { return }
      showsSpinner = true
    }
  }
}
