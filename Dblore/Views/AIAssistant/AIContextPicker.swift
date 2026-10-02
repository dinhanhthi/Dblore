//
//  AIContextPicker.swift
//  Dblore
//
//  Table scope for the AI assistant: removable table chips, expandable to column chips
//

import SwiftUI

/// Chip button with hover, pressed and disabled states. Always a capsule.
struct AIChipButtonStyle: ButtonStyle {
  var isActive = false

  func makeBody(configuration: Configuration) -> some View {
    ChipBody(configuration: configuration, isActive: isActive)
  }

  private struct ChipBody: View {
    let configuration: Configuration
    let isActive: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
      configuration.label
        .font(.small)
        .foregroundColor(isActive ? .accent : .foreground)
        .padding(.horizontal, Spacing.sm)
        .frame(height: 22)
        .background(
          configuration.isPressed || isHovering ? Color.cellBackgroundHover : Color.inputBackground
        )
        .clipShape(Capsule())
        .overlay(Capsule().stroke(isActive ? Color.accent : Color.border, lineWidth: 1))
        .contentShape(Capsule())
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { isHovering = $0 }
        .linkPointer()
    }
  }
}

/// Compact menu label that keeps the chevron and ellipsizes a long title.
struct AIDropdownLabel: View {
  let title: String
  var systemImage: String

  var body: some View {
    HStack(spacing: Spacing.xs) {
      Image(systemName: systemImage)
        .font(.system(size: 11))
        .foregroundColor(.foregroundSubtle)

      Text(title)
        .font(.small)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

      Image(systemName: "chevron.down")
        .font(.system(size: 9, weight: .semibold))
        .foregroundColor(.foregroundSubtle)
    }
    .foregroundColor(.foregroundMuted)
    .padding(.horizontal, Spacing.sm)
    .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
    .background(Color.inputBackground)
    .clipShape(Capsule())
    .overlay(Capsule().stroke(Color.border, lineWidth: 1))
    .contentShape(Capsule())
  }
}

/// Wraps children onto new lines when the row is full
private struct AIFlowLayout: Layout {
  var spacing: CGFloat = 4

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    arrange(width: proposal.width ?? .infinity, subviews: subviews).size
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let result = arrange(width: bounds.width, subviews: subviews)
    for (subview, origin) in zip(subviews, result.origins) {
      subview.place(
        at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
    }
  }

  private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
    var origins: [CGPoint] = []
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    var maxX: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > 0, x + size.width > width {
        x = 0
        y += rowHeight + spacing
        rowHeight = 0
      }
      origins.append(CGPoint(x: x, y: y))
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
      maxX = max(maxX, x - spacing)
    }
    return (CGSize(width: maxX, height: y + rowHeight), origins)
  }
}

struct AIContextPicker<Accessory: View>: View {
  @Binding var selected: Set<String>
  let tables: [DatabaseTable]
  /// Called with `schema.table.column` when a column chip is clicked
  var onColumn: (String) -> Void = { _ in }
  /// Sits beside the context menu. Empty when the picker is shown alone.
  private var accessory: () -> Accessory

  init(
    selected: Binding<Set<String>>,
    tables: [DatabaseTable],
    onColumn: @escaping (String) -> Void = { _ in },
    @ViewBuilder accessory: @escaping () -> Accessory
  ) {
    _selected = selected
    self.tables = tables
    self.onColumn = onColumn
    self.accessory = accessory
  }

  private let searchThreshold = 30

  @State private var expanded: String?
  @State private var showSearchPopover = false
  @State private var search = ""

  private var selectedTables: [DatabaseTable] {
    tables.filter { selected.contains($0.qualifiedName) }
  }

  private var expandedTable: DatabaseTable? {
    selectedTables.first { $0.qualifiedName == expanded }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      if !selectedTables.isEmpty {
        AIFlowLayout {
          ForEach(selectedTables) { table in
            tableChip(table)
          }
        }
      }

      if let table = expandedTable {
        AIFlowLayout {
          ForEach(table.columns) { column in
            Button(column.name) { onColumn("\(table.qualifiedName).\(column.name)") }
              .buttonStyle(AIChipButtonStyle())
              .help("Add \(table.qualifiedName).\(column.name) to the message")
          }
        }
      }

      HStack(alignment: .center, spacing: Spacing.sm) {
        picker
          .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
          .clipped()
        if Accessory.self != EmptyView.self {
          accessory()
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
      }
    }
    .onChange(of: selected) { _, newValue in
      if let expanded, !newValue.contains(expanded) { self.expanded = nil }
    }
  }

  // MARK: - Pieces

