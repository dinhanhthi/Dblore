//
//  MongoCollectionTabBar.swift
//  Dblore
//
//  Sections of a MongoDB collection screen (Documents, Aggregations, Schema, Indexes), shown in
//  the data viewer header next to the collection title, with the counts already known: the
//  documents total of the loaded page and the indexes once read.
//

import SwiftUI

struct MongoCollectionTabBar: View {
  @Bindable var model: MongoCollectionModel
  /// Documents matching the applied filter, nil while not counted
  var documentCount: Int?

  private typealias Section = MongoCollectionModel.Section

  /// Taller than the result pickers so the section names read as the screen's main navigation
  private static let height: CGFloat = 26

  var body: some View {
    CapsuleTabPicker(
      selection: $model.section,
      tabs: Section.allCases,
      height: Self.height,
      inset: 2,
      verticalInset: 2
    ) { tab in
      label(tab)
    }
    .fitsContent()
    .accessibilityLabel("Collection section")
  }

  /// Sized by the semibold title, so a selection change keeps every tab width and the chip
  /// slides instead of snapping
  private func label(_ tab: Section) -> some View {
    let isSelected = model.section == tab
    return HStack(spacing: Spacing.xs) {
      Text(tab.title)
        .font(.labelText)
        .fontWeight(.semibold)
        .hidden()
        .overlay {
          Text(tab.title)
            .font(.labelText)
            .fontWeight(isSelected ? .semibold : .regular)
            .foregroundColor(isSelected ? .onAccentFill : .foreground)
        }
      if let count = count(of: tab) {
        Text(count.formatted())
          .font(.labelText)
          .monospacedDigit()
          .foregroundColor(isSelected ? .onAccentFill.opacity(0.75) : .foregroundSubtle)
      }
    }
    .lineLimit(1)
  }

  private func count(of tab: Section) -> Int? {
    switch tab {
    case .documents:
      return documentCount
    case .aggregations, .schema:
      return nil
    case .indexes:
      guard case .loaded(.indexes(let indexes)) = model.indexState else { return nil }
      return indexes.count
    }
  }
}
