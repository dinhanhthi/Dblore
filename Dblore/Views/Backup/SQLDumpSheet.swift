import Foundation
import SwiftUI

/// Export SQL Dump (Structure, Data and Drop per table, then a save panel) and, for SQLite, Copy
/// Database File. Both run off the main actor with progress and Cancel.
struct SQLDumpSheet: View {
  enum Kind {
    case sqlDump
    case fileCopy
  }

  let kind: Kind
  /// Loaded schema tables, offered in the table list (Structure and Data on by default)
  let tables: [DatabaseTable]
  @Binding var isPresented: Bool
  @Binding var isBusy: Bool

  @State private var model: DatabaseBackupModel
  /// Every listed table's flags; Drop is only ever on with Structure
  @State private var flags: [SQLDumpDDL.ObjectName: SQLDumpOptions.TableOptions]

  /// Width of a Structure, Data or Drop checkbox column
  private static let flagColumnWidth: CGFloat = 64

  /// Width of the right sidebar the sheet opens in
  static let panelWidth: CGFloat = 520

  init(
    kind: Kind, viewModel: NotebookViewModel, tables: [DatabaseTable], isPresented: Binding<Bool>,
    isBusy: Binding<Bool>
  ) {
    self.kind = kind
    self.tables = tables
    _isPresented = isPresented
    _isBusy = isBusy
    _model = State(initialValue: DatabaseBackupModel(viewModel: viewModel))
    _flags = State(
      initialValue: Dictionary(
        tables.map { (Self.objectName($0), SQLDumpOptions.TableOptions()) },
        uniquingKeysWith: { first, _ in first }))
  }

  var body: some View {
    VStack(spacing: 0) {
      GenericModalHeader(
        title: kind == .sqlDump ? "Export SQL Dump" : "Copy Database File",
        titleIcon: kind == .sqlDump ? "square.and.arrow.up" : "doc.on.doc",
        onClose: close)
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.lg) {
          switch kind {
          case .sqlDump:
            if !tables.isEmpty { tablesSection }
            optionsSection
          case .fileCopy:
            fileCopySection
          }
          progressSection
          messageSection
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: .infinity)
      GenericModalFooter {
        Spacer()
        Button(model.isBusy ? "Cancel" : "Close") {
          if model.isBusy {
            Task { await model.cancel() }
          } else {
            close()
          }
        }
        .buttonStyle(FilledSecondaryButtonStyle())
        Button(action: start) {
          if model.isBusy {
            HStack(spacing: Spacing.sm) {
              ProgressView().controlSize(.mini)
              Text(kind == .sqlDump ? "Exporting..." : "Copying...")
            }
          } else {
            Text(kind == .sqlDump ? "Export..." : "Copy...")
          }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(model.isBusy || (kind == .sqlDump && !tables.isEmpty && chosenCount == 0))
      }
    }
    .background(Color.cardBackground)
    .onChange(of: model.isBusy) { _, busy in isBusy = busy }
    // The tab can close while the dump or copy runs: it stops, and the panel is no longer busy
    .onDisappear {
      model.sheetDisappeared()
      isBusy = false
    }
  }

  // MARK: - Sections

  private var tablesSection: some View {
    SettingsGroupCard(title: "Tables") {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        Text("\(chosenCount) of \(tables.count) tables in the dump")
          .font(.small)
          .foregroundColor(.foregroundMuted)
        databaseRow
        Divider()
        ScrollView {
          // Rows are built as they scroll into view, never one per table up front
          LazyVStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(tables) { table in
              tableRow(table)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 220)
        .disabled(model.isBusy)
        note(
          "A table with Structure and Data off is left out, and views on tables left out are "
            + "left out too. A table whose foreign key points to a table left out does not "
            + "restore on its own. Structure off keeps only the rows, to restore them into "
            + "the database they came from.")
        note(dropNote)
      }
    }
  }

  /// "All tables" with a tri-state checkbox per flag: a click sets the flag on every table
  private var databaseRow: some View {
    let structured = flags.filter { $0.value.structure }
    return HStack(spacing: 0) {
      Text("All tables")
        .font(.labelText.weight(.semibold))
        .foregroundColor(.foreground)
      Spacer(minLength: Spacing.sm)
      databaseToggle(
        "Structure", \.structure, state: DatabaseBackupModel.databaseRow(\.structure, of: flags))
      databaseToggle("Data", \.data, state: DatabaseBackupModel.databaseRow(\.data, of: flags))
      databaseToggle("Drop", \.drop, state: DatabaseBackupModel.databaseRow(\.drop, of: structured))
        .disabled(structured.isEmpty)
    }
    .disabled(model.isBusy)
  }

