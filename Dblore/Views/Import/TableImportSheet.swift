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

  private static let errorAnchor = "import-content-end"

  @State private var model = TableImportModel()
  @State private var previewWidth: CGFloat = 0
  @State private var previewContentHeight: CGFloat = 0
  @State private var createsNewTable = true
  @State private var didSubmit = false
  @State private var importTask: Task<Void, Never>?
  @State private var isCancelling = false

  private let formats: [TableImportFormat] = [.csv, .tsv, .json]
  private let kinds: [ImportTypeInference.Kind] = [
    .integer, .decimal, .boolean, .date, .timestamp, .text,
  ]
  /// Row and cell caps. JSONRowsReader uses the same defaults.
  private let limits = DelimitedTextReader.Options()

  var body: some View {
    GenericModal(
      title: "Import Data",
      titleIcon: "square.and.arrow.down",
      width: 760,
      height: 680,
      isPresented: Binding(
        get: { isPresented },
        set: { if $0 || !isBusy { isPresented = $0 } }
      )
    ) {
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: Spacing.lg) {
            fileSection
            if model.fileURL != nil {
              formatSection
              previewSection
              mappingSection
              destinationSection
              sqlSection
            }
            if model.isLoading || model.isImporting {
              ProgressView(value: model.progress)
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
                  RoundedRectangle(cornerRadius: CornerRadius.lg)
                    .stroke(Color.destructive.opacity(0.4), lineWidth: 1)
                )
            }
          }
          .padding(Spacing.md)
          .frame(maxWidth: .infinity, alignment: .leading)
          // Anchor on the padded content so the scroll ends below the bottom padding
          .id(Self.errorAnchor)
        }
        .onChange(of: model.errorMessage) { _, message in
          guard message != nil else { return }
          withAnimation { proxy.scrollTo(Self.errorAnchor, anchor: .bottom) }
        }
      }
    } footer: {
      GenericModalFooter {
        Spacer()
        Button("Cancel", action: cancelImport)
          .buttonStyle(SecondaryButtonStyle())
          .disabled(isCancelling)
        Button("Import", action: importFile)
          .buttonStyle(PrimaryButtonStyle())
          .disabled(!canImport)
      }
    }
    .onAppear {
      if let initialDestination {
        model.destination = initialDestination
        createsNewTable = initialDestination.createsTable
      }
      if let initialURL { Task { await model.loadFile(initialURL) } }
    }
    .onChange(of: isPresented) { _, presented in
      if !presented && !didSubmit { model.cancel() }
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
          Button("Choose File") { Task { await model.pickFile() } }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(model.isLoading || model.isImporting)
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
          Picker("Format", selection: formatSelection) {
            Text("CSV").tag(0)
            Text("TSV").tag(1)
            Text("JSON / NDJSON").tag(2)
          }
          .labelsHidden()
          .frame(width: 170)
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
        .overlay(RoundedRectangle(cornerRadius: CornerRadius.md).stroke(Color.border))
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
            Picker("Type", selection: mappingKind(index)) {
              ForEach(kinds.indices, id: \.self) { kindIndex in
                Text(kindLabel(kinds[kindIndex])).tag(kindIndex)
              }
            }
            .labelsHidden()
            .frame(width: 125)
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
        Picker("Destination", selection: $createsNewTable) {
          Text("New table").tag(true)
          Text("Existing table").tag(false)
        }
        .pickerStyle(.segmented)
        .onChange(of: createsNewTable) { _, _ in updateDestination() }
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
  }

  private var fileSize: Int? {
    guard let url = model.fileURL else { return nil }
    return try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
  }

  private var createTableSQL: String {
    guard createsNewTable else { return "Rows will be inserted into the existing table." }
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

  private func importFile() {
    isBusy = true
    model.tables = tables
    importTask = Task {
      if await model.submit(to: viewModel) {
        didSubmit = true
        isBusy = false
        isPresented = false
      } else {
        isBusy = false
      }
      importTask = nil
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
