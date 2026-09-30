//
//  SidebarFilterField.swift
//  Dblore
//
//  Compact keyword filter pinned to the top of a left-sidebar tab body.
//

import SwiftUI

struct SidebarFilterField: View {
  @Binding var text: String

  var body: some View {
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
    .background(
      RoundedRectangle(cornerRadius: CornerRadius.md)
        .fill(Color.inputBackground)
    )
    .overlay(
      RoundedRectangle(cornerRadius: CornerRadius.md)
        .strokeBorder(Color.border, lineWidth: 1)
    )
    .padding(.horizontal, Spacing.sm)
    .padding(.top, Spacing.sm)
    .padding(.bottom, Spacing.xs)
  }
}
