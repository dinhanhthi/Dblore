//
//  DatabaseEntityRows.swift
//  Dblore
//
//  Row views for database entities: Tables, Views, Functions, Procedures, Triggers, Sequences,
//  Types, and Columns. Table and view rows also offer the sidebar folder moves and drag onto a
//  folder (`SidebarFolderRows.swift`).
//

import SwiftUI

// MARK: - Table Row View

struct TableRowView: View {
  let table: DatabaseTable
  let isExpanded: Bool
  /// Shown in the active data viewer tab
  var isSelected = false
  /// Connection type; its default schema is omitted from the row label
  var databaseType: DatabaseType = .postgresql
  /// False when the row sits under its schema group (the label would repeat it)
  var showsSchema = true
  let onToggle: () -> Void
  let onOpen: () -> Void
  let onColumnClick: (String) -> Void
  /// Nil hides "Import Data..." (the engine has no table import)
  let onImport: (() -> Void)?
  /// Nil hides "Import Files..." (several files, the one file going into this table)
  var onImportFiles: (() -> Void)? = nil
  /// Nil hides "Generate Rows..." (the engine has no row staging)
  var onGenerateRows: (() -> Void)? = nil
  /// Title of the structure menu item (`SidebarSectionModel.structureMenuTitle`). Nil hides it.
  var structureMenuTitle: String? = nil
  var onEditStructure: () -> Void = {}
  /// Menu items of a MongoDB collection, or an SQL table's Build Join Query From Here, Rename and
  /// Drop Table (after the structure item)
  var menuActions: [SidebarSectionModel.RowAction] = []
  var onMenuAction: (SidebarSectionModel.RowAction) -> Void = { _ in }
  /// Move to Folder and Remove from Folder, and the drag onto a folder. Nil offers neither.
  var folderActions: SidebarFolderActions? = nil

  @State private var isHoveringTable = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Table row
      HStack(spacing: Spacing.xs) {
        // Expand/collapse chevron
        Image(systemName: "chevron.right")
          .font(.system(size: 10, weight: .semibold))
          .foregroundColor(.foregroundMuted)
          .frame(width: 12, height: 12)
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
          // Larger hit area; negative padding keeps the 12pt layout footprint
          .frame(width: 20, height: 20)
          .contentShape(Rectangle())
          .padding(-Spacing.xs)
          .onTapGesture {
            onToggle()
          }

        // Table icon
        Image(systemName: "tablecells")
          .font(.system(size: 12))
          .foregroundColor(.accent)

        // Table name
        HStack(spacing: Spacing.xs) {
          Text(table.name)
            .font(.monoMedium)
            .foregroundColor(.foreground)

          if showsSchema && !table.schema.isEmpty
            && table.schema != databaseType.dialect.defaultSchema
          {
            Text("(\(table.schema))")
              .font(.monoSmall)
              .foregroundColor(.foregroundSubtle)
          }

          ForEach(collectionFlagTitles, id: \.self) { CollectionFlagBadge(text: $0) }

          Spacer()

          // Row count badge
          if let estimate = compactRowEstimate(table.rowCount) {
            Text(estimate)
              .font(.system(.caption2))
              .foregroundColor(.foregroundSubtle)
              .padding(.horizontal, Spacing.xs)
              .padding(.vertical, 1)
              .background(
                RoundedRectangle(cornerRadius: 3)
                  .fill(Color.inputBackground)
              )
              .help("Estimated row count (from table statistics)")
          }
        }
      }
      .contentShape(Rectangle())
      .onTapGesture {
        onOpen()
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.xs)
      .background(
        RoundedRectangle(cornerRadius: CornerRadius.sm)
          .fill(
            isSelected
              ? Color.selectionFill
              : (isHoveringTable ? Color.hoverFill : Color.clear))
      )
      .onHover { hovering in
        isHoveringTable = hovering
        if hovering {
          NSCursor.pointingHand.push()
        } else {
          NSCursor.pop()
        }
      }
      .contextMenu {
        let language = databaseType.capabilities.queryLanguage
        if language == .mongosh {
          RowActionButtons(actions: menuActions, language: language, onAction: onMenuAction)
        }
        if let onImport {
          Button("Import Data...", action: onImport)
        }
        if let onImportFiles {
          Button("Import Files...", action: onImportFiles)
        }
        if let onGenerateRows {
          Button("Generate Rows...", action: onGenerateRows)
        }
        if let structureMenuTitle {
          Button(structureMenuTitle, action: onEditStructure)
        }
        if language == .sql, !menuActions.isEmpty {
          Divider()
          RowActionButtons(actions: menuActions, language: language, onAction: onMenuAction)
        }
        if let folderActions {
          Divider()
          SidebarFolderMenuItems(actions: folderActions)
        }
      }
      .sidebarFolderDrag(folderActions)

