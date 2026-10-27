//
//  DesignSystem+Glass.swift
//  Dblore
//
//  Surfaces for the navigation/chrome layer. They paint fixed design-system tokens, so the
//  app looks the same on every macOS version: macOS defines how Liquid Glass looks and renders
//  it differently between releases (macOS 27 draws `.regular` glass much lighter).
//  The only exception (user decision 2026-10-26) is the floating header controls: the left and
//  right header button groups and the selected tab chip use Liquid Glass on macOS 26 and later,
//  and keep their token look before. Sidebars, panels, backgrounds and banners stay tokens.
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
  func tintedChromeGlass(_ color: Color, opacity: Double = 0.25) -> some View {
    background(color.opacity(opacity), in: Rectangle())
      .background(Color.appBackground, in: Rectangle())
  }
}

// MARK: - Header Controls (Liquid Glass on macOS 26+)

extension View {
  /// A floating header button group (the sidebar and connection buttons; the AI, theme,
  /// settings and new-tab buttons). macOS 26 and later: a glass capsule framing the icons, 36pt
  /// tall in the 40pt header row; the thin side padding keeps the left group clear of the
  /// traffic lights. Earlier: unchanged, no background.
  @ViewBuilder
  func headerControlsGlass() -> some View {
    if #available(macOS 26, *) {
      padding(.horizontal, Spacing.xxs)
        .padding(.vertical, Spacing.xs)
        .glassEffect(.regular, in: Capsule())
    } else {
      self
    }
  }
}

/// The capsule behind the selected tab of the header tab strip. macOS 26 and later: a glass
/// capsule. Earlier: a neutral tint of the foreground color.
struct SelectedChipBackground: View {
  var body: some View {
    if #available(macOS 26, *) {
      Color.clear.glassEffect(.regular, in: Capsule())
    } else {
      Capsule().fill(Color.foreground.opacity(0.12))
    }
  }
}
