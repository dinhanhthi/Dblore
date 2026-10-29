//
//  EntitySection.swift
//  Dblore
//

import SwiftUI

struct EntitySection<Content: View>: View {
  let title: String
  /// Nil (not read yet) hides the count
  let count: Int?
  let icon: String
  /// The start state; unused when `expanded` is given
  let isExpanded: Bool
  /// Draws the section open (an active filter) without touching what the user toggled, so the
  /// section is back to that once it ends; the header does not toggle meanwhile
  let forceExpanded: Bool
  /// The open state when the caller keeps it (it outlives the section: one the filter takes out
  /// comes back as it was); nil keeps it here, starting at `isExpanded`
  let expanded: Binding<Bool>?
  /// The header's "+" button, its title as tooltip; nil shows none
  let createTitle: String?
  /// Nil disables "+"
  let onCreate: (() -> Void)?
  let content: () -> Content

  @State private var sectionExpanded: Bool

  init(
    title: String,
    count: Int?,
    icon: String,
    isExpanded: Bool = true,
    forceExpanded: Bool = false,
    expanded: Binding<Bool>? = nil,
    createTitle: String? = nil,
    onCreate: (() -> Void)? = nil,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.title = title
    self.count = count
    self.icon = icon
    self.isExpanded = isExpanded
    self.forceExpanded = forceExpanded
    self.expanded = expanded
    self.createTitle = createTitle
    self.onCreate = onCreate
    self.content = content
    _sectionExpanded = State(initialValue: isExpanded)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Section header, "+" beside the toggle (a button inside its label would toggle too)
      HStack(spacing: 0) {
        header
        if let createTitle {
          Button {
            onCreate?()
          } label: {
            Image(systemName: "plus")
              .font(.system(size: 11, weight: .semibold))
          }
          .buttonStyle(GhostButtonStyle(iconOnly: true))
          .controlSize(.small)
          .disabled(onCreate == nil)
          .help(createTitle)
          .accessibilityLabel(createTitle)
          .padding(.trailing, Spacing.sm)
        }
      }

      // Section content (lazy: only visible rows are built when the sidebar is shown)
      if isOpen {
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

  private var isOpen: Bool {
    forceExpanded || (expanded?.wrappedValue ?? sectionExpanded)
  }

  private var header: some View {
    Button(action: {
      guard !forceExpanded else { return }
      withAnimation(.snappy(duration: 0.2)) {
        if let expanded {
          expanded.wrappedValue.toggle()
        } else {
          sectionExpanded.toggle()
        }
      }
    }) {
      HStack(spacing: Spacing.xs) {
        Image(systemName: "chevron.right")
          .font(.system(size: 10, weight: .semibold))
          .foregroundColor(.foregroundMuted)
          .frame(width: 12, height: 12)
          .rotationEffect(.degrees(isOpen ? 90 : 0))

        Image(systemName: icon)
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