      // Columns (when expanded)
      if isExpanded {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(table.columns) { column in
            ColumnRowView(
              column: column,
              onClick: {
                onColumnClick(column.name)
              }
            )
          }
        }
        .padding(.leading, Spacing.lg)
        .overlay(alignment: .leading) {
          Rectangle()
            .fill(Color.foregroundSubtle.opacity(0.2))
            .frame(width: 1)
            .padding(.leading, Spacing.md + 6)  // Align with chevron center
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .clipped()
  }

  /// Badges of a MongoDB collection's markers, in a fixed order
  private var collectionFlagTitles: [String] {
    let flags = table.collectionFlags
    return [
      (DatabaseTable.CollectionFlags.capped, "capped"), (.timeSeries, "time series"),
      (.clustered, "clustered"),
    ].filter { flags.contains($0.0) }.map(\.1)
  }
}

/// Small marker beside a collection name (capped, time series, clustered), also used by the
/// MongoDB overview screens (view, current database)
struct CollectionFlagBadge: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.system(.caption2))
      .foregroundColor(.foregroundMuted)
      .lineLimit(1)
      .padding(.horizontal, Spacing.xs)
      .padding(.vertical, 1)
      .background(
        RoundedRectangle(cornerRadius: 3)
          .fill(Color.foregroundMuted.opacity(0.12))
      )
      .fixedSize()
  }
}

// MARK: - View Row View

struct ViewRowView: View {
  let view: DatabaseView
  let isExpanded: Bool
  /// Shown in the active data viewer tab
  var isSelected = false
  /// Connection type; its default schema is omitted from the row label
  var databaseType: DatabaseType = .postgresql
  /// False when the row sits under its schema group (the label would repeat it)
  var showsSchema = true
  let onToggle: () -> Void
  let onOpen: () -> Void
  let onColumnClick: (String) -> Void
  /// Menu items of a MongoDB view (SQL views have no menu)
  var menuActions: [SidebarSectionModel.RowAction] = []
  var onMenuAction: (SidebarSectionModel.RowAction) -> Void = { _ in }
  /// Move to Folder and Remove from Folder, and the drag onto a folder. Nil offers neither.
  var folderActions: SidebarFolderActions? = nil

  @State private var isHovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // View row
      HStack(spacing: Spacing.xs) {
        // Expand/collapse chevron
        Image(systemName: "chevron.right")
          .font(.system(size: 10, weight: .semibold))
          .foregroundColor(.foregroundMuted)
          .frame(width: 12, height: 12)
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
          // Larger hit area; negative padding keeps the 12pt layout footprint
          .frame(width: 20, height: 20)
          .contentShape(Rectangle())
          .padding(-Spacing.xs)
          .onTapGesture {
            onToggle()
          }

        // View icon
        Image(systemName: "eye")
          .font(.system(size: 12))
          .foregroundColor(.accent)

        // View name
        HStack(spacing: Spacing.xs) {
          Text(view.name)
            .font(.monoMedium)
            .foregroundColor(.foreground)

          if showsSchema && !view.schema.isEmpty
            && view.schema != databaseType.dialect.defaultSchema
          {
            Text("(\(view.schema))")
              .font(.monoSmall)
              .foregroundColor(.foregroundSubtle)
          }

          Spacer()
        }
      }
      .contentShape(Rectangle())
      .onTapGesture {
        onOpen()
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.xs)
      .background(
        RoundedRectangle(cornerRadius: CornerRadius.sm)
          .fill(
            isSelected
              ? Color.selectionFill
              : (isHovering ? Color.hoverFill : Color.clear))
      )
      .onHover { hovering in
        isHovering = hovering
        if hovering {
          NSCursor.pointingHand.push()
        } else {
          NSCursor.pop()
        }
      }
      .contextMenu {
        RowActionButtons(
          actions: menuActions, language: databaseType.capabilities.queryLanguage,
          onAction: onMenuAction)
        if let folderActions {
          if !menuActions.isEmpty { Divider() }
          SidebarFolderMenuItems(actions: folderActions)
        }
      }
      .sidebarFolderDrag(folderActions)

