//
//  CapsuleTabPicker.swift
//  Dblore
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

  /// Left and right inset of the selected chip.
  var inset: CGFloat = 3

  /// Top and bottom inset of the selected chip.
  var verticalInset: CGFloat = 3

  /// When set, the track hugs its labels instead of filling the parent width.
  var fitsContent: Bool = false

  /// Fill of the selected chip. The expanding track uses the accent color.
  var selectedFill: Color = .accent

  /// Extra inset of the selected chip inside its tab. Tightens a wide label such as a color dot.
  var selectedInset: CGFloat = 0

  init(
    selection: Binding<Tab>,
    tabs: [Tab],
    height: CGFloat = 32,
    inset: CGFloat = 3,
    verticalInset: CGFloat = 3,
    @ViewBuilder label: @escaping (Tab) -> Label
  ) {
    self._selection = selection
    self.tabs = tabs
    self.height = height
    self.inset = inset
    self.verticalInset = verticalInset
    self.label = label
  }

  /// Horizontal padding inside each content-sized tab.
  var contentTabPadding: CGFloat = 12

  @State private var tabWidths: [Int: CGFloat] = [:]

  func fitsContent(
    _ fits: Bool = true,
    selectedFill: Color? = nil,
    selectedInset: CGFloat = 0,
    tabPadding: CGFloat? = nil
  ) -> Self {
    var copy = self
    copy.fitsContent = fits
    copy.selectedInset = selectedInset
    if let selectedFill {
      copy.selectedFill = selectedFill
    }
    if let tabPadding {
      copy.contentTabPadding = tabPadding
    }
    return copy
  }

  var body: some View {
    if fitsContent {
      contentFitPicker
    } else {
      expandingPicker
    }
  }

  private var expandingPicker: some View {
    let selectedIndex = tabs.firstIndex(of: selection) ?? 0

    return ZStack {
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
            .frame(width: tabWidth, height: geometry.size.height - (verticalInset * 2))
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
              .linkPointer()
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

  private var contentFitPicker: some View {
    let selectedIndex = tabs.firstIndex(of: selection) ?? 0
    let selectedWidth = tabWidths[selectedIndex] ?? 0
    let chipWidth = max(0, selectedWidth - selectedInset * 2)
    let chipX =
      inset + selectedInset + (0..<selectedIndex).reduce(CGFloat(0)) { $0 + (tabWidths[$1] ?? 0) }

    return HStack(spacing: 0) {
      ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
        Button {
          withAnimation {
            selection = tab
          }
        } label: {
          label(tab)
            .padding(.horizontal, contentTabPadding)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .linkPointer()
        .background {
          GeometryReader { proxy in
            Color.clear.preference(key: TabWidthKey.self, value: [index: proxy.size.width])
          }
        }
      }
    }
    .onPreferenceChange(TabWidthKey.self) { tabWidths = $0 }
    .padding(.horizontal, inset)
    .frame(height: height)
    .fixedSize(horizontal: true, vertical: false)
    .background(alignment: .leading) {
      ZStack(alignment: .leading) {
        Capsule()
          .fill(Color.inputBackground)
          .overlay(Capsule().stroke(Color.border, lineWidth: 1))

        Capsule()
          .fill(selectedFill)
          .frame(width: chipWidth, height: height - (verticalInset * 2))
          .offset(x: chipX)
          .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selection)
          .allowsHitTesting(false)
      }
    }
  }
}

private struct TabWidthKey: PreferenceKey {
  static var defaultValue: [Int: CGFloat] = [:]
  static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
    value.merge(nextValue(), uniquingKeysWith: { $1 })
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
