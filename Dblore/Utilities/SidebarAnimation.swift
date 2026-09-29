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

/// Like `withAnimation`, but survives the app-wide `.transaction` that disables animations.
func withSidebarAnimation(_ body: () -> Void) {
  var transaction = Transaction(animation: .easeInOut(duration: 0.2))
  transaction.isSidebarAnimation = true
  withTransaction(transaction, body)
}
