// ResultExportSheet.swift
// Download options. The format picker opens on the menu item the user chose.
// Export writes a file. Nothing here is sent to the database. SQL INSERT and Parquet are offered
// for SQL only. Parquet stays in the sheet after its save panel: progress and Cancel show here.

import SwiftUI

struct ResultExportSheet: View {
  let result: CellResult
  /// Formats the picker offers (`exportFormats(for:)`).
  let formats: [ExportFormat]
  /// Default file name of a Parquet download.
  let queryIndex: Int?
  var onExport: (ExportOptions) -> Void
  var onCancel: () -> Void

  @State private var options: ExportOptions
  @State private var estimate: ExportSizeEstimate
  @State private var confirmLarge = false
  @State private var parquet = ParquetExportRun()

  init(
    result: CellResult, format: ExportFormat, queryLanguage: DatabaseCapabilities.QueryLanguage,
    queryIndex: Int? = nil, onExport: @escaping (ExportOptions) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.result = result
    self.formats = Self.exportFormats(for: queryLanguage)
    self.queryIndex = queryIndex
    self.onExport = onExport
    self.onCancel = onCancel
    let initial = ExportOptions(format: formats.contains(format) ? format : .csv)
    _options = State(initialValue: initial)
    _estimate = State(initialValue: ExportSize.estimate(result: result, options: initial))
  }

