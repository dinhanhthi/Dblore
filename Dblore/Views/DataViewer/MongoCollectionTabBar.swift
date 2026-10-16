//
//  MongoCollectionTabBar.swift
//  Dblore
//
//  Sections of a MongoDB collection screen (Documents, Aggregations, Schema, Indexes) above the
//  data viewer, with the counts already known: the documents total of the loaded page and the
//  indexes once read.
//

import SwiftUI

struct MongoCollectionTabBar: View {
  @Bindable var model: MongoCollectionModel
  /// Documents matching the applied filter, nil while not counted
  var documentCount: Int?

  private typealias Section = MongoCollectionModel.Section

  var body: some View {
    HStack(spacing: Spacing.sm) {
      CapsuleTabPicker(
        selection: $model.section,
        tabs: Section.allCases,
        height: ResultDisplayPicker.height,
        inset: 2,
        verticalInset: 2
      ) { tab in
        label(tab)
      }
      .fitsContent()
      .accessibilityLabel("Collection section")
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.appBackground)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(Color.foregroundMuted.opacity(0.1))
        .frame(height: 1)
    }
  }

  /// Sized by the semibold title, so a selection change keeps every tab width and the chip
  /// slides instead of snapping
  private func label(_ tab: Section) -> some View {
    let isSelected = model.section == tab
    return HStack(spacing: Spacing.xs) {
      Text(tab.title)
        .font(.small)
        .fontWeight(.semibold)
        .hidden()
        .overlay {
          Text(tab.title)
            .font(.small)
            .fontWeight(isSelected ? .semibold : .regular)
            .foregroundColor(isSelected ? .onAccentFill : .foreground)
        }
      if let count = count(of: tab) {
        Text(count.formatted())
          .font(.small)
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
