//
//  DesignSystem+Components.swift
//  SQLNotebook
//
//  Button styles, custom shapes, and view modifiers for the design system
//
//  Requires: DesignSystem+Colors.swift, DesignSystem+Spacing.swift
//

import SwiftUI

// MARK: - Button Style Variant

enum ButtonStyleVariant {
  case primary
  case secondary
  case danger
  case ghost

  func backgroundColor(isPressed: Bool, isHovering: Bool = false) -> Color {
    switch self {
    case .primary:
      return isPressed ? Color.accentMuted : Color.accent
    case .secondary:
      return isPressed ? Color.cellBackgroundHover : Color.clear
    case .danger:
      return isPressed ? Color.destructive.opacity(0.8) : Color.destructive.opacity(0.6)
    case .ghost:
      if isPressed {
        return Color.cellBackgroundHover
      } else if isHovering {
        return Color.cellBackgroundHover.opacity(0.5)
      } else {
        return Color.clear
      }
    }
  }

  var hasBorder: Bool {
    self == .secondary
  }

  var foregroundColor: Color {
    .foreground
  }

  func foregroundColor(isPressed: Bool, isHovering: Bool = false) -> Color {
    switch self {
    case .ghost:
      return isPressed || isHovering ? .foreground : .foregroundMuted
    default:
      return .foreground
    }
  }
}

// MARK: - Button Styles
struct PrimaryButtonStyle: ButtonStyle {
  var iconOnly: Bool = false

  func makeBody(configuration: Configuration) -> some View {
    BaseButtonStyleView(variant: .primary, iconOnly: iconOnly, configuration: configuration)
  }
}

struct SecondaryButtonStyle: ButtonStyle {
  var iconOnly: Bool = false

  func makeBody(configuration: Configuration) -> some View {
    BaseButtonStyleView(variant: .secondary, iconOnly: iconOnly, configuration: configuration)
  }
}

struct DangerButtonStyle: ButtonStyle {
  var iconOnly: Bool = false

  func makeBody(configuration: Configuration) -> some View {
    BaseButtonStyleView(variant: .danger, iconOnly: iconOnly, configuration: configuration)
  }
}

struct GhostButtonStyle: ButtonStyle {
  var iconOnly: Bool = false

  func makeBody(configuration: Configuration) -> some View {
    BaseButtonStyleView(variant: .ghost, iconOnly: iconOnly, configuration: configuration)
  }
}

/// Internal view that properly receives environment values
private struct BaseButtonStyleView: View {
  let variant: ButtonStyleVariant
  var iconOnly: Bool = false
  let configuration: ButtonStyleConfiguration
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.controlSize) private var controlSize
  @State private var isHovering = false

  private var font: Font {
    switch controlSize {
    case .mini:
      return .system(.caption2, weight: .medium)
    case .small:
      return .system(.caption, weight: .medium)
    case .large, .extraLarge:
      return .system(.body, weight: .medium)
    default:  // .regular
      return .system(.callout, weight: .medium)
    }
  }

  private var horizontalPadding: CGFloat {
    if iconOnly {
      return verticalPadding
    }
    switch controlSize {
    case .mini:
      return Spacing.xs
    case .small:
      return Spacing.md
    case .large, .extraLarge:
      return Spacing.xl
    default:  // .regular
      return (Spacing.md + Spacing.lg) / 2
    }
  }

  private var verticalPadding: CGFloat {
    switch controlSize {
    case .mini:
      return Spacing.xxs
    case .small:
      return iconOnly ? Spacing.sm - 2 : Spacing.xs
    case .large, .extraLarge:
      return Spacing.md
    default:  // .regular
      return iconOnly ? Spacing.sm : (Spacing.xs + Spacing.sm) / 2
    }
  }

  var body: some View {
    configuration.label
      .font(font)
      .foregroundColor(
        variant.foregroundColor(isPressed: configuration.isPressed, isHovering: isHovering)
      )
      .padding(.horizontal, horizontalPadding)
      .padding(.vertical, verticalPadding)
      .background {
        if iconOnly {
          Circle()
            .fill(
              variant.backgroundColor(isPressed: configuration.isPressed, isHovering: isHovering))
        } else {
          Capsule()
            .fill(
              variant.backgroundColor(isPressed: configuration.isPressed, isHovering: isHovering))
        }
      }
      .overlay {
        if variant.hasBorder {
          if iconOnly {
            Circle()
              .stroke(Color.border, lineWidth: 1)
          } else {
            Capsule()
              .stroke(Color.border, lineWidth: 1)
          }
        }
      }
      .contentShape(iconOnly ? AnyShape(Circle()) : AnyShape(Capsule()))
      .opacity(isEnabled ? 1 : 0.5)
      .animation(.easeInOut(duration: 0.15), value: isHovering)
      .onHover { hovering in
        isHovering = hovering
      }
      .cursor(.pointingHand)
  }
}

