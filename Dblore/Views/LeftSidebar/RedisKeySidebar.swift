//
//  RedisKeySidebar.swift
//  Dblore
//
//  The Public tab of a Redis workspace: a MATCH filter, then one row per database (0–15 and any
//  other `INFO keyspace` names) with its key count; an open database lists its keys as a tree
//  split on `:` (`RedisKeyBrowserModel`), with "Load more" while `SCAN` has more. A click on a
//  key selects it and shows it in the key preview tab in the same frame, a double click keeps
//  that tab; nothing is read for it here. Opening a database never changes the db the command
//  tabs run in.
//

import SwiftUI

struct RedisKeySidebar: View {
  let model: RedisKeyBrowserModel
  let workspaceManager: WorkspaceManager

  var body: some View {
    VStack(spacing: 0) {
      SidebarFilterField(
        text: Binding(get: { model.pattern }, set: { model.setPattern($0) }),
        placeholder: "match pattern, e.g. user:*", trailingSpacing: Spacing.xs
      ) {
        Button {
          model.refresh()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(GhostButtonStyle(iconOnly: true))
        .controlSize(.small)
        .help("Reload Keys")
        .accessibilityLabel("Reload Keys")
      }

      if model.databases.isEmpty {
        if model.isLoadingDatabases {
          DelayedProgressRow(text: "Loading databases...")
        }
        Spacer()
      } else {
        ScrollView {
          // One flat lazy stack: every header, key row and note is its own item, so only the
          // rows on screen are built (a db's rows nested in one item would all be)
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
              itemView(item)
            }
          }
          .padding(.vertical, Spacing.sm)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    // Another key tab picked in the tab bar: its key is the selected row
    .background { RedisActiveKeySync(model: model, workspaceManager: workspaceManager) }
    // An unstructured task: leaving the tab must not cancel a read half way
    .onAppear {
      let connection = workspaceManager.connectionManager
      let homeDatabase =
        workspaceManager.workspace.connectionConfig.flatMap { Int($0.database) } ?? 0
      let policy = Self.policy(of: workspaceManager)
      Task {
        await model.open(manager: connection, policy: policy, homeDatabase: homeDatabase)
      }
    }
  }

  /// The command tabs' policy (the active tab's), or the connection's when no tab is open
  private static func policy(
    of workspaceManager: WorkspaceManager
  ) -> @MainActor () -> ProtectionPolicy {
    { [weak workspaceManager] in
      workspaceManager?.activeViewModel?.protectionPolicy
        ?? ProtectionPolicy(config: workspaceManager?.workspace.connectionConfig)
    }
  }

  /// One item of the flat list: exactly one view each, so the lazy stack stays lazy
  private enum Item: Identifiable {
    enum NoteKind: Hashable { case empty, error, capped }
    enum ID: Hashable {
      case databasesError
      case header(Int)
      case node(RedisKeyBrowserModel.NodeID)
      case progress(Int)
      case note(Int, NoteKind)
      case loadMore(Int)
    }

    case databasesError(String)
    case header(RedisKeyBrowserModel.Database, isOpen: Bool, isFirst: Bool)
    case node(RedisKeyBrowserModel.Row)
    /// One id for both "Scanning" cases, so its 150 ms delay does not restart
    case progress(db: Int)
    case note(db: Int, kind: NoteKind, text: String)
    case loadMore(db: Int, isRetry: Bool)

    var id: ID {
      switch self {
      case .databasesError: .databasesError
      case .header(let database, _, _): .header(database.index)
      case .node(let row): .node(row.id)
      case .progress(let db): .progress(db)
      case .note(let db, let kind, _): .note(db, kind)
      case .loadMore(let db, _): .loadMore(db)
      }
    }
  }

  /// Every db's header, then an open db's rows and notes. The rows are cached in the model and
  /// the selection is read only in `RedisKeyRowHost`, so a click re-runs none of this.
  private var items: [Item] {
    var items: [Item] = []
    if let error = model.databasesError {
      items.append(.databasesError("Key counts unavailable: \(error)"))
    }
    for database in model.databases {
      let db = database.index
      let isOpen = model.expandedDatabases.contains(db)
      items.append(.header(database, isOpen: isOpen, isFirst: items.isEmpty))
      guard isOpen else { continue }
      items.append(contentsOf: model.rows(db: db).map(Item.node))
      guard let listing = model.listings[db] else {
        items.append(.progress(db: db))
        continue
      }
      if listing.isLoading {
        items.append(.progress(db: db))
      } else if listing.keys.isEmpty && listing.isComplete && listing.error == nil {
        items.append(
          .note(db: db, kind: .empty, text: model.pattern.isEmpty ? "No keys" : "No matching keys"))
      }
      if let error = listing.error {
        items.append(.note(db: db, kind: .error, text: error))
      }
      if listing.isCapped && !listing.isComplete {
        items.append(
          .note(
            db: db, kind: .capped,
            text: "Showing the first \(RedisKeyBrowserModel.maxKeysPerDatabase.formatted()) keys. "
              + "Narrow the match pattern to see others."))
      } else if listing.canLoadMore {
        items.append(.loadMore(db: db, isRetry: listing.error != nil))
      }
    }
    return items
  }

  @ViewBuilder
  private func itemView(_ item: Item) -> some View {
    switch item {
    case .databasesError(let text):
      note(text)
    case .header(let database, let isOpen, let isFirst):
      RedisDatabaseHeader(
        title: "db\(database.index)", count: database.keyCount, isOpen: isOpen
      ) {
        withAnimation(.snappy(duration: 0.2)) {
          model.setDatabase(database.index, expanded: !isOpen)
        }
      }
      .padding(.top, isFirst ? 0 : Spacing.sm)
    case .node(let row):
      RedisKeyRowHost(
        model: model, row: row, onTap: { tap(row.id) }, onDoubleTap: { doubleTap(row.id) }
      )
      .modifier(DatabaseContentIndent())
    case .progress:
      DelayedProgressRow(text: "Scanning keys...")
        .modifier(DatabaseContentIndent())
    case .note(_, _, let text):
      note(text)
        .modifier(DatabaseContentIndent())
    case .loadMore(let db, let isRetry):
      Button(isRetry ? "Retry" : "Load more") {
        Task { await model.loadPage(db: db) }
      }
      .buttonStyle(SecondaryButtonStyle())
      .controlSize(.small)
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.xs)
      .modifier(DatabaseContentIndent())
    }
  }

  /// A folder opens or closes; a key is selected and shown in the key preview tab at once
  private func tap(_ id: RedisKeyBrowserModel.NodeID) {
    switch id {
    case .folder: model.toggleFolder(id)
    case .key(let key):
      model.select(key)
      workspaceManager.openRedisKey(key)
    }
  }

  /// After the single click's open: the key's tab is kept (a folder ignores it)
  private func doubleTap(_ id: RedisKeyBrowserModel.NodeID) {
    guard case .key(let key) = id else { return }
    workspaceManager.pinRedisKey(key)
  }

  private func note(_ text: String) -> some View {
    Text(text)
      .font(.caption)
      .foregroundColor(.foregroundMuted)
      .lineLimit(3)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.xs)
  }
}

