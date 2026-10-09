// AIBubbleLayoutTests.swift
// Pure geometry of the AI bubble: circle position along the bottom edge, card placement
// above the circle, card height bounds and the scale anchor of the expand transition.

import CoreGraphics
import SwiftUI
import Testing

@testable import Dblore

@Suite("AI bubble layout")
@MainActor
struct AIBubbleLayoutTests {

  private typealias L = AIBubbleLayout

  private static let tolerance: CGFloat = 0.0001

  private func approx(_ a: CGFloat, _ b: CGFloat) -> Bool {
    abs(a - b) < Self.tolerance
  }

  private var radius: CGFloat { L.circleDiameter / 2 }

  @Test("fraction 0 and 1 map to the clamped extremes; out-of-range fractions clamp")
  func circleCenterClampsFractionToMargins() {
    let width: CGFloat = 1000
    let minCenter = L.margin + radius
    let maxCenter = width - L.margin - radius

    #expect(approx(L.circleCenterX(fraction: 0, containerWidth: width), minCenter))
    #expect(approx(L.circleCenterX(fraction: 1, containerWidth: width), maxCenter))
    #expect(
      approx(L.circleCenterX(fraction: 0.5, containerWidth: width), (minCenter + maxCenter) / 2))
    #expect(approx(L.circleCenterX(fraction: -0.3, containerWidth: width), minCenter))
    #expect(approx(L.circleCenterX(fraction: 1.7, containerWidth: width), maxCenter))
  }

  @Test("fraction -> center -> fraction round-trips, and off-range centers clamp to 0...1")
  func fractionRoundTrips() {
    let width: CGFloat = 900
    for fraction in [0.0, 0.25, 0.5, 0.8, 1.0] {
      let center = L.circleCenterX(fraction: fraction, containerWidth: width)
      let back = L.fraction(forCenterX: center, containerWidth: width)
      #expect(abs(back - fraction) < 0.0001)
    }
    #expect(L.fraction(forCenterX: 0, containerWidth: width) == 0)
    #expect(L.fraction(forCenterX: width, containerWidth: width) == 1)
  }

  @Test("the card is horizontally centered on the circle when there is room")
  func cardCentersOnCircle() {
    let width: CGFloat = 1200
    let center: CGFloat = 600
    let minX = L.cardMinX(circleCenterX: center, containerWidth: width)
    #expect(approx(minX, center - L.cardWidth / 2))
    #expect(approx(minX + L.cardWidth / 2, center))
  }

  @Test("the card clamps to the leading and trailing margins")
  func cardClampsAtLeadingAndTrailingEdges() {
    let width: CGFloat = 1200
    let leadingCenter = L.circleCenterX(fraction: 0, containerWidth: width)
    let trailingCenter = L.circleCenterX(fraction: 1, containerWidth: width)

    #expect(approx(L.cardMinX(circleCenterX: leadingCenter, containerWidth: width), L.margin))
    #expect(
      approx(
        L.cardMinX(circleCenterX: trailingCenter, containerWidth: width),
        width - L.margin - L.cardWidth))
  }

  @Test("the card pins to the leading margin when the container is narrower than the card")
  func cardPinsLeadingWhenContainerNarrowerThanCard() {
    let width = L.cardWidth + 2 * L.margin - 20
    for center in [CGFloat(0), width / 2, width] {
      #expect(approx(L.cardMinX(circleCenterX: center, containerWidth: width), L.margin))
    }
  }

  @Test("card height is 75% clamped to 360...640, then capped below the tab bar, never negative")
  func cardHeightWithinBoundsAndBelowTabBar() {
    func cap(_ height: CGFloat) -> CGFloat {
      height - ComponentSize.tabBarHeight - L.circleDiameter - 2 * L.margin - L.gap
    }

    // Tall containers: 0.75 * height clamped to the bounds.
    #expect(approx(L.cardHeight(containerHeight: 600), 450))
    #expect(approx(L.cardHeight(containerHeight: 1000), L.maxCardHeight))
    #expect(approx(L.cardHeight(containerHeight: 2000), L.maxCardHeight))
    for height: CGFloat in [600, 700, 800, 1000, 1400] {
      let result = L.cardHeight(containerHeight: height)
      #expect(result >= L.minCardHeight && result <= L.maxCardHeight)
      #expect(result <= cap(height))
    }

    // Short container: min height would push the card under the tab bar, so the cap wins.
    #expect(approx(L.cardHeight(containerHeight: 400), cap(400)))
    #expect(L.cardHeight(containerHeight: 400) < L.minCardHeight)

    // Tiny container: the cap is negative, the result is 0.
    #expect(L.cardHeight(containerHeight: 100) == 0)
  }

  @Test("the scale anchor points at the circle center below the card")
  func scaleAnchorPointsAtCircle() {
    let width: CGFloat = 1200
    let center = L.circleCenterX(fraction: 1, containerWidth: width)
    let minX = L.cardMinX(circleCenterX: center, containerWidth: width)
    let height = L.cardHeight(containerHeight: 800)

    let anchor = L.scaleAnchor(circleCenterX: center, cardMinX: minX, cardHeight: height)

    #expect(approx(anchor.x, (center - minX) / L.cardWidth))
    #expect(approx(anchor.y, (height + L.gap + L.circleDiameter / 2) / height))
    #expect(anchor.y > 1)
  }
}
