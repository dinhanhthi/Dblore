//
//  MongoIndexesView.swift
//  Dblore
//
//  Indexes section of a MongoDB collection screen: one table row per index (name and key,
//  type, size, usage, properties, build status), read on first show, on Refresh and after each
//  change. Columns a read could not fill (no privilege for the stats) show "—". Create Index
//  opens `MongoCreateIndexSheet`; each row but `_id_` has Hide / Unhide (MongoDB 4.4+) and
//  Drop. Changes go through `MongoAdminActionModel`, whose confirm sheet shows the typed name,
//  the Safe Mode panel and failures; a change sent without asking shows its progress here.
//

import SwiftUI

struct MongoIndexesView: View {
  let model: MongoCollectionModel
  /// The tab: connection, rules and history of the index changes
  let viewModel: NotebookViewModel

  /// The index change asked, running or done last; nil before the first
  @State private var action: MongoAdminActionModel?
  @State private var showsCreate = false

  fileprivate enum Width {
    static let disclosure: CGFloat = 16
    static let nameMin: CGFloat = 160
    static let type: CGFloat = 90
    static let size: CGFloat = 76
    static let usage: CGFloat = 170
    static let properties: CGFloat = 170
    static let status: CGFloat = 84
    static let menu: CGFloat = 20
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Color.appBackground)
    .onAppear {
      model.loadIndexesIfNeeded()
      model.loadServerFeaturesIfNeeded()
    }
    .modalOverlay(isPresented: $showsCreate) {
      if let action, let manager = viewModel.connectionManager {
        MongoCreateIndexSheet(
          collection: model.collection, model: action, manager: manager,
          fieldSource: viewModel.autocompleteProvider, isPresented: $showsCreate)
      }
    }
    .sheet(isPresented: confirmPresented) {
      if let action {
        MongoAdminConfirmSheet(
          model: action, databasePassword: viewModel.notebook.connectionConfig?.password,
          isConnected: viewModel.connectionState == .connected)
      }
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: Spacing.sm) {
      if isRunning {
        ProgressView().controlSize(.small)
        Text("Running...")
          .font(.small)
          .foregroundColor(.foregroundMuted)
      }
      Spacer(minLength: Spacing.sm)
      Button {
        guard let action = viewModel.mongoIndexAdminAction() else { return }
        self.action = action
        showsCreate = true
      } label: {
        Label("Create Index…", systemImage: "plus")
      }
      .buttonStyle(FilledSecondaryButtonStyle())
      .disabled(!canChange)
      .help("Create an index on \(model.collection)")
      Button {
        model.refreshIndexes()
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .buttonStyle(FilledSecondaryButtonStyle())
      .disabled(isLoading || isRunning)
      .help("Read the indexes again")
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
  }

  private var isLoading: Bool {
    if case .loading = model.indexState { return true }
    return false
  }

  private var isRunning: Bool { action?.state == .running }

  /// A collection's indexes are listed and no change is running
  private var canChange: Bool {
    guard case .loaded(.indexes) = model.indexState else { return false }
    return !isRunning
  }

  /// Hide / Unhide need MongoDB 4.4; an unknown version shows them
  private var showsHideToggle: Bool { model.serverFeatures?.hiddenIndexes ?? true }

  private var confirmPresented: Binding<Bool> {
    action.map(MongoAdminConfirmSheet.isPresented) ?? .constant(false)
  }

  /// Sends `command` through a new admin model (gated by the epoch of the list shown)
  private func run(_ command: MongoAdminCommand) {
    guard let action = viewModel.mongoIndexAdminAction() else { return }
    self.action = action
    Task { await action.request(command) }
  }

  // MARK: - States

  @ViewBuilder
  private var content: some View {
    switch model.indexState {
    case .idle, .loading:
      HStack(spacing: Spacing.sm) {
        ProgressView().controlSize(.small)
        Text("Loading indexes...")
          .font(.small)
          .foregroundColor(.foregroundMuted)
      }
    case .loaded(.view):
      message("Views have no indexes")
    case .loaded(.indexes(let indexes)):
      ScrollView {
        table(indexes)
          .padding(.horizontal, Spacing.md)
          .padding(.bottom, Spacing.md)
      }
    case .failed(let text):
      failure(text)
    }
  }

  private func message(_ text: String) -> some View {
    Text(text)
      .font(.small)
      .foregroundColor(.foregroundMuted)
  }

  private func failure(_ text: String) -> some View {
    VStack(spacing: Spacing.sm) {
      Text(text)
        .font(.system(size: 12, design: .monospaced))
        .foregroundColor(.destructive)
        .textSelection(.enabled)
        .multilineTextAlignment(.center)
      Button("Retry") { model.refreshIndexes() }
        .buttonStyle(SecondaryButtonStyle())
    }
    .padding(Spacing.md)
  }

  // MARK: - Table

  private func table(_ indexes: [MongoIndexInfo]) -> some View {
    // The count is on the section tab
    SettingsGroupCard(title: "Indexes", background: .cardBackground, contentPadding: 0) {
      EmptyView()
    } content: {
      VStack(alignment: .leading, spacing: 0) {
        if indexes.isEmpty {
          Text("No indexes")
            .font(.small)
            .foregroundColor(.foregroundMuted)
            .structureTableRow(isFirst: true)
        } else {
          tableHeader
        }
        ForEach(Array(indexes.enumerated()), id: \.element.id) { position, index in
          MongoIndexRow(index: index, isExpanded: expandedBinding(index.name)) {
            rowMenu(index)
          }
          .structureTableRow(isFirst: position == 0)
        }
      }
    }
  }

  private var tableHeader: some View {
    HStack(spacing: Spacing.sm) {
      Color.clear.frame(width: Width.disclosure, height: 0)
      Text("Name & Definition")
        .frame(minWidth: Width.nameMin, maxWidth: .infinity, alignment: .leading)
      Text("Type").frame(width: Width.type, alignment: .leading).structureColumnDivider()
      Text("Size").frame(width: Width.size, alignment: .trailing).structureColumnDivider()
      Text("Usage").frame(width: Width.usage, alignment: .leading).structureColumnDivider()
      Text("Properties").frame(width: Width.properties, alignment: .leading)
        .structureColumnDivider()
      Text("Status").frame(width: Width.status, alignment: .leading).structureColumnDivider()
      Color.clear.frame(width: Width.menu, height: 0)
    }
    .structureTableHeader()
  }

  /// Hide / Unhide and Drop; the `_id_` index can be neither hidden nor dropped
  @ViewBuilder
  private func rowMenu(_ index: MongoIndexInfo) -> some View {
    if index.name == "_id_" {
      Color.clear.frame(width: Width.menu, height: 0)
    } else {
      Menu {
        if showsHideToggle {
          Button(index.isHidden ? "Unhide" : "Hide") {
            run(
              .setIndexHidden(
                collection: model.collection, name: index.name, hidden: !index.isHidden))
          }
          Divider()
        }
        Button("Drop…", role: .destructive) {
          run(.dropIndex(collection: model.collection, index: .string(index.name)))
        }
      } label: {
        Image(systemName: "ellipsis")
          .font(.system(size: 11, weight: .semibold))
          .foregroundColor(.foregroundMuted)
          .frame(width: Width.menu, height: Width.menu)
          .contentShape(Rectangle())
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize()
      .disabled(!canChange)
      .help("Index actions")
      .accessibilityLabel("Actions for \(index.name)")
    }
  }

  private func expandedBinding(_ name: String) -> Binding<Bool> {
    Binding(
      get: { model.expandedIndexes.contains(name) },
      set: { isOn in
        if isOn {
          model.expandedIndexes.insert(name)
        } else {
          model.expandedIndexes.remove(name)
        }
      })
  }
}

// MARK: - Row

private struct MongoIndexRow<Actions: View>: View {
  let index: MongoIndexInfo
  @Binding var isExpanded: Bool
  /// Trailing row menu (`Width.menu` wide)
  @ViewBuilder let actions: () -> Actions

  private typealias Width = MongoIndexesView.Width

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      HStack(spacing: Spacing.sm) {
        disclosure
        nameCell
        IndexChip(text: Self.typeTitle(index.type))
          .frame(width: Width.type, alignment: .leading)
        Text(size)
          .font(.structureField)
          .foregroundColor(.structureCellMuted)
          .monospacedDigit()
          .lineLimit(1)
          .frame(width: Width.size, alignment: .trailing)
        Text(usage)
          .font(.small)
          .foregroundColor(.structureCellMuted)
          .monospacedDigit()
          .lineLimit(1)
          .truncationMode(.tail)
          .help(usage)
          .frame(width: Width.usage, alignment: .leading)
        properties
          .frame(width: Width.properties, alignment: .leading)
        status
          .frame(width: Width.status, alignment: .leading)
        actions()
      }
      if isExpanded {
        definition
          .padding(.leading, Width.disclosure + Spacing.sm)
          .padding(.bottom, Spacing.xs)
      }
    }
  }

