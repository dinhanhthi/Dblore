//
//  CapsuleTabPicker.swift
//  SQLNotebook
//
//  A reusable capsule-shaped tab picker with sliding animation
//

import SwiftUI

/// A generic capsule-shaped tab picker with sliding indicator animation
/// Usage:
/// ```swift
/// enum MyTab: String, CaseIterable {
///   case first = "First"
///   case second = "Second"
/// }
///
/// CapsuleTabPicker(
///   selection: $selectedTab,
///   tabs: MyTab.allCases
/// ) { tab in
///   Text(tab.rawValue)
/// }
/// ```
struct CapsuleTabPicker<Tab: Hashable, Label: View>: View {
  @Binding var selection: Tab
  let tabs: [Tab]
  let label: (Tab) -> Label

  /// Height of the picker
  var height: CGFloat = 32

  /// Inset padding for the sliding indicator
  private let inset: CGFloat = 3

  init(
    selection: Binding<Tab>,
    tabs: [Tab],
    height: CGFloat = 32,
    @ViewBuilder label: @escaping (Tab) -> Label
  ) {
    self._selection = selection
    self.tabs = tabs
    self.height = height
    self.label = label
  }

  var body: some View {
    let selectedIndex = tabs.firstIndex(of: selection) ?? 0

    ZStack {
      // Background
      Capsule()
        .fill(Color.inputBackground)
        .overlay(
          Capsule()
            .stroke(Color.border, lineWidth: 1)
        )

      // Content with padding
      GeometryReader { geometry in
        let availableWidth = geometry.size.width - (inset * 2)
        let tabWidth = availableWidth / CGFloat(tabs.count)

        ZStack(alignment: .leading) {
          // Sliding indicator
          Capsule()
            .fill(Color.accent)
            .frame(width: tabWidth, height: geometry.size.height - (inset * 2))
            .offset(x: inset + CGFloat(selectedIndex) * tabWidth)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selection)

          // Tab buttons
          HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { _, tab in
              Button(action: {
                withAnimation {
                  selection = tab
                }
              }) {
                label(tab)
                  .frame(maxWidth: .infinity, maxHeight: .infinity)
                  .contentShape(Rectangle())
              }
              .buttonStyle(PlainButtonStyle())
              .pointerStyle(.link)
              .onHover { hovering in
                if hovering {
                  NSCursor.pointingHand.push()
                } else {
                  NSCursor.pop()
                }
              }
            }
          }
        }
      }
    }
    .frame(height: height)
  }
}

// MARK: - Convenience initializer for RawRepresentable tabs

extension CapsuleTabPicker
where Tab: RawRepresentable, Tab.RawValue == String, Label == CapsuleTabLabel {
  /// Convenience initializer for String-based enums
  /// Automatically uses the rawValue as the label
  init(
    selection: Binding<Tab>,
    tabs: [Tab],
    height: CGFloat = 32
  ) {
    self._selection = selection
    self.tabs = tabs
    self.height = height
    self.label = { tab in
      CapsuleTabLabel(
        text: tab.rawValue,
        isSelected: selection.wrappedValue == tab
      )
    }
  }
}

// MARK: - Default Tab Label

/// Default label view for capsule tab picker
struct CapsuleTabLabel: View {
  let text: String
  let isSelected: Bool

  var body: some View {
    Text(text)
      .font(.body)
      .fontWeight(isSelected ? .semibold : .regular)
      .foregroundColor(isSelected ? .white : .foreground)
  }
}
