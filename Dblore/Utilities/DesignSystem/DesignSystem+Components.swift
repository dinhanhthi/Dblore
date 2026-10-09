//
//  DesignSystem+Components.swift
//  Dblore
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
  case filledSecondary
  case danger
  case ghost

  func backgroundColor(isPressed: Bool, isHovering: Bool = false) -> Color {
    switch self {
    case .primary:
      return isPressed ? Color.accentMuted : Color.accent
    case .secondary:
      return isPressed ? Color.cellBackgroundHover : Color.clear
    case .filledSecondary:
      return isPressed ? Color.cellBackgroundHover : Color.inputBackground
    case .danger:
      return isPressed ? Color.destructive.opacity(0.85) : Color.destructive
    case .ghost:
      if isPressed {
        return Color.cellBackgroundHover
      } else if isHovering {
        return Color.hoverFill
      } else {
        return Color.clear
      }
    }
  }

  var hasBorder: Bool {
    self == .secondary || self == .filledSecondary
  }

  var foregroundColor: Color {
    .foreground
  }

  func foregroundColor(isPressed: Bool, isHovering: Bool = false, isActive: Bool = false) -> Color {
    switch self {
    case .ghost:
      return isPressed || isHovering || isActive ? .foreground : .foregroundMuted
    case .primary:
      return .onAccent
    case .danger:
      return .onDestructive
    default:
      return isActive ? .accent : .foreground
    }
  }
}

/// Regular text-button chrome. Capsule dropdowns and number fields share it
/// so those controls line up with `PrimaryButtonStyle` and `SecondaryButtonStyle`.
enum ButtonMetrics {
  static let regularFont: Font = .system(.callout, weight: .medium)
  static let regularHorizontalPadding: CGFloat = (Spacing.md + Spacing.lg) / 2
  static let regularVerticalPadding: CGFloat = (Spacing.xs + Spacing.sm) / 2
  /// Callout line (16) plus the regular vertical padding on both sides.
  static let regularHeight: CGFloat = 16 + regularVerticalPadding * 2
}

// MARK: - Button Styles
struct PrimaryButtonStyle: ButtonStyle {
  var iconOnly: Bool = false
  var hPadding: CGFloat? = nil
  var vPadding: CGFloat? = nil

  func makeBody(configuration: Configuration) -> some View {
    BaseButtonStyleView(
      variant: .primary, iconOnly: iconOnly, hPadding: hPadding,
      vPadding: vPadding, configuration: configuration
    )
  }
}

struct SecondaryButtonStyle: ButtonStyle {
  var iconOnly: Bool = false
  var hPadding: CGFloat? = nil
  var vPadding: CGFloat? = nil

  func makeBody(configuration: Configuration) -> some View {
    BaseButtonStyleView(
      variant: .secondary, iconOnly: iconOnly, hPadding: hPadding,
      vPadding: vPadding, configuration: configuration
    )
  }
}

struct FilledSecondaryButtonStyle: ButtonStyle {
  var iconOnly: Bool = false
  var hPadding: CGFloat? = nil
  var vPadding: CGFloat? = nil

  func makeBody(configuration: Configuration) -> some View {
    BaseButtonStyleView(
      variant: .filledSecondary, iconOnly: iconOnly, hPadding: hPadding,
      vPadding: vPadding, configuration: configuration
    )
  }
}

struct DangerButtonStyle: ButtonStyle {
  var iconOnly: Bool = false
  var hPadding: CGFloat? = nil
  var vPadding: CGFloat? = nil

  func makeBody(configuration: Configuration) -> some View {
    BaseButtonStyleView(
      variant: .danger, iconOnly: iconOnly, hPadding: hPadding,
      vPadding: vPadding, configuration: configuration
    )
  }
}

struct GhostButtonStyle: ButtonStyle {
  var isActive: Bool = false
  var iconOnly: Bool = false
  var hPadding: CGFloat? = nil
  var vPadding: CGFloat? = nil

  func makeBody(configuration: Configuration) -> some View {
    BaseButtonStyleView(
      variant: .ghost, isActive: isActive, iconOnly: iconOnly, hPadding: hPadding,
      vPadding: vPadding, configuration: configuration
    )
  }
}