      // Columns (when expanded)
      if isExpanded {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(view.columns) { column in
            ColumnRowView(
              column: column,
              onClick: {
                onColumnClick(column.name)
              }
            )
          }
        }
        .padding(.leading, Spacing.lg)
        .overlay(alignment: .leading) {
          Rectangle()
            .fill(Color.foregroundSubtle.opacity(0.2))
            .frame(width: 1)
            .padding(.leading, Spacing.md + 6)  // Align with chevron center
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .clipped()
  }
}

/// Context menu buttons for `actions`, in order, a divider above the destructive Drop. No
/// actions renders nothing.
private struct RowActionButtons: View {
  let actions: [SidebarSectionModel.RowAction]
  let language: SidebarSectionModel.QueryLanguage
  let onAction: (SidebarSectionModel.RowAction) -> Void

  var body: some View {
    ForEach(actions.indices, id: \.self) { index in
      if index > 0 && actions[index] == .drop { Divider() }
      Button(actions[index].title(for: language)) { onAction(actions[index]) }
    }
  }
}

// MARK: - Function Row View

struct FunctionRowView: View {
  let function: DatabaseFunction
  let isExpanded: Bool
  let onToggle: () -> Void
  /// Opens the definition in a read-only tab
  let onViewSource: () -> Void

  @State private var isHovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Function row
      HStack(alignment: .top, spacing: Spacing.xs) {
        // Expand/collapse chevron
        Image(systemName: "chevron.right")
          .font(.system(size: 10, weight: .semibold))
          .foregroundColor(.foregroundMuted)
          .frame(width: 12, height: 12)
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
          .padding(.top, 2)  // Fine-tune alignment with text

        // Function icon
        Image(systemName: "function")
          .font(.system(size: 12))
          .foregroundColor(.accent)
          .padding(.top, 2)  // Fine-tune alignment with text

        // Function signature
        VStack(alignment: .leading, spacing: 2) {
          Text(function.name)
            .font(.monoMedium)
            .foregroundColor(.foreground)

          if !function.arguments.isEmpty {
            Text("(\(function.arguments))")
              .font(.monoSmall)
              .foregroundColor(.foregroundSubtle)
              .lineLimit(1)
          }
        }

        Spacer()
      }
      .contentShape(Rectangle())
      .onTapGesture {
        onToggle()
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.xs)
      .background(
        RoundedRectangle(cornerRadius: CornerRadius.sm)
          .fill(isHovering ? Color.hoverFill : Color.clear)
      )
      .onHover { hovering in
        isHovering = hovering
        if hovering {
          NSCursor.pointingHand.push()
        } else {
          NSCursor.pop()
        }
      }
      .contextMenu {
        Button("View Source", action: onViewSource)
      }

      // Details (when expanded)
      if isExpanded {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          HStack {
            Text("Returns:")
              .font(.monoSmall)
              .foregroundColor(.foregroundMuted)
            Text(function.returnType)
              .font(.monoSmall)
              .foregroundColor(.foreground)
          }
          .padding(.leading, Spacing.lg)
          .padding(.horizontal, Spacing.md)
        }
        .overlay(alignment: .leading) {
          Rectangle()
            .fill(Color.foregroundSubtle.opacity(0.2))
            .frame(width: 1)
            .padding(.leading, Spacing.md + 6)  // Align with chevron center
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .clipped()
  }
}

// MARK: - Procedure Row View

struct ProcedureRowView: View {
  let procedure: DatabaseProcedure
  let isExpanded: Bool
  let onToggle: () -> Void
  /// Opens the definition in a read-only tab
  let onViewSource: () -> Void

