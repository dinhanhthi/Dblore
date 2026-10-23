//
//  SidebarSchemaFilterMenu.swift
//  Dblore
//
//  The Public tab's schema filter: a checklist of the connection's schemas and Show All, in the
//  filter row's capsule. Its label says how many schemas are hidden, so a shorter list is never
//  a surprise. Hiding a schema only shortens the sidebar.
//

import SwiftUI

struct SidebarSchemaFilterMenu: View {
  /// Every schema of the connection, in display order (hidden ones included)
  let schemas: [String]
  /// The connection's hidden schemas, a dropped schema included
  let hidden: Set<String>
  /// Gets the new hidden list
  let onChange: ([String]) -> Void

  private var hiddenLabel: String? {
    SidebarSectionModel.hiddenSchemasLabel(schemas, hidden: hidden)
  }

  var body: some View {
    Menu {
      ForEach(schemas, id: \.self) { schema in
        Toggle(isOn: shownBinding(schema)) {
          Text(verbatim: schema)
        }
      }
      Divider()
      Button("Show All") { onChange([]) }
        .disabled(hidden.isEmpty)
    } label: {
      HStack(spacing: Spacing.xs) {
        Image(systemName: hiddenLabel == nil ? "eye" : "eye.slash")
          .font(.system(size: 11))
          .foregroundStyle(hiddenLabel == nil ? Color.foregroundMuted : Color.accent)
        if let hiddenLabel {
          Text(hiddenLabel)
            .font(.system(size: 11))
            .foregroundStyle(Color.foreground)
            .lineLimit(1)
        }
      }
      .padding(.horizontal, Spacing.sm)
      .frame(height: SidebarFilterMetrics.controlHeight)
      .background(Capsule().fill(Color.controlBackground))
      .overlay(HairlineBorder(shape: Capsule()))
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .linkPointer()
    .fixedSize()
    .help(hiddenLabel.map { "Schemas: \($0)" } ?? "Show or Hide Schemas")
    .accessibilityLabel(hiddenLabel.map { "Schemas, \($0)" } ?? "Show or Hide Schemas")
  }

  /// On while `schema` is listed
  private func shownBinding(_ schema: String) -> Binding<Bool> {
    Binding(
      get: { !hidden.contains(schema) },
      set: { isShown in
        var next = hidden
        if isShown { next.remove(schema) } else { next.insert(schema) }
        onChange(Array(next))
      })
  }
}
