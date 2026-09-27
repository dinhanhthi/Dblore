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

  /// Capsule glass for the selected tab. The shared `id` inside a `GlassEffectContainer`
  /// lets the glass morph from the old selected tab to the new one.
  func selectedTabGlass(id: some Hashable & Sendable, in namespace: Namespace.ID) -> some View {
    glassEffect(.regular, in: Capsule())
      .glassEffectID(id, in: namespace)
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
