//
//  EntitySection.swift
//  SQLNotebook
//

import SwiftUI

struct EntitySection<Content: View>: View {
  let title: String
  let count: Int
  let icon: String
  let isExpanded: Bool
  let content: () -> Content

  @State private var sectionExpanded: Bool

  init(
    title: String,
    count: Int,
    icon: String,
    isExpanded: Bool = true,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.title = title
    self.count = count
    self.icon = icon
    self.isExpanded = isExpanded
    self.content = content
    _sectionExpanded = State(initialValue: isExpanded)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Section header
      Button(action: {
        withAnimation(.snappy(duration: 0.2)) {
          sectionExpanded.toggle()
        }
      }) {
        HStack(spacing: Spacing.xs) {
          Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.foregroundMuted)
            .frame(width: 12, height: 12)
            .rotationEffect(.degrees(sectionExpanded ? 90 : 0))

          Image(systemName: icon)
            .font(.system(size: 12))
            .foregroundColor(.accent)

          Text(title)
            .font(.monoMedium)
            .foregroundColor(.foreground)

          Text("(\(count))")
            .font(.monoSmall)
            .foregroundColor(.foregroundSubtle)

          Spacer()
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs)
      }
      .buttonStyle(.plain)

      // Section content (lazy: only visible rows are built when the sidebar is shown)
      if sectionExpanded {
        LazyVStack(alignment: .leading, spacing: 0) {
          content()
        }
        .padding(.leading, Spacing.lg)  // Indent section content
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
