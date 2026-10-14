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

  @Test("card width defaults to 320, clamps to 320...720 and fits a narrow container")
  func cardWidthClamps() {
    #expect(L.cardWidth(preferred: nil, containerWidth: 1200) == L.minCardWidth)
    #expect(L.cardWidth(preferred: 200, containerWidth: 1200) == L.minCardWidth)
    #expect(L.cardWidth(preferred: 500, containerWidth: 1200) == 500)
    #expect(L.cardWidth(preferred: 2000, containerWidth: 1200) == L.maxCardWidth)
    // Narrow container: the container cap wins over the minimum.
    #expect(approx(L.cardWidth(preferred: 600, containerWidth: 400), 400 - 2 * L.margin))
    #expect(approx(L.cardWidth(preferred: nil, containerWidth: 300), 300 - 2 * L.margin))
    #expect(L.cardWidth(preferred: 600, containerWidth: 10) == 0)
  }

  @Test("preferred card height clamps to min...available height, never negative")
  func preferredCardHeightClamps() {
    func cap(_ height: CGFloat) -> CGFloat {
      height - ComponentSize.tabBarHeight - L.circleDiameter - 2 * L.margin - L.gap
    }
    #expect(
      L.cardHeight(preferred: nil, containerHeight: 600) == L.cardHeight(containerHeight: 600))
    #expect(L.cardHeight(preferred: 500, containerHeight: 1000) == 500)
    #expect(L.cardHeight(preferred: 100, containerHeight: 1000) == L.minCardHeight)
    // Taller than the old 640 cap is allowed up to the available height.
    #expect(L.cardHeight(preferred: 800, containerHeight: 1000) == 800)
    #expect(approx(L.cardHeight(preferred: 5000, containerHeight: 1000), cap(1000)))
    #expect(L.cardHeight(preferred: 500, containerHeight: 100) == 0)
  }

  @Test("a wider card stays inside the margins and its scale anchor points at the circle")
  func wideCardPlacementAndAnchor() {
    let width: CGFloat = 600
    let containerWidth: CGFloat = 1000
    let rightCenter = L.circleCenterX(fraction: 1, containerWidth: containerWidth)
    let minX = L.cardMinX(
      circleCenterX: rightCenter, cardWidth: width, containerWidth: containerWidth)
    #expect(approx(minX, containerWidth - L.margin - width))
    let leftCenter = L.circleCenterX(fraction: 0, containerWidth: containerWidth)
    #expect(
      L.cardMinX(circleCenterX: leftCenter, cardWidth: width, containerWidth: containerWidth)
        == L.margin)
    let midMinX = L.cardMinX(circleCenterX: 500, cardWidth: width, containerWidth: containerWidth)
    #expect(approx(midMinX, 200))

    let anchor = L.scaleAnchor(
      circleCenterX: rightCenter, cardMinX: minX, cardWidth: width, cardHeight: 400)
    #expect(approx(anchor.x, (rightCenter - minX) / width))
    #expect(approx(anchor.y, (400 + L.gap + radius) / 400))
  }
}
