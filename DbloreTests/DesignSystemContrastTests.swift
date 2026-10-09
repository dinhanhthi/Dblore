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

  @Test("borderStrong is stronger than border, and border stays visible on the window")
  func borderOrder() {
    for name in Self.appearances {
      let strong = ratio(.borderStrong, .cardBackground, name)
      let regular = ratio(.border, .cardBackground, name)
      #expect(strong > regular, "\(name.rawValue): strong \(strong), border \(regular)")
      let onWindow = ratio(.border, .appBackground, name)
      #expect(onWindow >= 1.15, "\(name.rawValue): border on window \(onWindow)")
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

  private func hexRatio(_ a: String, _ b: String) -> Double {
    ColorContrast.ratio(NSColor(Color(hex: a)), NSColor(Color(hex: b)))
  }

  @Test("The label on every accent fill, resting and pressed, reaches 4.5:1")
  func labelOnAccent() {
    for accent in AccentColor.allCases {
      for (fills, mode) in [
        ([accent.lightHex, accent.mutedLightHex], "light"),
        ([accent.darkHex, accent.mutedDarkHex], "dark"),
      ] {
        let label = ColorContrast.labelHex(on: fills[0])
        for fill in fills {
          let value = hexRatio(label, fill)
          #expect(value >= 4.5, "\(accent.rawValue) \(mode) \(fill): \(value)")
        }
      }
    }
  }

  @Test("Accent reads as text on cards and syntax keywords on the editor")
  func accentAsText() {
    for accent in AccentColor.allCases {
      for (hex, surface, mode) in [
        (accent.lightHex, "ffffff", "light"),
        (accent.darkHex, "252526", "dark"),
        (accent.syntaxLightHex, "ffffff", "light keyword"),
        (accent.syntaxDarkHex, "252526", "dark keyword"),
      ] {
        let value = hexRatio(hex, surface)
        #expect(value >= 4.5, "\(accent.rawValue) \(mode): \(value)")
      }
    }
  }

  @Test("Destructive fill keeps its label at 4.5:1")
  func labelOnDestructive() {
    for name in Self.appearances {
      let label = resolve(.onDestructive, name)
      let fill = resolve(.destructive, name)
      let card = resolve(.cardBackground, name)
      // Pressed: destructive at 0.85 over the card
      func mix(_ f: CGFloat, _ c: CGFloat) -> CGFloat { f * 0.85 + c * 0.15 }
      let pressed = NSColor(
        srgbRed: mix(fill.redComponent, card.redComponent),
        green: mix(fill.greenComponent, card.greenComponent),
        blue: mix(fill.blueComponent, card.blueComponent), alpha: 1)
      for (state, background) in [("resting", fill), ("pressed", pressed)] {
        let value = ColorContrast.ratio(label, background)
        #expect(value >= 4.5, "\(name.rawValue) \(state): \(value)")
      }
    }
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

  @Test("Selected rows stand out at 1.3:1 and hovered rows at 1.1:1 for every accent")
  func stateFills() {
    for accent in AccentColor.allCases {
      for (hex, surface, selection, hover, mode) in [
        (accent.lightHex, "ffffff", StateFill.selectionLight, StateFill.hoverLight, "light"),
        (accent.darkHex, "252526", StateFill.selectionDark, StateFill.hoverDark, "dark"),
      ] {
        let base = NSColor(Color(hex: surface))
        let selected = ColorContrast.ratio(composite(hex, selection, over: surface), base)
        let hovered = ColorContrast.ratio(composite(hex, hover, over: surface), base)
        #expect(selected >= 1.3, "\(accent.rawValue) \(mode) selection: \(selected)")
        #expect(hovered >= 1.1, "\(accent.rawValue) \(mode) hover: \(hovered)")
      }
    }
  }

  @Test("Neutral hover stands out at 1.1:1")
  func neutralHover() {
    for (ink, surface, mode) in [("09090b", "ffffff", "light"), ("fafafa", "252526", "dark")] {
      let value = ColorContrast.ratio(
        composite(ink, StateFill.neutralHover, over: surface), NSColor(Color(hex: surface)))
      #expect(value >= 1.1, "\(mode): \(value)")
    }
  }

  @Test("Controls stand off tinted panels, and off cards by fill or border")
  func controlsOnPanels() {
    for name in Self.appearances {
      let onPanel = ratio(.controlBackground, .cardHeaderBackground, name)
      #expect(onPanel >= 1.08, "\(name.rawValue): control on panel \(onPanel)")
      for surface in [Color.cardBackground, .cardHeaderBackground] {
        let fill = ratio(.controlBackground, surface, name)
        let edge = ratio(.border, surface, name)
        #expect(max(fill, edge) >= 1.15, "\(name.rawValue): fill \(fill), border \(edge)")
      }
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

  @Test("Result grid colors cached in statics resolve per appearance")
  func gridStatics() {
    let colors: [(String, NSColor)] = [
      ("alternate", ResultGridRowView.alternateColor),
      ("inserted", ResultGridRowView.insertedColor),
      ("deleted", ResultGridRowView.deletedColor),
      ("edited", ResultGridRowView.editedCellColor),
      ("text", ResultGridCoordinator.textColor),
      ("null", ResultGridCoordinator.nullTextColor),
      ("rowNumberText", ResultGridRowNumberCell.textColor),
      ("rowNumberBackground", ResultGridRowNumberCell.backgroundColor),
      ("rowNumberSeparator", ResultGridRowNumberCell.separatorColor),
    ]
    for (label, color) in colors {
      #expect(components(color, .aqua) != components(color, .darkAqua), "\(label) is frozen")
    }
  }
}