  /// A checkbox that shows a dash when `state` is mixed (two sources that disagree) and sets
  /// `flag` on every table when clicked
  private func databaseToggle(
    _ title: String, _ flag: WritableKeyPath<SQLDumpOptions.TableOptions, Bool>,
    state: SQLDumpTriState
  ) -> some View {
    let set: (Bool) -> Void = { on in
      flags = Self.dropNeedsStructure(
        DatabaseBackupModel.settingDatabaseRow(flag, to: on, in: flags))
    }
    let sources = [
      Binding(get: { state != .none }, set: set), Binding(get: { state == .all }, set: set),
    ]
    return VStack(spacing: 2) {
      Text(title)
        .font(.small)
        .foregroundColor(.foregroundMuted)
      Toggle(title, sources: sources, isOn: \.self)
        .toggleStyle(.checkbox)
        .labelsHidden()
    }
    .frame(width: Self.flagColumnWidth)
  }

  private func tableRow(_ table: DatabaseTable) -> some View {
    let name = Self.objectName(table)
    let structure = flags[name]?.structure ?? true
    return HStack(spacing: 0) {
      Text(verbatim: showsSchema ? "\(table.schema).\(table.name)" : table.name)
        .font(.monoMedium)
        .foregroundColor(.foreground)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: Spacing.sm)
      tableToggle("Structure", \.structure, of: name)
      tableToggle("Data", \.data, of: name)
      tableToggle("Drop", \.drop, of: name)
        .disabled(!structure)
    }
  }

  private func tableToggle(
    _ title: String, _ flag: WritableKeyPath<SQLDumpOptions.TableOptions, Bool>,
    of name: SQLDumpDDL.ObjectName
  ) -> some View {
    Toggle(
      title,
      isOn: Binding(
        get: { flags[name]?[keyPath: flag] ?? false },
        set: { on in
          var table = flags[name] ?? SQLDumpOptions.TableOptions()
          table[keyPath: flag] = on
          if !table.structure { table.drop = false }
          flags[name] = table
        })
    )
    .toggleStyle(.checkbox)
    .labelsHidden()
    .frame(width: Self.flagColumnWidth)
  }

  /// What Drop does on this connection's engine
  private var dropNote: String {
    let lead =
      "Drop: the dump first drops each table with Drop on and the views, sequences and types "
      + "it recreates, so a restore replaces them with the dump's rows. "
    switch engine {
    case .postgresql:
      return lead
        + "PostgreSQL never cascades: an object outside the dump that depends on a dropped "
        + "table makes the restore fail and roll back. Drop on a partitioned table also drops "
        + "its partitions."
    case .mysql:
      return lead
        + "MySQL commits each DROP at once: if a later statement fails, what it dropped stays "
        + "gone."
    case .sqlite:
      return lead
        + "SQLite refuses the restore when a table outside the dump has a foreign key with ON "
        + "DELETE CASCADE, SET NULL or SET DEFAULT to a dropped table. Virtual tables are never "
        + "dropped (their rows are not in the dump): an existing one keeps its rows, a missing "
        + "one is created empty."
    default:
      return lead
        + "Never with CASCADE: an object outside the dump that depends on a dropped one makes "
        + "the restore fail."
    }
  }

  private func note(_ text: String) -> some View {
    Text(text)
      .font(.small)
      .foregroundColor(.foregroundMuted)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var optionsSection: some View {
    SettingsGroupCard(title: "Options") {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        Text(
          (engine == .duckdb
            ? "The dump reads everything in one snapshot on this tab's connection. "
            : "The dump reads everything in one snapshot on its own connection. ")
            + "It holds your data as plain text: keep the file somewhere safe."
        )
        .font(.small)
        .foregroundColor(.foregroundMuted)
        .fixedSize(horizontal: false, vertical: true)
        Text(
          (engine == .duckdb
            ? "Not included: macros, secrets, comments, temporary objects, attached databases "
              + "and user types other than ENUM. "
            : "Not included: functions, procedures, extensions, roles, ownership and grants. ")
            + "Restore it with File > Restore SQL Dump (up to 64 MiB)."
        )
        .font(.small)
        .foregroundColor(.foregroundMuted)
        .fixedSize(horizontal: false, vertical: true)
        if engine == .sqlite {
          Text(
            "While another tab writes to a database without WAL, the dump waits up to "
              + "5 seconds for it, then stops. Try again once the write is done."
          )
          .font(.small)
          .foregroundColor(.foregroundMuted)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private var fileCopySection: some View {
    SettingsGroupCard(title: "Database File") {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        Text(
          "Saves a copy of the open database as one file, with the data written so far, "
            + "including changes still in its WAL file. The copy is checked before it "
            + "replaces the file you choose."
        )
        .font(.small)
        .foregroundColor(.foregroundMuted)
        .fixedSize(horizontal: false, vertical: true)
        Text(
          "Choose a new name: a file with -wal, -shm or -journal files next to it is refused."
        )
        .font(.small)
        .foregroundColor(.foregroundMuted)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  @ViewBuilder
  private var progressSection: some View {
    switch kind {
    case .sqlDump:
      if let progress = model.dumpProgress, model.activity == .dumping {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          ProgressView(
            value: progress.tableCount == 0
              ? nil : Double(progress.tablesDone) / Double(progress.tableCount)
          )
          .accessibilityLabel("Export progress")
          Text(
            "\(progress.tablesDone) of \(progress.tableCount) tables, "
              + "\(progress.rowsWritten.formatted()) rows"
          )
          .font(.monoSmall)
          .foregroundColor(.foregroundMuted)
        }
      }
    case .fileCopy:
      if model.activity == .copying {
        let progress = model.copyProgress
        VStack(alignment: .leading, spacing: Spacing.xs) {
          ProgressView(
            value: progress.flatMap {
              $0.pageCount == 0 ? nil : Double($0.pagesCopied) / Double($0.pageCount)
            }
          )
          .accessibilityLabel("Copy progress")
          if let progress {
            Text("\(progress.pagesCopied.formatted()) of \(progress.pageCount.formatted()) pages")
              .font(.monoSmall)
              .foregroundColor(.foregroundMuted)
          }
        }
      }
    }
  }

  @ViewBuilder
  private var messageSection: some View {
    if let error = model.errorMessage {
      BackupMessageBox(text: error, isError: true)
    } else if let result = model.resultMessage {
      BackupMessageBox(text: result, isError: false)
    }
  }

  // MARK: - Helpers

  private var engine: DatabaseType? {
    model.viewModel.notebook.connectionConfig?.databaseType
  }

  /// PostgreSQL tables live in several schemas; the others in one
  private var showsSchema: Bool {
    Set(tables.map(\.schema)).count > 1
  }

  private static func objectName(_ table: DatabaseTable) -> SQLDumpDDL.ObjectName {
    SQLDumpDDL.ObjectName(schema: table.schema, name: table.name)
  }

  /// Listed tables with Structure or Data on
  private var chosenCount: Int {
    flags.values.filter { $0.structure || $0.data }.count
  }

  /// `flags` with Drop off on every table whose Structure is off
  private static func dropNeedsStructure(
    _ flags: [SQLDumpDDL.ObjectName: SQLDumpOptions.TableOptions]
  ) -> [SQLDumpDDL.ObjectName: SQLDumpOptions.TableOptions] {
    flags.mapValues {
      var table = $0
      if !table.structure { table.drop = false }
      return table
    }
  }

  private func start() {
    switch kind {
    case .sqlDump:
      let options =
        tables.isEmpty ? SQLDumpOptions() : DatabaseBackupModel.dumpOptions(flags, from: tables)
      Task { await model.exportDump(options: options) }
    case .fileCopy:
      Task { await model.copyDatabaseFile() }
    }
  }

  private func close() {
    guard !model.isBusy else { return }
    isPresented = false
  }
}

/// Result or error text under a backup sheet's form
struct BackupMessageBox: View {
  let text: String
  let isError: Bool

  var body: some View {
    let color: Color = isError ? .destructive : .foreground
    Text(verbatim: text)
      .font(.small)
      .foregroundColor(color)
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(Spacing.md)
      .background(
        (isError ? Color.destructive : Color.accent).opacity(0.1),
        in: RoundedRectangle(cornerRadius: CornerRadius.lg)
      )
      .overlay(
        RoundedRectangle(cornerRadius: CornerRadius.lg)
          .stroke((isError ? Color.destructive : Color.accent).opacity(0.4), lineWidth: 1)
      )
  }
}
