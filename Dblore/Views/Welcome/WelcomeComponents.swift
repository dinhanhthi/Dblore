//
//  WelcomeComponents.swift
//  Dblore
//
//  Pieces shared by the app Welcome screen and the workspace welcome: the left column,
//  its buttons, the filter field, section headers and the single-line recent row.
//

import SwiftUI

// MARK: - Sidebar Column

/// Fixed-width left column: header on top, actions below it, footer pinned to the bottom.
struct WelcomeSidebarColumn<Header: View, Actions: View, Footer: View>: View {
  var topInset: CGFloat = 0
  @ViewBuilder let header: Header
  @ViewBuilder let actions: Actions
  @ViewBuilder let footer: Footer

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xl) {
      header
        .frame(maxWidth: .infinity)

      VStack(spacing: Spacing.sm) {
        actions
      }

      Spacer(minLength: 0)

      footer
    }
    .padding(Spacing.md)
    .padding(.top, topInset)
    .frame(width: ComponentSize.welcomeSidebarWidth)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(Color.cardBackground)
  }
}

// MARK: - Sidebar Buttons

/// Full-width secondary button: icon and title on the leading edge.
struct WelcomeActionButton: View {
  let title: String
  let systemImage: String
  var help: String?
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: Spacing.sm) {
        Image(systemName: systemImage)
          .frame(width: 16)
        Text(title)
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity)
    }
    .buttonStyle(SecondaryButtonStyle(fillsWidth: true))
    .help(help ?? title)
  }
}

// MARK: - Filter Field

/// Capsule search field (recent lists, the Settings title bar), with a clear button once it has text.
struct WelcomeFilterField: View {
  let prompt: String
  @Binding var text: String

  @Environment(\.pixelLength) private var pixelLength

  var body: some View {
    HStack(spacing: Spacing.xsm) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 12))
        .foregroundColor(.foregroundSubtle)
      TextField(prompt, text: $text)
        .textFieldStyle(.plain)
        .font(.callout)
      if !text.isEmpty {
        Button {
          text = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundColor(.foregroundSubtle)
        }
        .buttonStyle(.plain)
        .help("Clear filter")
      }
    }
    .padding(.horizontal, Spacing.md)
    .frame(height: 30)
    .background(Capsule().fill(Color.controlBackground))
    .overlay(Capsule().strokeBorder(Color.border, lineWidth: pixelLength))
  }
}

// MARK: - Recent Row Layout

/// Shared single-line row: the title keeps its width, the detail truncates first.
struct RecentRowLayout<Icon: View, Title: View, Detail: View, Trailing: View>: View {
  let isHovering: Bool
  @ViewBuilder let icon: Icon
  @ViewBuilder let title: Title
  @ViewBuilder let detail: Detail
  @ViewBuilder let trailing: Trailing

  var body: some View {
    HStack(spacing: Spacing.sm) {
      icon
        .frame(width: 18)

      title
        .font(.callout.weight(.medium))
        .foregroundColor(.foreground.opacity(0.85))
        .lineLimit(1)
        .truncationMode(.tail)
        .layoutPriority(1)

      detail
        .font(.caption)
        .foregroundColor(.foregroundMuted)
        .lineLimit(1)
        .truncationMode(.tail)

      Spacer(minLength: Spacing.sm)

      trailing
        .font(.caption)
        .foregroundColor(.foregroundSubtle)
        .layoutPriority(2)
    }
    .padding(.horizontal, Spacing.sm)
    .frame(height: 30)
    .background(Capsule().fill(isHovering ? Color.cellBackgroundHover : Color.clear))
    .contentShape(Rectangle())
  }
}