struct SidebarHeaderButtonStyle: ButtonStyle {
  var isActive: Bool = false
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovering = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundColor(isActive ? .accent : nil)
      .frame(width: 24, height: 24)
      .background(
        RoundedRectangle(cornerRadius: CornerRadius.sm)
          .fill(
            isActive || isHovering && isEnabled || configuration.isPressed
              ? Color.foregroundMuted.opacity(0.2)
              : Color.clear
          )
      )
      .contentShape(Rectangle())
      .animation(.easeInOut(duration: 0.1), value: isHovering)
      .onHover { hovering in
        isHovering = hovering
      }
      .cursor(.pointingHand)
  }
}

struct ToolbarButtonStyle: ButtonStyle {
  var isActive: Bool = false
  var iconOnly: Bool = false
  @State private var isHovering = false
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(.body, weight: .medium))
      .foregroundColor(
        isActive ? .accent : (configuration.isPressed ? .foreground : .foregroundMuted)
      )
      .padding(.horizontal, iconOnly ? Spacing.xs : Spacing.sm)
      .padding(.vertical, Spacing.sm)
      .background(
        RoundedRectangle(cornerRadius: CornerRadius.md)
          .fill(
            configuration.isPressed || isActive
              ? Color.cellBackgroundHover
              : (isHovering && isEnabled ? Color.cellBackgroundHover.opacity(0.5) : Color.clear)
          )
      )
      .contentShape(Rectangle())
      .opacity(isEnabled ? 1.0 : 0.4)
      .animation(.easeInOut(duration: 0.15), value: isHovering)
      .onHover { hovering in
        isHovering = hovering
      }
      .cursor(.pointingHand)
  }
}

struct FloatingActionButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .padding(Spacing.xs)
      .background(
        Circle()
          .fill(configuration.isPressed ? Color.accent.opacity(0.2) : Color.clear)
      )
      .contentShape(Circle())
      .cursor(.pointingHand)
  }
}

struct FloatingPanelButtonStyle: ButtonStyle {
  @State private var isHovering = false
  @Environment(\.colorScheme) private var colorScheme

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundColor(
        // Light theme: violet when hovering, muted otherwise
        // Dark theme: always muted
        colorScheme == .light && isHovering
          ? Color.accent
          : .foregroundMuted
      )
      .frame(width: 26, height: 26)
      .background(
        ZStack {
          // Opaque base layer to hide content behind
          Circle()
            .fill(Color.cellBackgroundHover)

          // Hover/press overlay with accent color (only in dark theme)
          if colorScheme == .dark && (isHovering || configuration.isPressed) {
            Circle()
              .fill(Color.accent.opacity(0.15))
          }
        }
        .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
      )
      .overlay(
        Circle()
          .stroke(isHovering ? Color.accent.opacity(0.5) : Color.borderSubtle, lineWidth: 1)
      )
      .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
      .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
      .animation(.easeInOut(duration: 0.15), value: isHovering)
      .onHover { hovering in
        isHovering = hovering
      }
      .cursor(.pointingHand)
  }
}

