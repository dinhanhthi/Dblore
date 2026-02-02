//
//  ToastOverlay.swift
//  SQLNotebook
//

import SwiftUI

/// Toast notification overlay (bottom-right corner)
/// Uses WorkspaceWindowManager for app-wide toast management
struct ToastOverlay: View {
  @Bindable var windowManager = WorkspaceWindowManager.shared

  var body: some View {
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
}
