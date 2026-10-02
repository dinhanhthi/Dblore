//
//  ToastView.swift
//  Dblore
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
/// Uses WorkspaceWindowManager for app-wide toast management
struct ToastView: View {
  let toast: ToastMessage
  @Bindable var windowManager: WorkspaceWindowManager

  @State private var isHovered = false

  var body: some View {
    HStack(spacing: Spacing.md) {
      icon
        .font(.system(size: 20, weight: .semibold))
        .foregroundColor(iconColor)

      Text(toast.message)
        .font(.body)
        .foregroundColor(.foreground)
        .lineLimit(2)

      Button {
        windowManager.dismissToast()
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .controlSize(.small)
      .help("Close")
      .accessibilityLabel("Close")
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.md)
    .background(
      RoundedRectangle(cornerRadius: CornerRadius.md)
        .fill(backgroundColor)
    )
    .overlay(
      RoundedRectangle(cornerRadius: CornerRadius.md)
        .strokeBorder(borderColor, lineWidth: 1)
    )
    .overlay(
      // Subtle inner glow
      RoundedRectangle(cornerRadius: CornerRadius.md)
        .strokeBorder(
          LinearGradient(
            colors: [borderColor.opacity(0.3), .clear],
            startPoint: .top,
            endPoint: .bottom
          ),
          lineWidth: 1
        )
        .padding(1)
    )
    .shadow(color: borderColor.opacity(0.2), radius: 8, x: 0, y: 0)  // Glow effect
    .shadow(color: Color.black.opacity(0.4), radius: 12, x: 0, y: 4)  // Deep shadow
    .shadow(color: Color.black.opacity(0.2), radius: 4, x: 0, y: 2)  // Close shadow
    .onHover { hovering in
      isHovered = hovering
      windowManager.setToastHovered(hovering)
    }
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
      return .accent
    case .warning:
      return .warning
    case .error:
      return .destructive
    case .success:
      return .success
    }
  }

  private var borderColor: Color {
    switch toast.type {
    case .info:
      return .accent
    case .warning:
      return .warning
    case .error:
      return .destructive
    case .success:
      return .success
    }
  }

  private var backgroundColor: Color {
    Color.cellBackground.opacity(0.95)
  }
}

#Preview {
  let windowManager = WorkspaceWindowManager.shared
  windowManager.showToast("Query limit enforced to 50 rows. Increase in Settings.", type: .warning)

  return VStack(spacing: Spacing.lg) {
    ToastView(
      toast: ToastMessage(
        message: "Query limit enforced to 50 rows. Increase in Settings.",
        type: .warning
      ),
      windowManager: windowManager
    )

    ToastView(
      toast: ToastMessage(
        message: "Query executed successfully",
        type: .success
      ),
      windowManager: windowManager
    )

    ToastView(
      toast: ToastMessage(
        message: "Connection failed",
        type: .error
      ),
      windowManager: windowManager
    )

    ToastView(
      toast: ToastMessage(
        message: "New notebook created",
        type: .info
      ),
      windowManager: windowManager
    )
  }
  .padding()
  .background(Color.appBackground)
  .preferredColorScheme(.dark)
}
