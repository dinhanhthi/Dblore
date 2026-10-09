//
//  DesignSystem+Colors.swift
//  Dblore
//
//  Color definitions for the design system
//

import SwiftUI

// MARK: - Colors

extension Color {
  // Background colors. Dark mode follows VS Code Dark:
  // editor #1E1E1E, sidebar #252526, inactive tab #2D2D2D, input #3C3C3C.
  static let appBackground = Color(
    light: Color(hex: "fafafa"),  // Zinc 50, one step under white cards and cells
    dark: Color(hex: "1e1e1e")  // VS Code editor
  )

  static let cardBackground = Color(
    light: Color(hex: "ffffff"),
    dark: Color(hex: "252526")  // VS Code sidebar
  )

  static let cardHeaderBackground = Color(
    light: Color(hex: "f5f5f5"),
    dark: Color(hex: "2d2d2d")  // VS Code inactive tab
  )

  static let cellBackground = Color(
    light: Color(hex: "ffffff"),  // White
    dark: Color(hex: "252526")  // VS Code sidebar
  )

  static let cellBackgroundHover = Color(
    light: Color(hex: "f3f4f6"),  // Gray 100
    dark: Color(hex: "2a2d2e")  // VS Code list hover
  )

  static let inputBackground = Color(
    // light: Color(hex: "f9fafb"),  // Light gray
    light: Color(hex: "f5f5f5"),
    dark: Color(hex: "3c3c3c")  // VS Code input
  )

  static let gutterBackground = Color(
    light: Color(hex: "f4f4f5"),  // Zinc 100, one quiet step off the white editor
    dark: Color(hex: "2d2d2d")  // One quiet step off the editor
  )

  // Foreground colors
  static let foreground = Color(
    light: Color(hex: "09090b"),  // Very dark zinc
    dark: Color(hex: "fafafa")  // Very light gray
  )

  static let foregroundMuted = Color(
    light: Color(hex: "52525b"),  // Zinc 600
    dark: Color(hex: "a1a1aa")  // Zinc 400
  )

  /// Faintest text that still reaches 4.5:1 on every surface and the gutter
  static let foregroundSubtle = Color(
    light: Color(hex: "63636b"),
    dark: Color(hex: "98989f")
  )

  /// Result grid cells: softer than `foreground`, stronger than `foregroundMuted`
  static let gridForeground = Color(
    light: Color(hex: "3f3f46"),  // Zinc 700
    dark: Color(hex: "d4d4d8")  // Zinc 300
  )

  // Border colors
  static let border = Color(
    light: Color(hex: "e4e4e7"),  // Zinc 200
    dark: Color(hex: "3c3c3c")  // VS Code input, visible on sidebar
  )

  /// One step stronger than `border`, for a divider that must stand out from grid lines
  static let borderStrong = Color(
    light: Color(hex: "d4d4d8"),  // Zinc 300
    dark: Color(hex: "454545")  // VS Code widget border
  )

  // Schema visualizer specific colors
  static let schemaNodeBorder = Color(
    light: Color(hex: "d4d4d8"),  // Zinc 300, same as borderStrong
    dark: Color(hex: "454545")  // Slightly lighter than border
  )

  static let schemaNodeHeader = Color(
    light: Color(hex: "e4e4e7"),  // Zinc 200 (darker than cardHeaderBackground's f5f5f5)
    dark: Color(hex: "2d2d2d")  // Same as cardHeaderBackground
  )

  static let schemaColumnText = Color(
    light: Color(hex: "3f3f46"),  // Zinc 700 (darker than foregroundMuted's Zinc 600)
    dark: Color(hex: "d4d4d8")  // Zinc 300 (lighter/whiter for better visibility)
  )

  static var borderFocus: Color {
    let accent = AppSettings.shared.accentColor
    return Color(
      light: Color(hex: accent.lightHex),
      dark: Color(hex: accent.darkHex)
    )
  }

  // Accent colors (dynamic based on user preference)
  static var accent: Color {
    let accent = AppSettings.shared.accentColor
    return Color(
      light: Color(hex: accent.lightHex),
      dark: Color(hex: accent.darkHex)
    )
  }

  static var accentMuted: Color {
    let accent = AppSettings.shared.accentColor
    return Color(
      light: Color(hex: accent.mutedLightHex),
      dark: Color(hex: accent.mutedDarkHex)
    )
  }

  /// Label on an accent fill: white or near-black, whichever reads better on that accent
  static var onAccent: Color {
    let accent = AppSettings.shared.accentColor
    return Color(
      light: Color(hex: ColorContrast.labelHex(on: accent.lightHex)),
      dark: Color(hex: ColorContrast.labelHex(on: accent.darkHex))
    )
  }

  /// Selected row or item: accent tint, at least 1.3:1 against its surface for every accent
  static var selectionFill: Color {
    let accent = AppSettings.shared.accentColor
    return Color(
      light: Color(hex: accent.lightHex).opacity(StateFill.selectionLight),
      dark: Color(hex: accent.darkHex).opacity(StateFill.selectionDark)
    )
  }

  /// Hovered row or item in an accent-tinted list, at least 1.1:1 against its surface
  static var accentHoverFill: Color {
    let accent = AppSettings.shared.accentColor
    return Color(
      light: Color(hex: accent.lightHex).opacity(StateFill.hoverLight),
      dark: Color(hex: accent.darkHex).opacity(StateFill.hoverDark)
    )
  }

