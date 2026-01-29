//
//  TabItemView.swift
//  SQLNotebook
//

import SwiftUI

/// Individual tab in the tab bar - Chrome-style with seamless active tab
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
    .clipShape(tabShape)
    .overlay(
      tabShape
        .stroke(isActive ? Color.border : Color.clear, lineWidth: 1)
    )
    .contentShape(Rectangle())
    .onTapGesture { onSelect() }
    .onHover { isHovering = $0 }
  }

  /// Tab shape: rounded top, flat bottom for active tab (seamless with content)
  private var tabShape: some Shape {
    if isActive {
      return AnyShape(TabTopRoundedShape(radius: CornerRadius.sm))
    } else {
      return AnyShape(RoundedRectangle(cornerRadius: CornerRadius.sm))
    }
  }

  private var displayTitle: String {
    tab.isDirty ? "\(tab.title) •" : tab.title
  }

  private var backgroundColor: Color {
    if isActive {
      return Color.appBackground
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

/// Custom shape with rounded top corners and flat bottom (for seamless tab)
struct TabTopRoundedShape: Shape {
  let radius: CGFloat

  func path(in rect: CGRect) -> Path {
    var path = Path()

    // Start from bottom-left
    path.move(to: CGPoint(x: rect.minX, y: rect.maxY))

    // Line up to top-left corner start
    path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))

    // Top-left corner
    path.addQuadCurve(
      to: CGPoint(x: rect.minX + radius, y: rect.minY),
      control: CGPoint(x: rect.minX, y: rect.minY)
    )

    // Line to top-right corner start
    path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))

    // Top-right corner
    path.addQuadCurve(
      to: CGPoint(x: rect.maxX, y: rect.minY + radius),
      control: CGPoint(x: rect.maxX, y: rect.minY)
    )

    // Line down to bottom-right
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))

    // Flat bottom (no corner rounding)
    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))

    path.closeSubpath()
    return path
  }
}

/// Type-erased shape wrapper for conditional shapes
struct AnyShape: Shape, @unchecked Sendable {
  private let pathBuilder: @Sendable (CGRect) -> Path

  init<S: Shape>(_ shape: S) {
    let shapeCopy = shape
    pathBuilder = { rect in
      shapeCopy.path(in: rect)
    }
  }

  func path(in rect: CGRect) -> Path {
    pathBuilder(rect)
  }
}

#Preview {
  VStack(spacing: 0) {
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
    .padding(.horizontal)
    .padding(.top, Spacing.sm)
    .background(Color.cardBackground)

    // Content area to show seamless effect
    Rectangle()
      .fill(Color.appBackground)
      .frame(height: 100)
  }
  .background(Color.cardBackground)
}