/// A database's header, drawn as an `EntitySection` header (chevron, icon, name, count)
private struct RedisDatabaseHeader: View {
  let title: String
  let count: Int?
  let isOpen: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: Spacing.xs) {
        Image(systemName: "chevron.right")
          .font(.system(size: 10, weight: .semibold))
          .foregroundColor(.foregroundMuted)
          .frame(width: 12, height: 12)
          .rotationEffect(.degrees(isOpen ? 90 : 0))

        Image(systemName: "cylinder")
          .font(.system(size: 12))
          .foregroundColor(.accent)

        Text(title)
          .font(.monoMedium)
          .foregroundColor(.foreground)

        if let count {
          Text("(\(count))")
            .font(.monoSmall)
            .foregroundColor(.foregroundSubtle)
        }

        Spacer()
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.xs)
    }
    .buttonStyle(.plain)
    .linkPointer()
  }
}

/// A db's content row: indented under its header with the guide line of `EntitySection`, drawn
/// per row (the rows are siblings, spaced 0, so the line reads as one)
private struct DatabaseContentIndent: ViewModifier {
  func body(content: Content) -> some View {
    content
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.leading, Spacing.lg)
      .overlay(alignment: .leading) {
        Rectangle()
          .fill(Color.foregroundSubtle.opacity(0.2))
          .frame(width: 1)
          .padding(.leading, Spacing.md + 6)  // Align with the header's chevron center
      }
  }
}