  private var disclosure: some View {
    Button {
      isExpanded.toggle()
    } label: {
      Image(systemName: "chevron.right")
        .font(.system(size: 9, weight: .semibold))
        .foregroundColor(.foregroundMuted)
        .rotationEffect(.degrees(isExpanded ? 90 : 0))
        .frame(width: Width.disclosure, height: Width.disclosure)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(isExpanded ? "Hide the key" : "Show the key")
    .accessibilityLabel(isExpanded ? "Collapse \(index.name)" : "Expand \(index.name)")
  }

  /// Name, then the key in one muted line while collapsed
  private var nameCell: some View {
    HStack(spacing: Spacing.sm) {
      Text(index.name)
        .font(.structureField)
        .foregroundColor(.structureCellForeground)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(index.name)
        .layoutPriority(1)
      if !isExpanded {
        Text(keySummary)
          .font(.structureField)
          .foregroundColor(.structureCellMuted)
          .lineLimit(1)
          .truncationMode(.tail)
          .help(keySummary)
      }
    }
    .frame(minWidth: Width.nameMin, maxWidth: .infinity, alignment: .leading)
  }

  /// Key chips in key order, then the partial filter
  private var definition: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: Spacing.xs) {
          ForEach(Array(index.keys.enumerated()), id: \.offset) { _, key in
            Text(Self.keyText(key))
              .font(.monoSmall)
              .foregroundColor(.structureCellForeground)
              .lineLimit(1)
              .padding(.horizontal, Spacing.xsm)
              .padding(.vertical, Spacing.xxs)
              .background(Color.controlBackground, in: Capsule())
              .overlay(HairlineBorder(shape: Capsule()))
          }
        }
      }
      if let filter = index.partialFilter {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
          Text("Partial filter")
            .font(.small)
            .foregroundColor(.foregroundSubtle)
          Text(filter)
            .font(.monoSmall)
            .foregroundColor(.structureCellForeground)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  @ViewBuilder
  private var properties: some View {
    let chips = propertyTitles
    if chips.isEmpty {
      Text("—")
        .font(.small)
        .foregroundColor(.structureCellMuted)
    } else {
      // One line when the chips fit, else stacked
      ViewThatFits(in: .horizontal) {
        HStack(spacing: Spacing.xs) { chipViews(chips) }
        VStack(alignment: .leading, spacing: Spacing.xxs) { chipViews(chips) }
      }
    }
  }

  private func chipViews(_ titles: [String]) -> some View {
    ForEach(titles, id: \.self) { IndexChip(text: $0) }
  }

  @ViewBuilder
  private var status: some View {
    switch index.status {
    case .ready: IndexChip(text: "READY", tint: .success)
    case .building: IndexChip(text: "BUILDING", tint: .warning)
    case nil:
      Text("—")
        .font(.small)
        .foregroundColor(.structureCellMuted)
    }
  }

  // MARK: Text

  private var keySummary: String {
    index.keys.map(Self.keyText).joined(separator: ", ")
  }

  private var size: String {
    guard let size = index.size else { return "—" }
    return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
  }

  private var usage: String {
    guard let ops = index.ops else { return "—" }
    guard let since = index.since else { return ops.formatted() }
    return "\(ops.formatted()) (since \(since.formatted(date: .abbreviated, time: .omitted)))"
  }

  private var propertyTitles: [String] {
    var titles: [String] = []
    if index.isUnique { titles.append("UNIQUE") }
    if index.isSparse { titles.append("SPARSE") }
    if let ttl = index.ttlSeconds { titles.append("TTL \(Self.duration(ttl))") }
    if index.partialFilter != nil { titles.append("PARTIAL") }
    if index.isHidden { titles.append("HIDDEN") }
    return titles
  }

  /// `field ↑` for 1, `field ↓` for -1, else `field kind` (text, 2dsphere, hashed…)
  private static func keyText(_ key: MongoIndexInfo.KeyPart) -> String {
    switch key.kind {
    case "1": "\(key.field) ↑"
    case "-1": "\(key.field) ↓"
    default: "\(key.field) \(key.kind)"
    }
  }

  private static func typeTitle(_ type: MongoIndexInfo.IndexType) -> String {
    switch type {
    case .regular: "REGULAR"
    case .compound: "COMPOUND"
    case .text: "TEXT"
    case .geo2dsphere: "2DSPHERE"
    case .geo2d: "2D"
    case .hashed: "HASHED"
    case .wildcard: "WILDCARD"
    }
  }

  /// Whole days, hours or minutes when the seconds divide evenly, else seconds
  private static func duration(_ seconds: Int) -> String {
    for (unit, suffix) in [(86_400, "d"), (3_600, "h"), (60, "m")]
    where seconds >= unit && seconds % unit == 0 {
      return "\(seconds / unit)\(suffix)"
    }
    return "\(seconds)s"
  }
}

/// Small uppercase label of an index type, property or status
private struct IndexChip: View {
  let text: String
  var tint: Color = .foregroundMuted

  var body: some View {
    Text(text)
      .font(.smallest)
      .fontWeight(.medium)
      .foregroundColor(tint)
      .lineLimit(1)
      .padding(.horizontal, Spacing.xsm)
      .padding(.vertical, Spacing.xxs)
      .background(Capsule().fill(tint.opacity(0.12)))
      .fixedSize()
  }
}