  @ViewBuilder
  private var picker: some View {
    if tables.count > searchThreshold {
      Button {
        showSearchPopover.toggle()
      } label: {
        pickerLabel
      }
      .buttonStyle(.plain)
      .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
      .linkPointer()
      .help("Context")
      .popover(isPresented: $showSearchPopover, arrowEdge: .bottom) { searchPopover }
    } else {
      Menu {
        menuItems(for: tables)
      } label: {
        pickerLabel
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
      .linkPointer()
      .help("Context")
    }
  }

  private var pickerLabel: some View {
    AIDropdownLabel(
      title: selected.isEmpty ? "Auto (relevant tables)" : "\(selected.count) selected",
      systemImage: "tablecells"
    )
  }

  @ViewBuilder
  private func menuItems(for list: [DatabaseTable]) -> some View {
    Button {
      selected = []
    } label: {
      if selected.isEmpty {
        Label("Auto (relevant tables)", systemImage: "checkmark")
      } else {
        Text("Auto (relevant tables)")
      }
    }
    Divider()
    ForEach(list) { table in
      Toggle(
        table.qualifiedName,
        isOn: Binding(
          get: { selected.contains(table.qualifiedName) },
          set: { isOn in
            if isOn {
              selected.insert(table.qualifiedName)
            } else {
              selected.remove(table.qualifiedName)
            }
          }))
    }
  }

  private var searchPopover: some View {
    let query = search.trimmingCharacters(in: .whitespaces).lowercased()
    let filtered =
      query.isEmpty ? tables : tables.filter { $0.qualifiedName.lowercased().contains(query) }
    return VStack(alignment: .leading, spacing: Spacing.sm) {
      TextField("Search tables", text: $search)
        .textFieldStyle(.plain)
        .font(.bodyText)
        .padding(.horizontal, Spacing.sm)
        .frame(height: ComponentSize.buttonHeight)
        .background(Color.inputBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm))
        .overlay(
          RoundedRectangle(cornerRadius: CornerRadius.sm).stroke(Color.borderSubtle, lineWidth: 1))

      Button("Auto (relevant tables)") { selected = [] }
        .buttonStyle(GhostButtonStyle(isActive: selected.isEmpty))

      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(filtered) { table in
            let isOn = selected.contains(table.qualifiedName)
            Button {
              if isOn {
                selected.remove(table.qualifiedName)
              } else {
                selected.insert(table.qualifiedName)
              }
            } label: {
              HStack {
                Image(systemName: "checkmark")
                  .font(.smallest)
                  .opacity(isOn ? 1 : 0)
                Text(table.qualifiedName)
                  .font(.labelText)
                Spacer(minLength: 0)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .contentShape(Rectangle())
            }
            .buttonStyle(GhostButtonStyle(isActive: isOn))
          }
        }
      }
      .frame(height: 240)
    }
    .padding(Spacing.md)
    .frame(width: 260)
    .background(Color.cardHeaderBackground)
  }

  private func tableChip(_ table: DatabaseTable) -> some View {
    let isExpanded = expanded == table.qualifiedName
    return HStack(spacing: Spacing.xs) {
      Button {
        expanded = isExpanded ? nil : table.qualifiedName
      } label: {
        Text(table.qualifiedName)
      }
      .buttonStyle(AIChipButtonStyle(isActive: isExpanded))
      .help("Show columns")

      Button {
        selected.remove(table.qualifiedName)
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .controlSize(.small)
      .help("Remove \(table.qualifiedName)")
    }
  }
}

extension AIContextPicker where Accessory == EmptyView {
  init(
    selected: Binding<Set<String>>,
    tables: [DatabaseTable],
    onColumn: @escaping (String) -> Void = { _ in }
  ) {
    self.init(selected: selected, tables: tables, onColumn: onColumn) { EmptyView() }
  }
}

#Preview("AIContextPicker") {
  @Previewable @State var selected: Set<String> = ["public.orders"]
  let tables = [
    DatabaseTable(
      schema: "public", name: "orders",
      columns: [
        DatabaseColumn(
          name: "id", type: "int", isNullable: false, isPrimaryKey: true, isIdentity: true,
          isUnique: true),
        DatabaseColumn(
          name: "total", type: "numeric", isNullable: true, isPrimaryKey: false,
          isIdentity: false, isUnique: false),
      ]),
    DatabaseTable(schema: "public", name: "customers"),
  ]
  AIContextPicker(selected: $selected, tables: tables)
    .padding(Spacing.md)
    .frame(width: ComponentSize.sidebarWidth)
    .background(Color.appBackground)
}
