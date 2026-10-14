//
//  SidebarAnimation.swift
//  Dblore
//

import SwiftUI

/// Marks a transaction as a sidebar show/hide so the app-wide animation kill switch lets it through.
private struct SidebarAnimationKey: TransactionKey {
  static let defaultValue = false
}

extension Transaction {
  var isSidebarAnimation: Bool {
    get { self[SidebarAnimationKey.self] }
    set { self[SidebarAnimationKey.self] = newValue }
  }
}

enum SidebarAnimation {
  /// Shared by every sidebar show/hide so opening and closing use the same curve.
  static let animation = Animation.easeInOut(duration: 0.2)
  /// Slides in from the trailing edge and back out to that edge.
  static let trailingSlide = AnyTransition.move(edge: .trailing)
  /// Slide of a right side panel `width` wide: a marked ease in and out (cubic), longer the
  /// farther it travels (440pt forms 0.26s, Settings 640pt 0.31s, Import Data 760pt 0.34s,
  /// structure editor 960pt 0.39s)
  static func panel(width: CGFloat) -> Animation {
    .timingCurve(0.65, 0, 0.35, 1, duration: 0.15 + width / 4000)
  }
  /// Snappier curve for the AI bubble expanding, collapsing, and switching to or from the sidebar.
  static let bubble = Animation.snappy(duration: 0.2)

  /// Settings › Appearance › Animations; System follows System Settings › Accessibility ›
  /// Display › Reduce motion. Motion is dropped (nil animation) when true (design rule 10).
  @MainActor static var reduceMotion: Bool {
    AppSettings.shared.animationPreference.reducesMotion(
      system: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
  }
}

/// View-side `SidebarAnimation.reduceMotion`: the Animations setting, with System following
/// the `accessibilityReduceMotion` environment so views update when macOS changes it.
@MainActor
@propertyWrapper
struct ReduceMotion: DynamicProperty {
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

  var wrappedValue: Bool {
    AppSettings.shared.animationPreference.reducesMotion(system: systemReduceMotion)
  }
}

/// Like `withAnimation`, but survives the app-wide `.transaction` that disables animations.
/// Instant when Reduce motion is on.
@MainActor
func withSidebarAnimation(
  _ animation: Animation = SidebarAnimation.animation, _ body: () -> Void
) {
  var transaction = Transaction(animation: SidebarAnimation.reduceMotion ? nil : animation)
  transaction.isSidebarAnimation = true
  withTransaction(transaction, body)
}
