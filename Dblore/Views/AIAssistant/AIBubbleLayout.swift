//
//  AIBubbleLayout.swift
//  Dblore
//
//  Geometry for the floating AI bubble
//

import SwiftUI

/// Pure geometry of the AI bubble: circle position along the bottom edge, card placement
/// above the circle, card height bounds and the scale anchor of the expand transition.
enum AIBubbleLayout {
  static let circleDiameter: CGFloat = 44
  static let margin: CGFloat = Spacing.md
  static let gap: CGFloat = Spacing.sm
  static let cardWidth: CGFloat = ComponentSize.sidebarWidth
  static let minCardHeight: CGFloat = 360
  static let maxCardHeight: CGFloat = 640

  private static var radius: CGFloat { circleDiameter / 2 }

  private static func centerRange(containerWidth: CGFloat) -> (min: CGFloat, max: CGFloat) {
    (margin + radius, containerWidth - margin - radius)
  }

  /// Circle center x for a 0...1 position fraction; out-of-range fractions clamp.
  static func circleCenterX(fraction: Double, containerWidth: CGFloat) -> CGFloat {
    let range = centerRange(containerWidth: containerWidth)
    let clamped = CGFloat(min(max(fraction, 0), 1))
    return range.min + clamped * (range.max - range.min)
  }

  /// Position fraction (0...1) for a circle center x. Returns 0 when the range is empty.
  static func fraction(forCenterX centerX: CGFloat, containerWidth: CGFloat) -> Double {
    let range = centerRange(containerWidth: containerWidth)
    let span = range.max - range.min
    guard span > 0 else { return 0 }
    return Double(min(max((centerX - range.min) / span, 0), 1))
  }

  /// Card leading x: centered on the circle, clamped to the margins. Pins to the leading
  /// margin when the container is narrower than the card plus both margins.
  static func cardMinX(circleCenterX: CGFloat, containerWidth: CGFloat) -> CGFloat {
    let maxX = containerWidth - margin - cardWidth
    guard maxX >= margin else { return margin }
    return min(max(circleCenterX - cardWidth / 2, margin), maxX)
  }

  /// Card height: 75% of the container clamped to min...max, then capped so the card stays
  /// below the tab bar. Never negative.
  static func cardHeight(containerHeight: CGFloat) -> CGFloat {
    let preferred = min(max(containerHeight * 0.75, minCardHeight), maxCardHeight)
    let cap = containerHeight - ComponentSize.tabBarHeight - circleDiameter - 2 * margin - gap
    return max(min(preferred, cap), 0)
  }

  /// Scale anchor (in card unit space) pointing at the circle center below the card.
  static func scaleAnchor(
    circleCenterX: CGFloat, cardMinX: CGFloat, cardHeight: CGFloat
  )
    -> UnitPoint
  {
    let x = (circleCenterX - cardMinX) / cardWidth
    let y = cardHeight > 0 ? (cardHeight + gap + radius) / cardHeight : 1
    return UnitPoint(x: x, y: y)
  }
}
