//
//  DesignSystem+Glass.swift
//  Dblore
//
//  Surfaces for the navigation/chrome layer. The names are historic: these used Liquid
//  Glass, whose look is defined by macOS and changed between releases (macOS 27 renders
//  `.regular` glass much lighter). They now paint fixed design-system tokens only, so the
//  app looks the same on every macOS version. Never use system materials or glass here.
//

import SwiftUI

// MARK: - Chrome Surfaces

extension View {
  /// Edge-to-edge chrome surfaces (sidebars, header strips).
  /// Rectangular because these surfaces butt against the window edges.
  func chromeGlass() -> some View {
    background(Color.appBackground, in: Rectangle())
  }

  /// Floating bars and capsules.
  func floatingBarGlass() -> some View {
    background(Color.cardBackground, in: Capsule())
  }

  /// Tinted capsule for small status badges (e.g. Safe Mode indicator).
  /// The tint keeps the badge's color meaning on any surface.
  func tintedCapsuleGlass(_ color: Color) -> some View {
    background(color.opacity(0.25), in: Capsule())
  }

  /// Tinted edge-to-edge surface for workspace banners (pending transaction, connection lost).
  func tintedChromeGlass(_ color: Color) -> some View {
    background(color.opacity(0.25), in: Rectangle())
      .background(Color.appBackground, in: Rectangle())
  }
}
