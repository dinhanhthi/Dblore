//
//  ToastView.swift
//  SQLNotebook
//

import SwiftUI

/// Toast notification message
struct ToastMessage: Identifiable, Equatable {
  let id = UUID()
  let message: String
  let type: ToastType

  enum ToastType {
    case info
    case warning
    case error
    case success
  }
}

/// Toast notification view (bottom-right corner)
struct ToastView: View {
  let toast: ToastMessage

  var body: some View {
    HStack(spacing: Spacing.sm) {
      icon
        .font(.system(size: 14))
        .foregroundColor(iconColor)

      Text(toast.message)
        .font(.caption)
        .foregroundColor(.foreground)
        .lineLimit(2)
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.sm)
    .background(backgroundColor)
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
    .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 2)
  }

  @ViewBuilder
  private var icon: some View {
    switch toast.type {
    case .info:
      Image(systemName: "info.circle.fill")
    case .warning:
      Image(systemName: "exclamationmark.triangle.fill")
    case .error:
      Image(systemName: "xmark.circle.fill")
    case .success:
      Image(systemName: "checkmark.circle.fill")
    }
  }

  private var iconColor: Color {
    switch toast.type {
    case .info:
      return .accentColor
    case .warning:
      return .warning
    case .error:
      return .destructive
    case .success:
      return .success
    }
  }

  private var backgroundColor: Color {
    Color.cardBackground.opacity(0.95)
  }
}

#Preview {
  VStack(spacing: Spacing.lg) {
    ToastView(toast: ToastMessage(
      message: "Query limit enforced to 50 rows. Increase in Settings.",
      type: .warning
    ))

    ToastView(toast: ToastMessage(
      message: "Query executed successfully",
      type: .success
    ))

    ToastView(toast: ToastMessage(
      message: "Connection failed",
      type: .error
    ))

    ToastView(toast: ToastMessage(
      message: "New notebook created",
      type: .info
    ))
  }
  .padding()
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}
