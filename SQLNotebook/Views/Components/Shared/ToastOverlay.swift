//
//  ToastOverlay.swift
//  SQLNotebook
//

import SwiftUI

/// Toast notification overlay (bottom-right corner)
/// Shared between Notebook and Editor modes
struct ToastOverlay: View {
  let viewModel: NotebookViewModel

  var body: some View {
    if let toast = viewModel.currentToast {
      VStack {
        Spacer()
        HStack {
          Spacer()
          ToastView(toast: toast, viewModel: viewModel)
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.xxl)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
      }
    }
  }
}