  /// Hovered neutral control, at least 1.1:1 against its surface
  static let hoverFill = Color.foreground.opacity(StateFill.neutralHover)

  /// Drop shadow under floating surfaces: light enough for light mode, visible in dark mode
  static let shadow = Color(
    light: Color.black.opacity(0.12),
    dark: Color.black.opacity(0.4)
  )

  /// Dim layer behind a modal: lighter in light mode so the window doesn't go gray
  static let scrim = Color(
    light: Color.black.opacity(0.18),
    dark: Color.black.opacity(0.35)
  )

  // Semantic colors
  static let success = Color(
    light: Color(hex: "15803d"),  // Green 700
    dark: Color(hex: "22c55e")  // Green 500
  )

  static let warning = Color(
    light: Color(hex: "c2410c"),  // Orange 700
    dark: Color(hex: "f59e0b")  // Amber 500
  )

  static let destructive = Color(
    light: Color(hex: "b91c1c"),  // Red 700
    dark: Color(hex: "f87171")  // Red 400
  )

  /// Label on a `destructive` fill
  static let onDestructive = Color(
    light: Color(hex: "ffffff"),
    dark: Color(hex: "09090b")
  )

  // Light gray in both modes so the light-blue AI bubble icon stays visible
  static let aiBubbleBackground = Color(
    light: Color(hex: "e5e7eb"),  // Gray 200
    dark: Color(hex: "d1d5db")  // Gray 300
  )

  // Table colors
  static let tableHeaderBackground = Color(
    light: Color(hex: "f3f4f6"),  // Gray 100
    dark: Color(hex: "2d2d2d")  // VS Code inactive tab
  )

  static let tableRowAlternate = Color(
    light: Color(hex: "f9fafb"),  // Gray 50
    dark: Color(hex: "1e1e1e")  // Editor, darker stripe against cell rows
  )

  // Syntax highlighting colors (keyword color matches accent)
  static var syntaxKeyword: Color {
    let accent = AppSettings.shared.accentColor
    return Color(
      light: Color(hex: accent.syntaxLightHex),
      dark: Color(hex: accent.syntaxDarkHex)
    )
  }

  static let syntaxFunction = Color(
    light: Color(hex: "0284c7"),  // Sky 600
    dark: Color(hex: "38bdf8")  // Sky 400
  )

  static let syntaxString = Color(
    light: Color(hex: "16a34a"),  // Green 600
    dark: Color(hex: "4ade80")  // Green 400
  )

  static let syntaxNumber = Color(
    light: Color(hex: "ea580c"),  // Orange 600
    dark: Color(hex: "fb923c")  // Orange 400
  )

  static let syntaxComment = Color(
    light: Color(hex: "6b7280"),  // Gray 500
    dark: Color(hex: "8b919c")
  )

  static let syntaxOperator = Color(
    light: Color(hex: "09090b"),  // Very dark zinc
    dark: Color(hex: "fafafa")  // Very light gray
  )
}

/// Opacities of the state fills, kept apart so their contrast can be checked for every accent
enum StateFill {
  static let selectionLight = 0.22
  static let selectionDark = 0.2
  static let hoverLight = 0.1
  static let hoverDark = 0.1
  static let neutralHover = 0.06
}

/// WCAG 2 contrast between two opaque colors.
enum ColorContrast {
  static func ratio(_ a: NSColor, _ b: NSColor) -> Double {
    let la = luminance(a)
    let lb = luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
  }

  static func luminance(_ color: NSColor) -> Double {
    guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
    func channel(_ c: CGFloat) -> Double {
      let c = Double(c)
      return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(rgb.redComponent) + 0.7152 * channel(rgb.greenComponent)
      + 0.0722 * channel(rgb.blueComponent)
  }

  /// White or near-black (`foreground` light), whichever contrasts more with the fill
  static func labelHex(on fillHex: String) -> String {
    let fill = NSColor(Color(hex: fillHex))
    let white = ratio(NSColor(Color(hex: "ffffff")), fill)
    let ink = ratio(NSColor(Color(hex: "09090b")), fill)
    return white >= ink ? "ffffff" : "09090b"
  }
}

extension Color {
  /// Initialize an adaptive color with separate light and dark mode values
  init(light: Color, dark: Color) {
    #if os(macOS)
      self.init(
        nsColor: NSColor(name: nil) { appearance in
          switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
          case .darkAqua:
            return NSColor(dark)
          default:
            return NSColor(light)
          }
        })
    #else
      self.init(
        uiColor: UIColor { traitCollection in
          switch traitCollection.userInterfaceStyle {
          case .dark:
            return UIColor(dark)
          default:
            return UIColor(light)
          }
        })
    #endif
  }

  init(hex: String) {
    let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    var int: UInt64 = 0
    Scanner(string: hex).scanHexInt64(&int)
    let a: UInt64
    let r: UInt64
    let g: UInt64
    let b: UInt64
    switch hex.count {
    case 3:  // RGB (12-bit)
      (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
    case 6:  // RGB (24-bit)
      (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
    case 8:  // ARGB (32-bit)
      (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
    default:
      (a, r, g, b) = (255, 0, 0, 0)
    }
    self.init(
      .sRGB,
      red: Double(r) / 255,
      green: Double(g) / 255,
      blue: Double(b) / 255,
      opacity: Double(a) / 255
    )
  }
}
