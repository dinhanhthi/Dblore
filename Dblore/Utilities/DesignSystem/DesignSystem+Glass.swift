//
//  DesignSystem+Glass.swift
//  Dblore
//
//  Liquid Glass building blocks for the navigation/chrome layer.
//  Views call these instead of raw `glassEffect` or glass button styles.
//  Never use glass on the result grid or editor text. Below macOS 26 (no
//  Liquid Glass) they fall back to `.regularMaterial` on the same shape,
//  tinted where glass is tinted, and to the bordered button styles.
//

import SwiftUI

// MARK: - Glass Modifiers

extension View {
  /// Glass for edge-to-edge chrome surfaces (tab bar, header, sidebars).
  /// Rectangular because these surfaces butt against the window edges.
  @ViewBuilder
  func chromeGlass() -> some View {
    if #available(macOS 26, *) {
      glassEffect(.regular, in: Rectangle())
    } else {
      background(.regularMaterial, in: Rectangle())
    }
  }

  /// Glass for floating bars and capsules, matching the existing capsule floating bars.
  @ViewBuilder
  func floatingBarGlass() -> some View {
    if #available(macOS 26, *) {
      glassEffect(.regular, in: Capsule())
    } else {
      background(.regularMaterial, in: Capsule())
    }
  }

  /// Tinted capsule glass for small status badges (e.g. Safe Mode indicator).
  /// The tint keeps the badge's color meaning on glass. Pass `interactive: false` for
  /// passive notices that cannot be clicked.
  @ViewBuilder
  func tintedCapsuleGlass(_ color: Color, interactive: Bool = true) -> some View {
    if #available(macOS 26, *) {
      glassEffect(.regular.tint(color.opacity(0.25)).interactive(interactive), in: Capsule())
    } else {
      background(color.opacity(0.25), in: Capsule())
        .background(.regularMaterial, in: Capsule())
    }
  }

  /// Tinted edge-to-edge glass for workspace banners (pending transaction, connection lost).
  @ViewBuilder
  func tintedChromeGlass(_ color: Color) -> some View {
    if #available(macOS 26, *) {
      glassEffect(.regular.tint(color.opacity(0.25)), in: Rectangle())
    } else {
      background(color.opacity(0.25), in: Rectangle())
        .background(.regularMaterial, in: Rectangle())
    }
  }
}

// MARK: - Glass Button Styles

extension View {
  /// Glass button style (prominent for the primary action). The border is a capsule, same as
  /// `PrimaryButtonStyle`. Below macOS 26 it falls back to the bordered styles.
  func glassButtonStyle(prominent: Bool = false) -> some View {
    glassChrome(prominent: prominent)
      .buttonBorderShape(.capsule)
  }

  @ViewBuilder
  private func glassChrome(prominent: Bool) -> some View {
    if #available(macOS 26, *) {
      if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
    } else {
      if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
    }
  }
}

// MARK: - Glass Toolbar Group

/// Groups glass controls so their shapes blend and morph together.
struct GlassToolbarGroup<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    if #available(macOS 26, *) {
      GlassEffectContainer(spacing: Spacing.sm) {
        HStack(spacing: Spacing.sm) {
          content
        }
      }
    } else {
      HStack(spacing: Spacing.sm) {
        content
      }
    }
  }
}
