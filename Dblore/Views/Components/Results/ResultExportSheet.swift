// ResultExportSheet.swift
// Download options. The format picker opens on the menu item the user chose.
// Export writes a file. Nothing here is sent to the database. SQL INSERT and Parquet are offered
// for SQL only. Parquet stays in the sheet after its save panel: progress and Cancel show here.
// A result the grid holds only part of offers "All rows" (`AllRowsExportOffer`): its read runs
// again on a separate connection and writes every row (CSV, JSON or SQL INSERT), with rows
// written and Cancel here too. "Shown rows" of a result whose cut cells are not loaded loads them
// first (`loadShownRows`), and exports nothing when they cannot be loaded.

import SwiftUI

struct ResultExportSheet: View {
  let result: CellResult
  /// Formats the picker offers (`exportFormats(for:)`).
  let formats: [ExportFormat]
  /// Default file name of a Parquet or all-rows download.
  let queryIndex: Int?
  /// "All rows" beside the shown rows; nil: the shown rows are every row (no rows picker)
  let allRows: AllRowsExportChoice?
  /// Loads the shown rows' cut cells before a "Shown rows" export (nil when they are whole);
  /// nil back when they could not be loaded (the view model told the user)
  let loadShownRows: (() async -> CellResult?)?
  /// Saves the shown rows (cut cells loaded) with the options. Parquet is written here instead.
  var onExport: (ExportOptions, CellResult) -> Void
  var onCancel: () -> Void

  /// Which rows the sheet exports
  enum RowScope: Hashable {
    case shown
    case all
  }

  /// Formats of an all-rows export: the ones written row by row (`StreamedResultWriter`)
  static let allRowsFormats: [ExportFormat] = [.csv, .json, .sqlInsert]

  @State private var options: ExportOptions
  @State private var estimate: ExportSizeEstimate
  @State private var confirmLarge = false
  @State private var parquet = ParquetExportRun()
  @State private var allRowsRun = AllRowsExportRun()
  @State private var scope = RowScope.shown
  /// The shown rows as exported: `result` until `loadShownRows` gave them whole
  @State private var shown: CellResult
  @State private var shownLoad: Task<Void, Never>?
  @State private var shownError: String?
  /// `loadShownRows` gave the shown rows whole
  @State private var isShownLoaded = false

