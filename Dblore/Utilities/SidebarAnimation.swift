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
  /// Snappier curve for the AI bubble expanding, collapsing, and switching to or from the sidebar.
  static let bubble = Animation.snappy(duration: 0.2)
}

/// Like `withAnimation`, but survives the app-wide `.transaction` that disables animations.
func withSidebarAnimation(
  _ animation: Animation = SidebarAnimation.animation, _ body: () -> Void
) {
  var transaction = Transaction(animation: animation)
  transaction.isSidebarAnimation = true
  withTransaction(transaction, body)
}