struct FloatingPanelToggleButtonStyle: ButtonStyle {
  let isActive: Bool
  @State private var isHovering = false
  @Environment(\.colorScheme) private var colorScheme

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundColor(
        // Light theme: violet when hovering or active, muted otherwise
        // Dark theme: always muted
        colorScheme == .light && (isHovering || isActive)
          ? Color.accent
          : .foregroundMuted
      )
      .frame(width: 26, height: 26)
      .background(
        ZStack {
          // Opaque base layer to hide content behind
          Circle()
            .fill(Color.cellBackgroundHover)

          // Hover/press/active overlay with accent color (only in dark theme)
          if colorScheme == .dark && (isHovering || configuration.isPressed || isActive) {
            Circle()
              .fill(Color.accent.opacity(0.15))
          }
        }
        .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
      )
      .overlay(
        Circle()
          .stroke(
            (isHovering || isActive) ? Color.accent.opacity(0.5) : Color.borderSubtle,
            lineWidth: 1
          )
      )
      .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
      .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
      .animation(.easeInOut(duration: 0.15), value: isHovering)
      .animation(.easeInOut(duration: 0.15), value: isActive)
      .onHover { hovering in
        isHovering = hovering
      }
      .cursor(.pointingHand)
  }
}

// MARK: - Custom Shapes

struct RoundedLeftBorder: Shape {
  let cornerRadius: CGFloat
  let lineWidth: CGFloat

  func path(in rect: CGRect) -> Path {
    var path = Path()

    // Start from top-left corner (accounting for line width)
    let startX = lineWidth / 2
    let startY = cornerRadius

    // Move to start position
    path.move(to: CGPoint(x: startX, y: startY))

    // Top-left corner arc
    // path.addArc(
    //     center: CGPoint(x: cornerRadius, y: cornerRadius),
    //     radius: cornerRadius - lineWidth / 2,
    //     startAngle: .degrees(180),
    //     endAngle: .degrees(270),
    //     clockwise: false
    // )

    // Move back to left edge (creating the vertical line)
    path.move(to: CGPoint(x: startX, y: cornerRadius))

    // Left edge line
    path.addLine(to: CGPoint(x: startX, y: rect.height - cornerRadius))

    // Bottom-left corner arc
    // path.addArc(
    //     center: CGPoint(x: cornerRadius, y: rect.height - cornerRadius),
    //     radius: cornerRadius - lineWidth / 2,
    //     startAngle: .degrees(180),
    //     endAngle: .degrees(90),
    //     clockwise: true
    // )

    return path.strokedPath(StrokeStyle(lineWidth: lineWidth, lineCap: .round))
  }
}

// MARK: - View Extensions

extension View {
  func cardStyle() -> some View {
    background(Color.cardBackground)
      .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg))
      .overlay(
        RoundedRectangle(cornerRadius: CornerRadius.lg)
          .stroke(Color.border, lineWidth: 1)
      )
  }

  func cellStyle(isSelected: Bool = false, isHovered: Bool = false) -> some View {
    background(Color.cellBackground)
      .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg))
      .overlay(
        RoundedRectangle(cornerRadius: CornerRadius.lg)
          .stroke(
            isSelected
              ? Color.accent : (isHovered ? Color.foregroundMuted.opacity(0.3) : Color.border),
            lineWidth: isSelected ? 0.5 : 1
          )
      )
  }

  func inputStyle() -> some View {
    padding(Spacing.sm)
      .background(Color.inputBackground)
      .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
      .overlay(
        RoundedRectangle(cornerRadius: CornerRadius.md)
          .stroke(Color.border, lineWidth: 1)
      )
  }

  @ViewBuilder
  func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
    if condition {
      transform(self)
    } else {
      self
    }
  }

  /// Set cursor for the view
  func cursor(_ cursor: NSCursor) -> some View {
    self.onContinuousHover { phase in
      switch phase {
      case .active:
        cursor.push()
      case .ended:
        NSCursor.pop()
      }
    }
  }
}