/// Internal view that properly receives environment values
private struct BaseButtonStyleView: View {
  let variant: ButtonStyleVariant
  var isActive: Bool = false
  var iconOnly: Bool = false
  var hPadding: CGFloat? = nil
  var vPadding: CGFloat? = nil
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
      return ButtonMetrics.regularFont
    }
  }

  /// Font size boost for iconOnly buttons (makes icon slightly larger)
  private var iconFontSize: CGFloat? {
    guard iconOnly else { return nil }
    switch controlSize {
    case .mini:
      return 9
    case .small:
      return 11
    case .large, .extraLarge:
      return 14
    default:  // .regular
      return 12
    }
  }

  private var horizontalPadding: CGFloat {
    if let hPadding { return hPadding }
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
      return ButtonMetrics.regularHorizontalPadding
    }
  }

  private var verticalPadding: CGFloat {
    if let vPadding { return vPadding }
    switch controlSize {
    case .mini:
      return Spacing.xxs
    case .small:
      return iconOnly ? Spacing.sm - 2 : Spacing.xs
    case .large, .extraLarge:
      return Spacing.md
    default:  // .regular
      return iconOnly ? Spacing.sm : ButtonMetrics.regularVerticalPadding
    }
  }

  var body: some View {
    configuration.label
      .font(iconFontSize.map { Font.system(size: $0) } ?? font)
      .foregroundColor(
        variant.foregroundColor(
          isPressed: configuration.isPressed, isHovering: isHovering, isActive: isActive)
      )
      .padding(.horizontal, horizontalPadding)
      .padding(.vertical, verticalPadding)
      .background {
        if iconOnly {
          Circle()
            .fill(
              variant.backgroundColor(isPressed: isHovering || isActive, isHovering: isHovering))
        } else {
          Capsule()
            .fill(
              variant.backgroundColor(isPressed: isHovering || isActive, isHovering: isHovering))
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
      .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
      .animation(.easeInOut(duration: 0.15), value: isHovering)
      .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
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
              .fill(Color.selectionFill)
          }
        }
        .shadow(color: Color.shadow, radius: 4, x: 0, y: 2)
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
              .fill(Color.selectionFill)
          }
        }
        .shadow(color: Color.shadow, radius: 4, x: 0, y: 2)
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
      .clipShape(RoundedRectangle(cornerRadius: CornerRadius.xxl))
      .overlay(
        RoundedRectangle(cornerRadius: CornerRadius.xxl)
          .stroke(Color.border, lineWidth: 1)
      )
  }

  /// Capsule style for input fields
  func inputCapsuleStyle() -> some View {
    padding(.vertical, Spacing.sm)
      .padding(.horizontal, Spacing.md)
      .background(Color.inputBackground)
      .clipShape(Capsule())
      .overlay(
        Capsule()
          .stroke(Color.border, lineWidth: 1)
      )
  }

  /// Numeric field. `inputCapsuleStyle` adds `Spacing.sm` on top of the text
  /// control, which makes number boxes taller than a regular button.
  func numberInputCapsuleStyle() -> some View {
    self
      .font(.monoMedium)
      .controlSize(.small)
      .padding(.horizontal, Spacing.sm)
      .frame(height: ButtonMetrics.regularHeight)
      .background(Color.inputBackground)
      .clipShape(Capsule())
      .overlay(
        Capsule()
          .stroke(Color.border, lineWidth: 1)
      )
  }

  /// Beside a number capsule. A default `Stepper` stays at AppKit `.regular`,
  /// so the up/down chevrons draw larger than the field.
  func compactStepperStyle() -> some View {
    self
      .labelsHidden()
      .controlSize(.mini)
  }

  /// Capsule style for dropdown menus and pickers
  func dropdownCapsuleStyle() -> some View {
    padding(.vertical, Spacing.sm)
      .padding(.horizontal, Spacing.sm + 2)
      .background(Color.inputBackground)
      .clipShape(Capsule())
      .overlay(
        Capsule()
          .stroke(Color.border, lineWidth: 1)
      )
  }

  /// Rounded style for multiline text fields with capsule-like radius
  func textAreaCapsuleStyle() -> some View {
    padding(Spacing.sm)
      .background(Color.inputBackground)
      .clipShape(RoundedRectangle(cornerRadius: CornerRadius.xxxl))
      .overlay(
        RoundedRectangle(cornerRadius: CornerRadius.xxxl)
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
