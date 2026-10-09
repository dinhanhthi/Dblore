//
//  SidebarFilterField.swift
//  Dblore
//
//  Compact keyword filter pinned to the top of a left-sidebar tab body.
//

import SwiftUI

/// Shared chrome for every left-sidebar filter row, so switching tabs does not jump.
enum SidebarFilterMetrics {
  static let controlHeight: CGFloat = 26
}

struct SidebarFilterField<Trailing: View>: View {
  @Binding var text: String
  var placeholder: String = "filter"
  /// Fixed capsule height for the field and its trailing control. Nil keeps the field's padding.
  var controlHeight: CGFloat? = SidebarFilterMetrics.controlHeight
  var topPadding: CGFloat = Spacing.sm
  var bottomPadding: CGFloat = Spacing.sm
  var trailingSpacing: CGFloat = Spacing.sm
  private var trailing: Trailing

  init(
    text: Binding<String>,
    placeholder: String = "filter",
    controlHeight: CGFloat? = SidebarFilterMetrics.controlHeight,
    topPadding: CGFloat = Spacing.sm,
    bottomPadding: CGFloat = Spacing.sm,
    trailingSpacing: CGFloat = Spacing.sm,
    @ViewBuilder trailing: () -> Trailing
  ) {
    self._text = text
    self.placeholder = placeholder
    self.controlHeight = controlHeight
    self.topPadding = topPadding
    self.bottomPadding = bottomPadding
    self.trailingSpacing = trailingSpacing
    self.trailing = trailing()
  }

  /// Empty trailing must not take a slot, or the field picks up a gap on the right.
  private var showsTrailing: Bool {
    Trailing.self != EmptyView.self
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .center, spacing: showsTrailing ? trailingSpacing : 0) {
        field
        if showsTrailing {
          trailing
            .frame(height: controlHeight)
        }
      }
      .padding(.horizontal, Spacing.sm)
      .padding(.top, topPadding)
      .padding(.bottom, bottomPadding)

      Divider()
    }
  }

  private var field: some View {
    HStack(spacing: Spacing.xs) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 11))
        .foregroundColor(.foregroundSubtle)

      TextField(placeholder, text: $text)
        .textFieldStyle(.plain)
        .font(.small)
        .autocorrectionDisabled()

      if !text.isEmpty {
        Button {
          text = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 11))
            .foregroundColor(.foregroundSubtle)
        }
        .buttonStyle(.plain)
        .help("Clear filter")
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, controlHeight == nil ? Spacing.xsm : 0)
    .frame(maxWidth: .infinity)
    .frame(height: controlHeight)
    .background(Capsule().fill(Color.inputBackground))
    .overlay(Capsule().strokeBorder(Color.border, lineWidth: 1))
  }
}

extension SidebarFilterField where Trailing == EmptyView {
  init(text: Binding<String>, placeholder: String = "filter") {
    self.init(text: text, placeholder: placeholder) { EmptyView() }
  }
}
