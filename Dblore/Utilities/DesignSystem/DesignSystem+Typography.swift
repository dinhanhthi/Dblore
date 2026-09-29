//
//  DesignSystem+Typography.swift
//  Dblore
//
//  Typography styles for the design system
//

import SwiftUI

// MARK: - Typography

extension Font {
  static let mono = Font.system(.body, design: .monospaced)  // 13pt
  static let monoMedium = Font.system(.callout, design: .monospaced)  // 12pt
  static let monoSmall = Font.system(.footnote, design: .monospaced)  // 10pt
  static let monoLarge = Font.system(.title3, design: .monospaced)  // 20pt

  static let heading = Font.system(.title2, weight: .semibold)  // 17pt
  static let subheading = Font.system(.title3, weight: .medium)  // 15pt
  static let bodyText = Font.system(.body)  // 13pt
  static let labelText = Font.system(.callout)  // 12pt
  static let small = Font.system(.subheadline)  // 11pt
  static let smallest = Font.system(.caption)  // 10pt
}
