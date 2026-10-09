// DesignSystemContrastTests.swift
// Color tokens stay legible in both appearances: text meets WCAG AA 4.5:1 on every surface
// it sits on, the "subtle" border is the lighter one, and light mode has a surface step.

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
    ("tableHeaderBackground", .tableHeaderBackground),
  ]

  @Test("Text tokens reach 4.5:1 on every surface")
  func textOnSurfaces() {
    let tokens: [(String, Color)] = [
      ("foreground", .foreground),
      ("foregroundMuted", .foregroundMuted),
      ("foregroundSubtle", .foregroundSubtle),
      ("gridForeground", .gridForeground),
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

  @Test("Gutter digits reach 4.5:1")
  func gutterDigits() {
    for name in Self.appearances {
      let value = ratio(.foregroundSubtle, .gutterBackground, name)
      #expect(value >= 4.5, "gutter in \(name.rawValue): \(value)")
    }
  }

  @Test("SQL comments reach 4.5:1 on editor surfaces")
  func comments() {
    for name in Self.appearances {
      for surface in [Color.appBackground, .cellBackground] {
        let value = ratio(.syntaxComment, surface, name)
        #expect(value >= 4.5, "comment in \(name.rawValue): \(value)")
      }
    }
  }

  @Test("borderSubtle is lighter than border")
  func borderOrder() {
    for name in Self.appearances {
      let subtle = ratio(.borderSubtle, .cardBackground, name)
      let regular = ratio(.border, .cardBackground, name)
      #expect(subtle < regular, "\(name.rawValue): subtle \(subtle), border \(regular)")
    }
  }

  @Test("Schema node border is no stronger than borderStrong")
  func schemaBorder() {
    for name in Self.appearances {
      let node = ratio(.schemaNodeBorder, .cardBackground, name)
      let strong = ratio(.borderStrong, .cardBackground, name)
      #expect(node <= strong, "\(name.rawValue): node \(node), borderStrong \(strong)")
    }
  }

  @Test("Cards stand off the window background in both appearances")
  func surfaceStep() {
    for name in Self.appearances {
      let value = ratio(.cardBackground, .appBackground, name)
      #expect(value >= 1.03, "\(name.rawValue): \(value)")
    }
  }
}