  @State private var isHovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Procedure row
      HStack(alignment: .top, spacing: Spacing.xs) {
        // Expand/collapse chevron
        Image(systemName: "chevron.right")
          .font(.system(size: 10, weight: .semibold))
          .foregroundColor(.foregroundMuted)
          .frame(width: 12, height: 12)
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
          .padding(.top, 2)  // Fine-tune alignment with text

        // Procedure icon
        Image(systemName: "gearshape.2")
          .font(.system(size: 12))
          .foregroundColor(.accent)
          .padding(.top, 2)  // Fine-tune alignment with text

        // Procedure signature
        VStack(alignment: .leading, spacing: 2) {
          Text(procedure.name)
            .font(.monoMedium)
            .foregroundColor(.foreground)

          if !procedure.arguments.isEmpty {
            Text("(\(procedure.arguments))")
              .font(.monoSmall)
              .foregroundColor(.foregroundSubtle)
              .lineLimit(1)
          }
        }

        Spacer()
      }
      .contentShape(Rectangle())
      .onTapGesture {
        onToggle()
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.xs)
      .background(
        RoundedRectangle(cornerRadius: CornerRadius.sm)
          .fill(isHovering ? Color.hoverFill : Color.clear)
      )
      .onHover { hovering in
        isHovering = hovering
        if hovering {
          NSCursor.pointingHand.push()
        } else {
          NSCursor.pop()
        }
      }
      .contextMenu {
        Button("View Source", action: onViewSource)
      }
    }
  }
}

// MARK: - Trigger Row View

/// A trigger with its table and firing events. A click opens its definition read-only.
struct TriggerRowView: View {
  let trigger: DatabaseTrigger
  let onViewSource: () -> Void

  @State private var isHovering = false

  var body: some View {
    HStack(alignment: .top, spacing: Spacing.xs) {
      Image(systemName: ObjectSourceRef.Kind.trigger.iconName)
        .font(.system(size: 12))
        .foregroundColor(trigger.enabled ? .accent : .foregroundSubtle)
        .frame(width: 12)
        .padding(.top, 2)  // Fine-tune alignment with text
        .padding(.leading, 12 + Spacing.xs)  // Align with chevron rows

      VStack(alignment: .leading, spacing: 2) {
        Text(trigger.name)
          .font(.monoMedium)
          .foregroundColor(.foreground)

        Text(trigger.sidebarSubtitle)
          .font(.monoSmall)
          .foregroundColor(.foregroundSubtle)
          .lineLimit(1)
      }

      Spacer()
    }
    .contentShape(Rectangle())
    .onTapGesture {
      onViewSource()
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.xs)
    .background(
      RoundedRectangle(cornerRadius: CornerRadius.sm)
        .fill(isHovering ? Color.hoverFill : Color.clear)
    )
    .onHover { hovering in
      isHovering = hovering
      if hovering {
        NSCursor.pointingHand.push()
      } else {
        NSCursor.pop()
      }
    }
    .contextMenu {
      Button("View Source", action: onViewSource)
    }
    .help(trigger.sidebarSubtitle)
  }
}

// MARK: - Sequence and Type Rows

/// A sequence (data type, owning column). A click opens its DDL read-only.
struct SequenceRowView: View {
  let sequence: DatabaseSequence
  let onShowDDL: () -> Void
  let onCopyName: () -> Void

  var body: some View {
    CatalogObjectRow(
      name: sequence.name, subtitle: subtitle, icon: ObjectSourceRef.Kind.sequence.iconName,
      onShowDDL: onShowDDL, onCopyName: onCopyName)
  }

  /// "integer · owned by orders.id", "bigint · identity of orders.id"
  private var subtitle: String {
    guard let owner = sequence.ownedBy else { return sequence.dataType }
    let role = sequence.isIdentity ? "identity of" : "owned by"
    return "\(sequence.dataType) · \(role) \(owner.table).\(owner.column)"
  }
}

/// An enum, domain or composite type. A click opens its DDL read-only.
struct UserTypeRowView: View {
  let type: DatabaseUserType
  let onShowDDL: () -> Void
  let onCopyName: () -> Void

  var body: some View {
    CatalogObjectRow(
      name: type.name, subtitle: subtitle, icon: ObjectSourceRef.Kind.userType.iconName,
      onShowDDL: onShowDDL, onCopyName: onCopyName)
  }

  /// "enum · 3 labels", "domain over integer", "composite · 2 attributes"
  private var subtitle: String {
    switch type.kind {
    case .enum(let labels): "enum · \(counted(labels.count, "label"))"
    case .domain(let baseType, _, _, _): "domain over \(baseType)"
    case .composite(let attributes): "composite · \(counted(attributes.count, "attribute"))"
    }
  }

  private func counted(_ count: Int, _ noun: String) -> String {
    "\(count) \(noun)\(count == 1 ? "" : "s")"
  }
}

