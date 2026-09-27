//
//  DesignSystem+Glass.swift
//  SQLNotebook
//
//  Liquid Glass building blocks for the navigation/chrome layer.
//  Views call these instead of raw `glassEffect`. Never use glass on the
//  result grid or editor text.
//

import SwiftUI

// MARK: - Glass Modifiers

extension View {
  /// Glass for edge-to-edge chrome surfaces (tab bar, header, sidebars).
  /// Rectangular because these surfaces butt against the window edges.
  func chromeGlass() -> some View {
    glassEffect(.regular, in: Rectangle())
  }

  /// Glass for floating bars and capsules, matching the existing capsule floating bars.
  func floatingBarGlass() -> some View {
    glassEffect(.regular, in: Capsule())
  }

  /// Tinted capsule glass for small status badges (e.g. Safe Mode indicator).
  /// The tint keeps the badge's color meaning on glass. Pass `interactive: false` for
  /// passive notices that cannot be clicked.
  func tintedCapsuleGlass(_ color: Color, interactive: Bool = true) -> some View {
    glassEffect(.regular.tint(color.opacity(0.25)).interactive(interactive), in: Capsule())
  }

  /// Tinted edge-to-edge glass for workspace banners (pending transaction, connection lost).
  func tintedChromeGlass(_ color: Color) -> some View {
    glassEffect(.regular.tint(color.opacity(0.25)), in: Rectangle())
  }

  /// Accent-tinted capsule glass for the selected tab, applied to the tab label itself so the
  /// label is drawn as the glass content (a glass on a background sibling inside a
  /// `GlassEffectContainer` is composited over the label and hides it). Inactive tabs get
  /// `.identity` (no glass) so the modifier chain stays stable. The active tab uses
  /// `activeID`, inactive tabs their own unique `inactiveID`, so the glass morphs from the
  /// old selected tab to the new one.
  func selectedTabGlass(
    isActive: Bool, activeID: String, inactiveID: String, in namespace: Namespace.ID
  ) -> some View {
    glassEffect(isActive ? .regular.tint(Color.accent.opacity(0.2)) : .identity, in: Capsule())
      .glassEffectID(isActive ? activeID : inactiveID, in: namespace)
      .overlay {
        if isActive {
          Capsule().strokeBorder(Color.accent.opacity(0.35), lineWidth: 1)
        }
      }
  }
}

// MARK: - Glass Toolbar Group

/// Groups glass controls so their shapes blend and morph together.
struct GlassToolbarGroup<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    GlassEffectContainer(spacing: Spacing.sm) {
      HStack(spacing: Spacing.sm) {
        content
      }
    }
  }
}
