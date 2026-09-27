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