  /// Every format for SQL. MongoDB has no SQL INSERT (its results have no SQL table or literals)
  /// and no Parquet (its documents have no column types).
  static func exportFormats(for language: DatabaseCapabilities.QueryLanguage) -> [ExportFormat] {
    switch language {
    case .sql: ExportFormat.allCases
    case .mongosh: ExportFormat.allCases.filter { $0 != .sqlInsert && $0 != .parquet }
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.md) {
          sectionGroup {
            formatPicker
            Text(options.format.blurb)
              .font(.small)
              .foregroundColor(.foregroundMuted)
              .fixedSize(horizontal: false, vertical: true)
            rowBadge
            sizeSummary
            if options.format.requiresDuckDBPlugin && !isDuckDBPluginReady {
              missingPluginRow
            }
            if let message = parquet.errorMessage {
              Text(message)
                .font(.small)
                .foregroundColor(.destructive)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          if showsFormatOptions {
            sectionGroup {
              formatOptions
            }
          }
          sectionGroup {
            sensitiveColumns
          }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      Divider()
      footer
    }
    .frame(width: 440, height: 560)
    .background(Color.appBackground)
    .interactiveDismissDisabled(parquet.isRunning)
    // Closing the tab or window also stops a running Parquet export and removes its temp folder.
    .onDisappear { parquet.cancel() }
    .onChange(of: options) { _, updated in
      estimate = ExportSize.estimate(result: result, options: updated)
      parquet.clearError()
    }
    .alert("Large export", isPresented: $confirmLarge) {
      Button("Cancel", role: .cancel) {}
      Button("Export anyway") { runExport() }
    } message: {
      Text(estimate.confirmMessage)
    }
  }

  private var header: some View {
    HStack {
      Text("Export")
        .font(.subheading)
        .foregroundColor(.foreground)
      Spacer()
      Button(action: close) {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .semibold))
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .help("Close")
      // The save panel stays open on its own after the sheet closes.
      .disabled(isChoosingParquetFile)
    }
    .modalBarPadding(vertical: Spacing.sm)
  }

  private var showsFormatOptions: Bool {
    let format = options.format
    return format.offersHeaderToggle || format.offersNullAsEmpty || format.offersWrap
      || format.offersLineBreakToSpace || format.offersFormulaSanitize || format.offersEncoding
      || format.offersQuote || format.offersLineBreak || format.offersJsonPretty
  }

  private func sectionTitle(_ title: String) -> some View {
    Text(title)
      .font(.subheading.weight(.semibold))
      .foregroundColor(.foreground)
  }

  private func sectionGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      content()
    }
    .padding(Spacing.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.cardHeaderBackground)
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
    .overlay(
      HairlineBorder(shape: RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)))
  }

  private var formatPicker: some View {
    HStack(spacing: Spacing.sm) {
      sectionTitle("Format")
      Spacer(minLength: Spacing.sm)
      Picker("Format", selection: $options.format) {
        ForEach(formats) { format in
          Text(format.title).tag(format)
        }
      }
      .pickerStyle(.menu)
      .labelsHidden()
      .fixedSize()
      .disabled(parquet.isRunning)
    }
  }

  private var formatOptions: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      sectionTitle("Options")
      if options.format.offersHeaderToggle {
        optionToggle(
          options.format.headerToggleTitle, isOn: $options.includeHeader,
          help: options.format == .sqlInsert
            ? "Each INSERT lists the column names."
            : "The first row lists the column names.")
      }
      if options.format.offersNullAsEmpty {
        optionToggle(
          "Convert NULL to empty", isOn: $options.nullAsEmpty,
          help: options.format == .sqlInsert
            ? "NULL cells become an empty string. Turn off to write NULL."
            : "NULL cells become an empty field. Turn off to write the text NULL.")
      }
      if options.format.offersLineBreakToSpace {
        optionToggle(
          "Convert line break to space", isOn: $options.convertLineBreaksToSpace,
          help: "Replaces a line break inside a cell with a space.")
      }
      if options.format.offersFormulaSanitize {
        optionToggle(
          "Sanitize formula-like values", isOn: $options.sanitizeFormulas,
          help:
            "Prefixes text that starts with =, +, -, @, or a tab so a spreadsheet does not run it as a formula."
        )
      }
      if options.format.offersWrap {
        optionToggle(
          "Wrap long text", isOn: $options.wrapText,
          help: "Keeps the full cell text. Turn off to cut long cells with an ellipsis.")
      }
      if options.format.offersJsonPretty {
        optionToggle(
          "Pretty print", isOn: $options.jsonPretty,
          help: "Indents the JSON. Turn off for one line.")
        optionToggle(
          "Include null", isOn: $options.jsonIncludeNull,
          help: "Keeps keys whose value is null. Turn off to omit them.")
        optionToggle(
          "Preserve all values as string", isOn: $options.jsonValuesAsString,
          help: "Writes numbers, booleans, and null as text. Null becomes the text NULL.")
      }
      if options.format.offersEncoding {
        optionPicker(
          "Encoding", selection: $options.encoding,
          help:
            "UTF-16 LE includes a byte order mark. Windows-1252 drops characters it cannot store."
        ) {
          ForEach(ExportEncoding.allCases) { encoding in
            Text(encoding.title).tag(encoding)
          }
        }
      }
      if options.format.offersQuote {
        optionPicker(
          "Quote", selection: $options.quote,
          help:
            "Quote if needed wraps a field with a comma, a quote, or a line break. Never can split a field; formulas are then neutralized on every line."
        ) {
          ForEach(ExportQuote.allCases) { quote in
            Text(quote.title).tag(quote)
          }
        }
      }
      if options.format.offersLineBreak {
        optionPicker(
          "Line break", selection: $options.lineBreak,
          help: "Record separators and line breaks inside fields use this ending."
        ) {
          ForEach(ExportLineBreak.allCases) { lineBreak in
            Text(lineBreak.title).tag(lineBreak)
          }
        }
      }
    }
  }

  private func optionToggle(_ title: String, isOn: Binding<Bool>, help: String) -> some View {
    Toggle(title, isOn: isOn)
      .toggleStyle(.checkbox)
      .font(.bodyText)
      .help(help)
  }

  private func optionPicker<Selection: Hashable>(
    _ title: String, selection: Binding<Selection>, help: String,
    @ViewBuilder content: () -> some View
  ) -> some View {
    HStack(spacing: Spacing.sm) {
      Text(title)
        .font(.bodyText)
        .foregroundColor(.foreground)
      Spacer(minLength: Spacing.sm)
      Picker(title, selection: selection, content: content)
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }
    .help(help)
  }

  private var sensitiveColumns: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      sectionTitle("Sensitive columns")
      Text("Checked columns are written as \(ExportOptions.mask). You can select more than one.")
        .font(.small)
        .foregroundColor(.foregroundSubtle)
        .fixedSize(horizontal: false, vertical: true)
      if result.columns.isEmpty {
        Text("This result has no columns.")
          .font(.small)
          .foregroundColor(.foregroundMuted)
      } else {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          ForEach(Array(result.columns.enumerated()), id: \.offset) { index, column in
            Toggle(isOn: redacted(index)) {
              HStack(spacing: Spacing.sm) {
                Text(columnTitle(column, index: index))
                  .font(.bodyText)
                  .foregroundColor(.foreground)
                  .lineLimit(1)
                Spacer(minLength: Spacing.sm)
                Text(column.type)
                  .font(.monoSmall)
                  .foregroundColor(.foregroundSubtle)
                  .lineLimit(1)
              }
            }
            .toggleStyle(.checkbox)
          }
        }
      }
    }
  }

  private var footer: some View {
    HStack {
      if let written = parquet.rowsWritten {
        ProgressView(value: Double(written), total: Double(max(result.rows.count, 1)))
        Text("\(written.formatted()) of \(result.rows.count.formatted()) rows")
          .font(.small)
          .foregroundColor(.foregroundMuted)
          .monospacedDigit()
          .fixedSize()
        Button("Cancel") { parquet.cancel() }
          .buttonStyle(GhostButtonStyle())
          .keyboardShortcut(.cancelAction)
      } else {
        Button("Reset to Default") {
          options = ExportOptions(format: options.format)
        }
        .buttonStyle(GhostButtonStyle())
        .disabled(parquet.isRunning)
        Spacer()
        Button("Cancel", action: close)
          .buttonStyle(GhostButtonStyle())
          .disabled(isChoosingParquetFile)
        Button("Export", action: export)
          .buttonStyle(PrimaryButtonStyle())
          .disabled(!canExport)
      }
    }
    .modalBarPadding()
  }

  /// The DuckDB plugin is installed, or its launch check is still hashing an installed file.
  private var isDuckDBPluginReady: Bool {
    PluginRegistry.shared.manager(id: "duckdb")?.isInstalledOrPending ?? false
  }

  /// The Parquet save panel is open: no rows written yet.
  private var isChoosingParquetFile: Bool {
    parquet.isRunning && parquet.rowsWritten == nil
  }

  private var canExport: Bool {
    !parquet.isRunning && (!options.format.requiresDuckDBPlugin || isDuckDBPluginReady)
  }

  private var missingPluginRow: some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundColor(.warning)
      Text("Requires the DuckDB plugin")
        .foregroundColor(.warning)
      Spacer(minLength: Spacing.sm)
      Button("Open Settings > Plugins") {
        close()
        ConnectionErrorAction.postOpenPluginSettings()
      }
      .buttonStyle(.link)
      .linkPointer()
    }
    .font(.small)
  }

  /// Closes the sheet; a running Parquet export is cancelled and cleans up after itself.
  private func close() {
    parquet.cancel()
    onCancel()
  }

  private var sizeSummary: some View {
    VStack(alignment: .leading, spacing: Spacing.xxs) {
      Text(estimate.summary)
        .font(.small)
        .foregroundColor(estimate.isLarge ? .warning : .foregroundSubtle)
      if let warning = estimate.warning {
        Text(warning)
          .font(.small)
          .foregroundColor(.warning)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func export() {
    if estimate.isLarge {
      confirmLarge = true
    } else {
      runExport()
    }
  }

  private func runExport() {
    guard options.format == .parquet else {
      onExport(options)
      return
    }
    parquet.start(
      result: DataExporter.applying(options, to: result), queryIndex: queryIndex
    ) { url in
      onCancel()
      // The sheet is still dismissing. Presenting now stacks the two modals.
      DispatchQueue.main.async { DataExporter.presentSavedFile(url) }
    }
  }

  private var rowBadge: some View {
    let count = result.rows.count
    let tint = rowTint(ExportRowScale.level(for: count))
    return HStack(spacing: Spacing.xs) {
      Text(count.formatted())
        .font(.labelText.weight(.semibold))
        .monospacedDigit()
      Text(rowCaption(count))
        .font(.small)
    }
    .foregroundColor(tint)
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.xxs)
    .background(tint.opacity(0.15), in: Capsule())
    .overlay(HairlineBorder(shape: Capsule(), color: tint.opacity(0.45)))
  }

  private func rowCaption(_ count: Int) -> String {
    let noun = count == 1 ? "row" : "rows"
    if result.wasLimited {
      return "loaded \(noun) to export"
    }
    return "\(noun) to export"
  }

  private func rowTint(_ level: ExportRowScale) -> Color {
    switch level {
    case .modest: .success
    case .large: .warning
    case .huge: .destructive
    }
  }

  private func columnTitle(_ column: ColumnInfo, index: Int) -> String {
    column.name.isEmpty ? "Column \(index + 1)" : column.name
  }

  private func redacted(_ index: Int) -> Binding<Bool> {
    Binding(
      get: { options.redactedColumns.contains(index) },
      set: { isOn in
        if isOn {
          options.redactedColumns.insert(index)
        } else {
          options.redactedColumns.remove(index)
        }
      })
  }
}

/// One Parquet download from the sheet: save panel, then the export off the main actor with
/// its row progress, Cancel, and the error to show when it fails.
@Observable
final class ParquetExportRun {
  /// Rows inserted so far; nil while no export is writing.
  private(set) var rowsWritten: Int?
  private(set) var errorMessage: String?
  private var task: Task<Void, Never>?

  var isRunning: Bool { task != nil }

  func start(result: CellResult, queryIndex: Int?, onSaved: @escaping (URL) -> Void) {
    guard task == nil else { return }
    errorMessage = nil
    task = Task {
      defer {
        task = nil
        rowsWritten = nil
      }
      // The sheet may have closed while the panel was open.
      guard let url = await DataExporter.chooseParquetDestination(queryIndex: queryIndex),
        !Task.isCancelled
      else { return }
      rowsWritten = 0
      do {
        try await DataExporter.exportParquet(
          result: result, to: url,
          progress: { rows in
            Task { @MainActor in self.report(rows) }
          })
        onSaved(url)
      } catch is CancellationError {
      } catch {
        errorMessage = "Export failed: \(error.localizedDescription)"
      }
    }
  }

  func cancel() {
    task?.cancel()
  }

  func clearError() {
    errorMessage = nil
  }

  /// Late reports (after the export ended) are dropped.
  private func report(_ rows: Int) {
    guard task != nil, let written = rowsWritten else { return }
    rowsWritten = max(written, rows)
  }
}