  init(
    result: CellResult, format: ExportFormat, queryLanguage: DatabaseCapabilities.QueryLanguage,
    queryIndex: Int? = nil, allRows: AllRowsExportChoice? = nil,
    loadShownRows: (() async -> CellResult?)? = nil,
    onExport: @escaping (ExportOptions, CellResult) -> Void, onCancel: @escaping () -> Void
  ) {
    self.result = result
    self.formats = Self.exportFormats(for: queryLanguage)
    self.queryIndex = queryIndex
    self.allRows = allRows
    self.loadShownRows = loadShownRows
    self.onExport = onExport
    self.onCancel = onCancel
    _shown = State(initialValue: result)
    let initial = ExportOptions(format: formats.contains(format) ? format : .csv)
      .redactingMasked(result.columns)
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
            if allRows != nil {
              rowScopePicker
            }
            formatPicker
            Text(options.format.blurb)
              .font(.small)
              .foregroundColor(.foregroundMuted)
              .fixedSize(horizontal: false, vertical: true)
            if scope == .all {
              Text("Runs the query again on a separate connection and writes every row.")
                .font(.small)
                .foregroundColor(.foregroundSubtle)
                .fixedSize(horizontal: false, vertical: true)
            } else {
              rowBadge
              sizeSummary
              if options.format.requiresDuckDBPlugin && !isDuckDBPluginReady {
                missingPluginRow
              }
            }
            if let message = errorMessage {
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
    .interactiveDismissDisabled(isBusy)
    // Closing the tab or window also stops a running export and removes its temporary file.
    .onDisappear { cancelWork() }
    .onChange(of: options) { _, updated in
      estimate = ExportSize.estimate(result: shown, options: updated)
      clearErrors()
    }
    .onChange(of: scope) { _, updated in
      if updated == .all && !Self.allRowsFormats.contains(options.format) {
        options.format = .csv
      }
      clearErrors()
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
      .disabled(isChoosingFile)
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

  /// "Shown rows (N)" / "All rows". Without an all-rows source the picker stays on the shown
  /// rows and the reason shows under it (macOS shows no help on a disabled control).
  private var rowScopePicker: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      HStack(spacing: Spacing.sm) {
        sectionTitle("Rows")
        Spacer(minLength: Spacing.sm)
        CapsuleTabPicker(selection: $scope, tabs: [.shown, .all], height: 28) { tab in
          CapsuleTabLabel(text: scopeTitle(tab), isSelected: scope == tab)
        }
        .fitsContent()
        .disabled(allRows?.offer.source == nil || isBusy)
        .accessibilityLabel("Rows")
      }
      if allRows?.offer.source == nil, let reason = allRows?.offer.reason {
        Text(reason)
          .font(.small)
          .foregroundColor(.foregroundMuted)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func scopeTitle(_ scope: RowScope) -> String {
    switch scope {
    case .shown: "Shown rows (\(result.rows.count.formatted()))"
    case .all: "All rows"
    }
  }

  /// The formats of the chosen rows
  private var scopeFormats: [ExportFormat] {
    scope == .all ? formats.filter(Self.allRowsFormats.contains) : formats
  }

  private var formatPicker: some View {
    HStack(spacing: Spacing.sm) {
      sectionTitle("Format")
      Spacer(minLength: Spacing.sm)
      CapsulePickerMenu(title: options.format.title) {
        Picker("Format", selection: $options.format) {
          ForEach(scopeFormats) { format in
            Text(format.title).tag(format)
          }
        }
        .pickerStyle(.inline)
        .labelsHidden()
      }
      .accessibilityLabel("Format")
      .disabled(isBusy)
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
          "Encoding", selection: $options.encoding, value: options.encoding.title,
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
          "Quote", selection: $options.quote, value: options.quote.title,
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
          "Line break", selection: $options.lineBreak, value: options.lineBreak.title,
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

  /// `value`: the title of the selected choice
  private func optionPicker<Selection: Hashable>(
    _ title: String, selection: Binding<Selection>, value: String, help: String,
    @ViewBuilder content: () -> some View
  ) -> some View {
    let picker = Picker(title, selection: selection, content: content)
    return HStack(spacing: Spacing.sm) {
      Text(title)
        .font(.bodyText)
        .foregroundColor(.foreground)
      Spacer(minLength: Spacing.sm)
      CapsulePickerMenu(title: value) {
        picker
          .pickerStyle(.inline)
          .labelsHidden()
      }
      .accessibilityLabel(title)
    }
    .help(help)
  }

  private var sensitiveColumns: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      sectionTitle("Sensitive columns")
      Text(
        "Checked columns are written as \(ExportOptions.mask). You can select more than one. "
          + "Columns masked by a connection rule stay checked."
      )
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
            .disabled(column.masked)
            .help(column.masked ? "Masked by a connection rule" : "")
          }
        }
      }
    }
  }

  private var footer: some View {
    HStack {
      if let written = allRowsRun.rowsWritten {
        ProgressView()
          .controlSize(.small)
        Text("\(written.formatted()) \(written == 1 ? "row" : "rows") written")
          .font(.small)
          .foregroundColor(.foregroundMuted)
          .monospacedDigit()
          .fixedSize()
        Spacer()
        Button("Cancel") { allRowsRun.cancel() }
          .buttonStyle(GhostButtonStyle())
          .keyboardShortcut(.cancelAction)
      } else if let written = parquet.rowsWritten {
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
          options = ExportOptions(format: options.format).redactingMasked(result.columns)
        }
        .buttonStyle(GhostButtonStyle())
        .disabled(isBusy)
        Spacer()
        if shownLoad != nil {
          Text("Loading the full values…")
            .font(.small)
            .foregroundColor(.foregroundMuted)
            .fixedSize()
        }
        Button("Cancel", action: close)
          .buttonStyle(GhostButtonStyle())
          .disabled(isChoosingFile)
        Button("Export", action: export)
          .buttonStyle(PrimaryButtonStyle())
          .disabled(!canExport)
      }
    }
    .modalBarPadding()
  }

  /// The DuckDB plugin is installed, or its launch check is still hashing an installed file.
  private var isDuckDBPluginReady: Bool {
    PluginRegistry.shared.manager(for: .duckdb)?.isInstalledOrPending ?? false
  }

  /// A Parquet or all-rows save panel is open: no rows written yet.
  private var isChoosingFile: Bool {
    (parquet.isRunning && parquet.rowsWritten == nil)
      || (allRowsRun.isRunning && allRowsRun.rowsWritten == nil)
  }

  /// An export runs, or the shown rows' cut cells load
  private var isBusy: Bool {
    parquet.isRunning || allRowsRun.isRunning || shownLoad != nil
  }

  private var canExport: Bool {
    !isBusy
      && (scope == .all || !options.format.requiresDuckDBPlugin || isDuckDBPluginReady)
  }

  private var errorMessage: String? {
    scope == .all ? allRowsRun.errorMessage : shownError ?? parquet.errorMessage
  }

  private func clearErrors() {
    parquet.clearError()
    allRowsRun.clearError()
    shownError = nil
  }

