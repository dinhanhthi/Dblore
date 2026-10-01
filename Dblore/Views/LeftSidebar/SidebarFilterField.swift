//
//  SidebarFilterField.swift
//  Dblore
//
//  Compact keyword filter pinned to the top of a left-sidebar tab body.
//

import SwiftUI

struct SidebarFilterField<Trailing: View>: View {
  @Binding var text: String
  private var trailing: Trailing

  init(text: Binding<String>, @ViewBuilder trailing: () -> Trailing) {
    self._text = text
    self.trailing = trailing()
  }

  /// Empty trailing must not take a slot, or the field picks up a gap on the right.
  private var showsTrailing: Bool {
    Trailing.self != EmptyView.self
  }

  var body: some View {
    HStack(alignment: .center, spacing: showsTrailing ? Spacing.sm : 0) {
      field
      if showsTrailing {
        trailing
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.top, Spacing.sm)
    .padding(.bottom, Spacing.xs)
  }

  private var field: some View {
    HStack(spacing: Spacing.xs) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 11))
        .foregroundColor(.foregroundSubtle)

      TextField("filter", text: $text)
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
    .padding(.vertical, Spacing.xsm)
    .frame(maxWidth: .infinity)
    .background(Capsule().fill(Color.inputBackground))
    .overlay(Capsule().strokeBorder(Color.border, lineWidth: 1))
  }
}

extension SidebarFilterField where Trailing == EmptyView {
  init(text: Binding<String>) {
    self.init(text: text) { EmptyView() }
  }
}
