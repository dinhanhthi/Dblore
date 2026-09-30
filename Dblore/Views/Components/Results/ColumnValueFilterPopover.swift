//
//  ColumnValueFilterPopover.swift
//  Dblore
//
//  Header filter popover: checkboxes for distinct values in the column, capped so a unique
//  column does not mount one toggle per loaded row. Unchecked values are hidden in the grid.
//  The loaded result is unchanged.
//

import SwiftUI

struct ColumnValueFilterPopover: View {
  let columnName: String
  let categories: [ColumnCategory]
  /// Every category key in the column, including those past the listed limit
  let allKeys: Set<String>
  @State private var hidden: Set<String>
  @State private var query = ""
  let onHiddenChange: (Set<String>) -> Void

  init(
    columnName: String, categories: [ColumnCategory], hidden: Set<String>,
    allKeys: Set<String>, onHiddenChange: @escaping (Set<String>) -> Void
  ) {
    self.columnName = columnName
    self.categories = categories
    self.allKeys = allKeys
    self.onHiddenChange = onHiddenChange
    _hidden = State(initialValue: hidden)
  }

  private var trimmedQuery: String {
    query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The prefix mounted as checkboxes. Search filters this list, not every distinct value.
  private var listedCategories: [ColumnCategory] {
    ColumnValueFilter.listedCategories(categories)
  }

  private var visibleCategories: [ColumnCategory] {
    guard !trimmedQuery.isEmpty else { return listedCategories }
    return listedCategories.filter {
      $0.label.range(of: trimmedQuery, options: .caseInsensitive) != nil
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text(columnName)
        .font(.system(size: 12, weight: .semibold))
        .foregroundColor(.foreground)
        .lineLimit(1)

      if categories.count > 8 {
        TextField("Search values", text: $query)
          .textFieldStyle(.plain)
          .font(.system(size: 12))
          .inputCapsuleStyle()
      }

      HStack(spacing: Spacing.sm) {
        Button("Show all", action: showAll)
          .buttonStyle(GhostButtonStyle())
          .disabled(hidden.isEmpty)
        Spacer()
        Button("Hide all", action: hideAll)
          .buttonStyle(GhostButtonStyle())
          .disabled(allKeys.isEmpty || hidden.isSuperset(of: allKeys))
      }

      Divider()

      if categories.isEmpty {
        Text("No values")
          .font(.small)
          .foregroundColor(.foregroundMuted)
      } else if visibleCategories.isEmpty {
        Text("No matching values")
          .font(.small)
          .foregroundColor(.foregroundMuted)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(visibleCategories) { category in
              Toggle(isOn: shownBinding(category.key)) {
                HStack(spacing: Spacing.sm) {
                  Text(category.label)
                    .font(.small)
                    .foregroundColor(.foreground)
                    .lineLimit(1)
                  Spacer(minLength: Spacing.sm)
                  Text("\(category.count)")
                    .font(.monoSmall)
                    .foregroundColor(.foregroundSubtle)
                }
              }
              .toggleStyle(.checkbox)
              .help(category.label)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 280)
      }
    }
    .padding(Spacing.md)
    .frame(width: 260)
  }

  private func shownBinding(_ key: String) -> Binding<Bool> {
    Binding(
      get: { !hidden.contains(key) },
      set: { shown in
        if shown {
          hidden.remove(key)
        } else {
          hidden.insert(key)
        }
        onHiddenChange(hidden)
      }
    )
  }

  private func showAll() {
    hidden = []
    onHiddenChange(hidden)
  }

  private func hideAll() {
    hidden = allKeys
    onHiddenChange(hidden)
  }
}
