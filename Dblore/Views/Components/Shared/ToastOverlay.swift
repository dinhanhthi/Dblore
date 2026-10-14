//
//  ToastOverlay.swift
//  Dblore
//

import SwiftUI

/// Toast notification overlay (bottom-right corner)
/// Uses WorkspaceWindowManager for app-wide toast management
struct ToastOverlay: View {
  @Bindable var windowManager = WorkspaceWindowManager.shared
  @ReduceMotion private var reduceMotion

  var body: some View {
    // Always present, so the toast's insertion and removal can animate
    ZStack {
      if let toast = windowManager.toastState.currentToast {
        VStack {
          Spacer()
          HStack {
            Spacer()
            ToastView(toast: toast, windowManager: windowManager)
              .padding(.horizontal, Spacing.lg)
              .padding(.vertical, Spacing.xxl)
              .transition(.move(edge: .trailing).combined(with: .opacity))
          }
        }
      }
    }
    .animation(
      reduceMotion ? nil : .snappy(duration: 0.2), value: windowManager.toastState.currentToast
    )
    // Opt out of the app-wide animation kill switch, only for the show/dismiss change
    .transaction(value: windowManager.toastState.currentToast) { $0.disablesAnimations = false }
  }
}