  /// Stops a running export (it cleans up after itself) and the shown rows' load
  private func cancelWork() {
    parquet.cancel()
    allRowsRun.cancel()
    shownLoad?.cancel()
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

  /// Closes the sheet; a running export is cancelled and cleans up after itself.
  private func close() {
    cancelWork()
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
    if scope == .all {
      exportAllRows()
    } else if let loadShownRows, !isShownLoaded {
      loadThenExport(loadShownRows)
    } else if estimate.isLarge {
      confirmLarge = true
    } else {
      runExport()
    }
  }

  /// Loads the shown rows' cut cells, then exports them; a refused load exports nothing
  private func loadThenExport(_ load: @escaping () async -> CellResult?) {
    clearErrors()
    shownLoad = Task {
      let loaded = await load()
      shownLoad = nil
      guard !Task.isCancelled else { return }
      guard let loaded else {
        shownError =
          "The shown rows cannot be exported whole. All rows writes every full value."
        return
      }
      shown = loaded
      isShownLoaded = true
      estimate = ExportSize.estimate(result: loaded, options: options)
      if estimate.isLarge {
        confirmLarge = true
      } else {
        runExport()
      }
    }
  }

  private func runExport() {
    guard options.format == .parquet else {
      onExport(options, shown)
      return
    }
    parquet.start(
      result: DataExporter.applying(options, to: shown), queryIndex: queryIndex
    ) { url in
      finishSaved(url)
    }
  }

  private func exportAllRows() {
    guard let allRows, let source = allRows.offer.source else { return }
    let options = options
    allRowsRun.start(
      fileExtension: Self.fileExtension(options.format), queryIndex: queryIndex,
      workspaceID: allRows.workspaceID,
      write: { url, progress in try await allRows.write(source, options, url, progress) },
      onSaved: { url in finishSaved(url) })
  }

  /// Closes the sheet, then offers to open the saved file
  private func finishSaved(_ url: URL) {
    onCancel()
    // The sheet is still dismissing. Presenting now stacks the two modals.
    DispatchQueue.main.async { DataExporter.presentSavedFile(url) }
  }

  /// File extension of an all-rows export
  private static func fileExtension(_ format: ExportFormat) -> String {
    switch format {
    case .json: "json"
    case .sqlInsert: "sql"
    default: "csv"
    }
  }

  private var rowBadge: some View {
    let count = shown.rows.count
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
      guard
        let url = await DataExporter.chooseDestination(
          fileExtension: "parquet", queryIndex: queryIndex),
        !Task.isCancelled
      else { return }
      // No workspace is known here: the export is listed at Quit only
      let runningWork = RunningWorkRegistry.shared.begin(
        workspaceID: nil, label: "Parquet export to \(url.lastPathComponent)", kind: .dataExport
      ) { self.cancel() }
      defer { RunningWorkRegistry.shared.end(runningWork) }
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

/// The sheet's "All rows" choice: what is offered, and what writes it
struct AllRowsExportChoice {
  let offer: AllRowsExportOffer
  /// Runs the source again and writes every row with the options to the URL (replaced once
  /// whole), reporting the rows written; returns them
  let write:
    (AllRowsExportSource, ExportOptions, URL, @escaping @Sendable (Int) -> Void) async throws
      -> Int
  /// The workspace the export is listed under while it runs
  let workspaceID: UUID?
}

/// One all-rows download from the sheet: save panel, then the read again on a separate
/// connection with its rows written, Cancel, and the error to show when it fails.
@Observable
final class AllRowsExportRun {
  /// Rows written so far; nil while no export is writing.
  private(set) var rowsWritten: Int?
  private(set) var errorMessage: String?
  private var task: Task<Void, Never>?

  var isRunning: Bool { task != nil }

  func start(
    fileExtension: String, queryIndex: Int?, workspaceID: UUID?,
    write: @escaping (URL, @escaping @Sendable (Int) -> Void) async throws -> Int,
    onSaved: @escaping (URL) -> Void
  ) {
    guard task == nil else { return }
    errorMessage = nil
    task = Task {
      defer {
        task = nil
        rowsWritten = nil
      }
      // The sheet may have closed while the panel was open.
      guard
        let url = await DataExporter.chooseDestination(
          fileExtension: fileExtension, queryIndex: queryIndex),
        !Task.isCancelled
      else { return }
      let runningWork = RunningWorkRegistry.shared.begin(
        workspaceID: workspaceID, label: "Export of all rows to \(url.lastPathComponent)",
        kind: .dataExport
      ) { self.cancel() }
      defer { RunningWorkRegistry.shared.end(runningWork) }
      rowsWritten = 0
      do {
        _ = try await write(url) { rows in
          Task { @MainActor in self.report(rows) }
        }
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
