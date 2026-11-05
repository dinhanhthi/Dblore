//
//  ResultSetTabs.swift
//  Dblore
//
//  The result sets of a multi-statement run as capsule tabs, shared by the editor and notebook
//  cells.
//

import SwiftUI

/// One tab per result set ("1 · 120 rows", "2 · UPDATE 3") above the grid. Beyond
/// `maxTabs` results, the first `overflowStart` stay tabs and a "More" menu holds the rest. A
/// click calls `onSelect` at once; the selection itself does no async work.
struct ResultSetTabs: View {
  let results: [StatementResult]
  let selectedIndex: Int
  let dialect: SQLDialect
  let onSelect: (Int) -> Void

  /// Most results shown as tabs without a "More" menu
  static let maxTabs = 6
  /// Results shown as tabs once the rest go in "More"
  static let overflowStart = 5

  private var tabCount: Int { Self.tabCount(for: results.count) }

  /// How many of `resultCount` results show as tabs; the rest go in "More"
  static func tabCount(for resultCount: Int) -> Int {
    resultCount > maxTabs ? overflowStart : resultCount
  }

  private var selectsOverflow: Bool { selectedIndex >= tabCount }

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: Spacing.sm) {
        CapsuleTabPicker(
          selection: Binding(get: { selectedIndex }, set: { onSelect($0) }),
          tabs: Array(0..<tabCount),
          height: 26,
          inset: 2,
          verticalInset: 2
        ) { index in
          CapsuleTabLabel(
            text: Self.label(for: results[index], at: index, dialect: dialect),
            isSelected: index == selectedIndex
          )
          .lineLimit(1)
          .help(Self.truncatedQuery(results[index].queryText))
        }
        // A result in "More" leaves no tab selected
        .fitsContent(selectedFill: selectsOverflow ? Color.clear : nil)

        if results.count > tabCount {
          overflowMenu
        }
      }
    }
    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
  }

  /// The results past the tabs; its title is the selected one while it is among them
  private var overflowMenu: some View {
    CapsulePickerMenu(
      // An index past the results (an old file) shows "More" instead of reading out of range
      title: selectsOverflow && results.indices.contains(selectedIndex)
        ? Self.label(for: results[selectedIndex], at: selectedIndex, dialect: dialect)
        : "More"
    ) {
      Picker(
        "More results",
        selection: Binding<Int?>(
          get: { selectsOverflow ? selectedIndex : nil },
          set: { if let index = $0 { onSelect(index) } })
      ) {
        ForEach(tabCount..<results.count, id: \.self) { index in
          Text(Self.label(for: results[index], at: index, dialect: dialect))
            .tag(Optional(index))
        }
      }
      .pickerStyle(.inline)
      .labelsHidden()
    }
  }

  /// The statement's text, cut to `maxLength` characters, as a tab's tooltip
  static func truncatedQuery(_ query: String, maxLength: Int = 60) -> String {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.count <= maxLength ? trimmed : String(trimmed.prefix(maxLength)) + "..."
  }

  /// "N · Error", "N · UPDATE 3" for a statement without rows (its verb alone when it reports
  /// no count, such as CREATE), else "N · 120 rows". MongoDB shows "N · 3 affected".
  static func label(
    for statement: StatementResult, at index: Int, dialect: SQLDialect
  )
    -> String
  {
    let result = statement.result
    let rows = "\(result.rowCount.formatted()) row\(result.rowCount == 1 ? "" : "s")"
    let kind: String
    if result.error != nil {
      kind = "Error"
    } else if !result.columns.isEmpty {
      kind = rows
    } else {
      // The first word is near the start: lex a bounded prefix, not the whole statement (a
      // leading comment longer than that gives no verb, so the count or rows show instead)
      let verb =
        dialect == .mongodb
        ? nil
        : SQLTokenizer.tokens(String(statement.queryText.prefix(256)), dialect: dialect)
          .first { $0.kind == .word }?.keyword
      switch (verb, result.affectedRows) {
      case (let verb?, let affected?): kind = "\(verb) \(affected.formatted())"
      case (let verb?, nil): kind = verb
      case (nil, let affected?): kind = "\(affected.formatted()) affected"
      case (nil, nil): kind = rows
      }
    }
    return "\(index + 1) · \(kind)"
  }
}
