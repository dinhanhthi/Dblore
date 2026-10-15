import Foundation
import SwiftUI

/// Export SQL Dump (tables and data on or off, then a save panel) and, for SQLite, Copy
/// Database File. Both run off the main actor with progress and Cancel.
struct SQLDumpSheet: View {
  enum Kind {
    case sqlDump
    case fileCopy
  }

  let kind: Kind
  /// Loaded schema tables, offered in the table list (all chosen by default)
  let tables: [DatabaseTable]
  @Binding var isPresented: Bool
  @Binding var isBusy: Bool

  @State private var model: DatabaseBackupModel
  @State private var selected: Set<SQLDumpDDL.ObjectName>
  @State private var includeData = true

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
    _selected = State(initialValue: Set(tables.map(Self.objectName)))
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
        .disabled(model.isBusy || (kind == .sqlDump && !tables.isEmpty && selected.isEmpty))
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
        HStack(spacing: Spacing.sm) {
          Text("\(selected.count) of \(tables.count) selected")
            .font(.small)
            .foregroundColor(.foregroundMuted)
          Spacer()
          Button("Select All") { selected = Set(tables.map(Self.objectName)) }
            .buttonStyle(GhostButtonStyle())
          Button("Select None") { selected = [] }
            .buttonStyle(GhostButtonStyle())
        }
        ScrollView {
          LazyVStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(tables) { table in
              Toggle(isOn: binding(for: table)) {
                Text(verbatim: showsSchema ? "\(table.schema).\(table.name)" : table.name)
                  .font(.monoMedium)
                  .foregroundColor(.foreground)
                  .lineLimit(1)
                  .truncationMode(.middle)
              }
              .toggleStyle(.checkbox)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 220)
        .disabled(model.isBusy)
        Text(
          "Views on tables left out are left out too. A table whose foreign key points to a "
            + "table left out does not restore on its own."
        )
        .font(.small)
        .foregroundColor(.foregroundMuted)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var optionsSection: some View {
    SettingsGroupCard(title: "Options") {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        Toggle("Include data (INSERT statements)", isOn: $includeData)
          .toggleStyle(.checkbox)
          .font(.bodyText)
          .disabled(model.isBusy)
        Text(
          "The dump reads everything in one snapshot on its own connection. It holds your data "
            + "as plain text: keep the file somewhere safe."
        )
        .font(.small)
        .foregroundColor(.foregroundMuted)
        .fixedSize(horizontal: false, vertical: true)
        Text(
          "Not included: functions, procedures, extensions, roles, ownership and grants. "
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

  private func binding(for table: DatabaseTable) -> Binding<Bool> {
    let name = Self.objectName(table)
    return Binding(
      get: { selected.contains(name) },
      set: { if $0 { selected.insert(name) } else { selected.remove(name) } })
  }

  private func start() {
    switch kind {
    case .sqlDump:
      let options = DatabaseBackupModel.dumpOptions(
        selected: selected, from: tables, includeData: includeData)
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
