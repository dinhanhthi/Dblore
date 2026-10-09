//
//  DatabaseEntityRows.swift
//  Dblore
//
//  Row views for database entities: Tables, Views, Functions, Procedures, Triggers, and Columns
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
  let onToggle: () -> Void
  let onOpen: () -> Void
  let onColumnClick: (String) -> Void
  /// Nil hides "Import Data..." (the engine has no table import)
  let onImport: (() -> Void)?

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

          if !table.schema.isEmpty && table.schema != databaseType.dialect.defaultSchema {
            Text("(\(table.schema))")
              .font(.monoSmall)
              .foregroundColor(.foregroundSubtle)
          }

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
              ? Color.accent.opacity(0.15)
              : (isHoveringTable ? Color.cellBackgroundHover.opacity(0.5) : Color.clear))
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
        if let onImport {
          Button("Import Data...", action: onImport)
        }
      }

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
}

// MARK: - View Row View

struct ViewRowView: View {
  let view: DatabaseView
  let isExpanded: Bool
  /// Shown in the active data viewer tab
  var isSelected = false
  /// Connection type; its default schema is omitted from the row label
  var databaseType: DatabaseType = .postgresql
  let onToggle: () -> Void
  let onOpen: () -> Void
  let onColumnClick: (String) -> Void

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

          if !view.schema.isEmpty && view.schema != databaseType.dialect.defaultSchema {
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
              ? Color.accent.opacity(0.15)
              : (isHovering ? Color.cellBackgroundHover.opacity(0.5) : Color.clear))
      )
      .onHover { hovering in
        isHovering = hovering
        if hovering {
          NSCursor.pointingHand.push()
        } else {
          NSCursor.pop()
        }
      }

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
          .fill(isHovering ? Color.cellBackgroundHover.opacity(0.5) : Color.clear)
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
          .fill(isHovering ? Color.cellBackgroundHover.opacity(0.5) : Color.clear)
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
        .fill(isHovering ? Color.cellBackgroundHover.opacity(0.5) : Color.clear)
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