/// Selects the active key tab's key in the tree. Its own body reads the tabs, so a tab change
/// re-runs only this empty view, never the list.
private struct RedisActiveKeySync: View {
  let model: RedisKeyBrowserModel
  let workspaceManager: WorkspaceManager

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .onChange(of: workspaceManager.activeRedisKey) { _, key in
        if let key { model.select(key) }
      }
  }
}

/// Reads the selection for one row, so a click re-runs only this tiny body per row and redraws
/// only the rows whose `isSelected` changed
private struct RedisKeyRowHost: View {
  let model: RedisKeyBrowserModel
  let row: RedisKeyBrowserModel.Row
  let onTap: () -> Void
  let onDoubleTap: () -> Void

  var body: some View {
    let isSelected: Bool
    if case .key(let key) = row.id {
      isSelected = model.selectedKey == key
    } else {
      isSelected = false
    }
    return RedisKeyRow(
      row: row, isSelected: isSelected, onTap: onTap, onDoubleTap: onDoubleTap
    )
    .equatable()
  }
}

/// One folder or key of the tree, drawn as the table rows of the SQL sidebar. Equal by its row
/// and selection (the tap actions never change for a row id), so an unchanged row is not redrawn.
private struct RedisKeyRow: View, Equatable {
  let row: RedisKeyBrowserModel.Row
  let isSelected: Bool
  let onTap: () -> Void
  let onDoubleTap: () -> Void

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.row == rhs.row && lhs.isSelected == rhs.isSelected
  }

  @State private var isHovering = false

  private var isFolder: Bool { row.folderKeyCount != nil }

  var body: some View {
    HStack(spacing: Spacing.xs) {
      Image(systemName: "chevron.right")
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(.foregroundMuted)
        .frame(width: 12, height: 12)
        .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
        .opacity(isFolder ? 1 : 0)

      Image(systemName: isFolder ? "folder" : "key")
        .font(.system(size: 12))
        .foregroundColor(.accent)

      // An empty segment (`a::b`, the empty key) gets a visible placeholder
      Text(row.label.isEmpty ? "(empty)" : row.label)
        .font(.monoMedium)
        .foregroundColor(row.label.isEmpty ? .foregroundSubtle : .foreground)
        .lineLimit(1)
        .truncationMode(.middle)

      if let count = row.folderKeyCount {
        Text("(\(count))")
          .font(.monoSmall)
          .foregroundColor(.foregroundSubtle)
      }

      Spacer(minLength: 0)
    }
    .padding(.leading, CGFloat(row.depth) * Spacing.md)
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.xs)
    .contentShape(Rectangle())
    // The single click acts at once; the double click adds to it (never an exclusive pair,
    // which would hold every click until the double-click interval ends)
    .onTapGesture(perform: onTap)
    .simultaneousGesture(TapGesture(count: 2).onEnded { onDoubleTap() })
    .background(
      RoundedRectangle(cornerRadius: CornerRadius.sm)
        .fill(isSelected ? Color.selectionFill : (isHovering ? Color.hoverFill : Color.clear))
    )
    .onHover { hovering in
      isHovering = hovering
      if hovering {
        NSCursor.pointingHand.push()
      } else {
        NSCursor.pop()
      }
    }
    // A key's whole name, a folder's segment: escaped and cut when the tree was built
    .help(row.tooltip)
  }
}

/// A read's progress, shown ~150 ms after it starts, so a quick read does not flash it
private struct DelayedProgressRow: View {
  let text: String
  @State private var isShown = false

  var body: some View {
    VStack(spacing: 0) {
      // Keeps the row on screen (and its task running) before it shows
      Color.clear.frame(height: 0)
      if isShown {
        HStack(spacing: Spacing.sm) {
          ProgressView()
            .controlSize(.small)
            .tint(.accent)
          Text(text)
            .font(.caption)
            .foregroundColor(.foregroundMuted)
          Spacer()
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs)
        .transition(.opacity)
      }
    }
    .animation(.easeIn(duration: 0.15), value: isShown)
    // Opt out of the app-wide animation kill switch, only for the fade
    .transaction(value: isShown) { $0.disablesAnimations = false }
    .task {
      // A cancelled sleep must not show the row after it disappeared
      guard (try? await Task.sleep(for: .milliseconds(150))) != nil else { return }
      isShown = true
    }
  }
}
