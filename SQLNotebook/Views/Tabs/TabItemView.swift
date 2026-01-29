//
//  TabItemView.swift
//  SQLNotebook
//

import SwiftUI

/// Individual tab in the tab bar
struct TabItemView: View {
  let tab: TabItem
  let isActive: Bool
  let onSelect: () -> Void
  let onClose: () -> Void

  @State private var isHovering = false

  var body: some View {
    HStack(spacing: Spacing.xs) {
      // Document type icon
      Image(systemName: tab.documentType.icon)
        .font(.system(size: 11))
        .foregroundColor(isActive ? .foreground : .foregroundMuted)

      // Title with dirty indicator
      Text(displayTitle)
        .font(.system(size: 12))
        .lineLimit(1)
        .foregroundColor(isActive ? .foreground : .foregroundMuted)

      // Close button
      closeButton
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.xs)
    .frame(height: 28)
    .background(backgroundColor)
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm))
    .overlay(
      RoundedRectangle(cornerRadius: CornerRadius.sm)
        .stroke(isActive ? Color.border : Color.clear, lineWidth: 1)
    )
    .contentShape(Rectangle())
    .onTapGesture { onSelect() }
    .onHover { isHovering = $0 }
  }

  private var displayTitle: String {
    tab.isDirty ? "\(tab.title) •" : tab.title
  }

  private var backgroundColor: Color {
    if isActive {
      return Color.cardBackground
    } else if isHovering {
      return Color.cellBackgroundHover.opacity(0.5)
    } else {
      return Color.clear
    }
  }

  @ViewBuilder
  private var closeButton: some View {
    if isHovering || isActive || tab.isDirty {
      Button {
        onClose()
      } label: {
        Image(systemName: tab.isDirty ? "circle.fill" : "xmark")
          .font(.system(size: tab.isDirty ? 6 : 8, weight: .medium))
          .foregroundColor(.foregroundMuted)
          .frame(width: 14, height: 14)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(tab.isDirty ? "Unsaved changes" : "Close tab")
    } else {
      // Spacer to maintain consistent width
      Color.clear
        .frame(width: 14, height: 14)
    }
  }
}

#Preview {
  HStack(spacing: 4) {
    TabItemView(
      tab: TabItem(documentType: .notebook, title: "Untitled"),
      isActive: true,
      onSelect: {},
      onClose: {}
    )

    TabItemView(
      tab: TabItem(documentType: .sqlFile, title: "query", isDirty: true),
      isActive: false,
      onSelect: {},
      onClose: {}
    )

    TabItemView(
      tab: TabItem(documentType: .notebook, title: "analytics"),
      isActive: false,
      onSelect: {},
      onClose: {}
    )
  }
  .padding()
  .background(Color.appBackground)
}
