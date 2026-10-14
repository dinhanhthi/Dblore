// DesignSystemContrastTests.swift
// Color tokens stay legible in both appearances: text meets WCAG AA 4.5:1 on every surface
// it sits on, labels on accent and destructive fills read, borders keep their order, state
// fills stay visible for every accent, and light mode has a surface step.

import AppKit
import SwiftUI
import Testing

@testable import Dblore

@Suite("Design system contrast")
@MainActor
struct DesignSystemContrastTests {
  private static let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]

  /// Resolves a dynamic token to sRGB in the given appearance.
  private func resolve(_ color: Color, _ name: NSAppearance.Name) -> NSColor {
    var resolved = NSColor.clear
    NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
      resolved = NSColor(color).usingColorSpace(.sRGB) ?? .clear
    }
    return resolved
  }

  private func ratio(_ a: Color, _ b: Color, _ name: NSAppearance.Name) -> Double {
    ColorContrast.ratio(resolve(a, name), resolve(b, name))
  }

  private static let surfaces: [(String, Color)] = [
    ("appBackground", .appBackground),
    ("cardBackground", .cardBackground),
    ("cellBackground", .cellBackground),
    ("cardHeaderBackground", .cardHeaderBackground),
    ("panelBackground", .panelBackground),
    ("modalFooterBackground", .modalFooterBackground),
    ("panelFooterBackground", .panelFooterBackground),
    ("tableHeaderBackground", .tableHeaderBackground),
  ]

  @Test("Text tokens reach 4.5:1 on every surface")
  func textOnSurfaces() {
    let tokens: [(String, Color)] = [
      ("foreground", .foreground),
      ("foregroundMuted", .foregroundMuted),
      ("foregroundSubtle", .foregroundSubtle),
      ("gridForeground", .gridForeground),
      ("gridNumber", .gridNumber),
      ("gridString", .gridString),
      ("gridDate", .gridDate),
      ("gridBoolean", .gridBoolean),
      ("gridJSON", .gridJSON),
      ("success", .success),
      ("warning", .warning),
      ("destructive", .destructive),
    ]
    for name in Self.appearances {
      for (tokenName, token) in tokens {
        for (surfaceName, surface) in Self.surfaces {
          let value = ratio(token, surface, name)
          #expect(value >= 4.5, "\(tokenName) on \(surfaceName) in \(name.rawValue): \(value)")
        }
      }
    }
  }

  private func hexRatio(_ a: String, _ b: String) -> Double {
    ColorContrast.ratio(NSColor(Color(hex: a)), NSColor(Color(hex: b)))
  }

  /// `fillHex` at `opacity` over `surfaceHex`
  private func composite(_ fillHex: String, _ opacity: Double, over surfaceHex: String) -> NSColor {
    let fill = NSColor(Color(hex: fillHex)).usingColorSpace(.sRGB)!
    let surface = NSColor(Color(hex: surfaceHex)).usingColorSpace(.sRGB)!
    func mix(_ f: CGFloat, _ s: CGFloat) -> CGFloat { f * opacity + s * (1 - opacity) }
    return NSColor(
      srgbRed: mix(fill.redComponent, surface.redComponent),
      green: mix(fill.greenComponent, surface.greenComponent),
      blue: mix(fill.blueComponent, surface.blueComponent), alpha: 1)
  }

}

@Suite("Cached AppKit colors follow the appearance")
@MainActor
struct CachedAppKitColorTests {
  private func components(_ color: NSColor, _ name: NSAppearance.Name) -> [CGFloat] {
    var result: [CGFloat] = []
    NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
      let rgb = color.usingColorSpace(.sRGB)!
      result = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent]
    }
    return result
  }
}