/// Name and subtitle of a sequence or type, with Show DDL and Copy Name
private struct CatalogObjectRow: View {
  let name: String
  let subtitle: String
  let icon: String
  let onShowDDL: () -> Void
  let onCopyName: () -> Void

  @State private var isHovering = false

  var body: some View {
    HStack(alignment: .top, spacing: Spacing.xs) {
      Image(systemName: icon)
        .font(.system(size: 12))
        .foregroundColor(.accent)
        .frame(width: 12)
        .padding(.top, 2)  // Fine-tune alignment with text
        .padding(.leading, 12 + Spacing.xs)  // Align with chevron rows

      VStack(alignment: .leading, spacing: 2) {
        Text(name)
          .font(.monoMedium)
          .foregroundColor(.foreground)

        Text(subtitle)
          .font(.monoSmall)
          .foregroundColor(.foregroundSubtle)
          .lineLimit(1)
      }

      Spacer()
    }
    .contentShape(Rectangle())
    .onTapGesture {
      onShowDDL()
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.xs)
    .background(
      RoundedRectangle(cornerRadius: CornerRadius.sm)
        .fill(isHovering ? Color.hoverFill : Color.clear)
    )
    .onHover { hovering in
      isHovering = hovering
      if hovering {
        NSCursor.pointingHand.push()
      } else {
        NSCursor.pop()
      }
    }
    .contextMenu {
      Button("Show DDL", action: onShowDDL)
      Button("Copy Name", action: onCopyName)
    }
    .help(subtitle)
  }
}

/// Loading, failure (with Retry) or empty state of a section read on expand. Unread shows
/// Loading: the row appearing (each time the section opens) starts the read, and a lazy stack
/// never shows a zero-size row. Back to Loading (a reset on disconnect) starts it again.
struct CatalogStatusRow: View {
  let status: CatalogStatus
  /// Starts the read when needed, in a task of its own: collapsing does not cancel it
  let onAppear: () -> Void
  let onRetry: () -> Void

  var body: some View {
    // A stack, not a Group: the handlers stay on one view while the state below changes, so a
    // failed read is not started again by the error row appearing
    VStack(alignment: .leading, spacing: 0) {
      switch status {
      case .loading:
        HStack(spacing: Spacing.xs) {
          ProgressView()
            .controlSize(.small)
          Text("Loading…")
            .font(.monoSmall)
            .foregroundColor(.foregroundSubtle)
        }
      case .failed(let error):
        HStack(spacing: Spacing.xs) {
          Text(error)
            .font(.monoSmall)
            .foregroundColor(.foregroundSubtle)
            .lineLimit(2)
            .help(error)
          Button("Retry", action: onRetry)
            .buttonStyle(GhostButtonStyle())
            .controlSize(.small)
        }
      case .empty:
        Text("None")
          .font(.monoSmall)
          .foregroundColor(.foregroundSubtle)
      case .rows:
        Color.clear.frame(height: 0)
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, status == .rows ? 0 : Spacing.xs)
    .onAppear(perform: onAppear)
    .onChange(of: status) { _, status in
      if status == .loading { onAppear() }
    }
  }
}

// MARK: - Column Row View

struct ColumnRowView: View {
  let column: DatabaseColumn
  let onClick: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: onClick) {
      HStack(spacing: Spacing.xs) {
        // Column icon
        Image(systemName: column.typeIcon)
          .font(.system(size: 10))
          .foregroundColor(column.isPrimaryKey ? .warning : .foregroundSubtle)
          .frame(width: 12)

        // Column name
        Text(column.name)
          .font(.monoSmall)
          .foregroundColor(.foregroundMuted)

        Spacer()

        // Type and nullable indicator
        HStack(spacing: 2) {
          Text(column.type.uppercased())
            .font(.monoSmall)
            .foregroundColor(.foregroundSubtle)

          if column.isNullable {
            Text("?")
              .font(.monoSmall)
              .foregroundColor(.foregroundSubtle)
          }
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .linkPointer()
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.xs)
    .background(
      RoundedRectangle(cornerRadius: CornerRadius.sm)
        .fill(isHovering ? Color.cellBackgroundHover.opacity(0.3) : Color.clear)
    )
    .onHover { hovering in
      isHovering = hovering
      if hovering {
        NSCursor.pointingHand.push()
      } else {
        NSCursor.pop()
      }
    }
    .onTapGesture(count: 2) {
      onClick()
    }
  }
}
