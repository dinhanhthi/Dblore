//
//  CustomTooltip.swift
//  SQLNotebook
//

import SwiftUI

// MARK: - Custom Tooltip Modifier

/// A custom tooltip that appears faster than macOS default tooltip
/// Usage: .customTooltip("Your tooltip text")
struct CustomTooltipModifier: ViewModifier {
  let text: String
  let position: TooltipPosition
  let delay: TimeInterval

  @State private var isHovering = false
  @State private var showTooltip = false
  @State private var mouseLocation: CGPoint = .zero

  func body(content: Content) -> some View {
    content
      .background(
        GeometryReader { geometry in
          Color.clear.preference(
            key: TooltipPreferenceKey.self,
            value: geometry.frame(in: .global)
          )
        }
      )
      .onPreferenceChange(TooltipPreferenceKey.self) { _ in
        // Track frame changes
      }
      .onHover { hovering in
        isHovering = hovering
        if hovering {
          // Show tooltip after short delay
          DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if isHovering {
              showTooltip = true
            }
          }
        } else {
          // Hide immediately when mouse leaves
          showTooltip = false
        }
      }
      .overlay(alignment: position.alignment) {
        if showTooltip {
          TooltipView(text: text)
            .offset(y: position.offset)
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
            .animation(.easeOut(duration: 0.15), value: showTooltip)
        }
      }
  }
}

// MARK: - Tooltip View

private struct TooltipView: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.caption)
      .foregroundColor(.white)
      .lineLimit(nil)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: true, vertical: false)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xs)
      .background(
        RoundedRectangle(cornerRadius: CornerRadius.sm)
          .fill(Color.black.opacity(0.85))
      )
      .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
  }
}

// MARK: - Tooltip Position

enum TooltipPosition {
  case top
  case bottom
  case leading
  case trailing

  var alignment: Alignment {
    switch self {
    case .top: return .top
    case .bottom: return .bottom
    case .leading: return .leading
    case .trailing: return .trailing
    }
  }

  var offset: CGFloat {
    switch self {
    case .top: return -32
    case .bottom: return 32
    case .leading, .trailing: return 0
    }
  }
}

// MARK: - Preference Key

private struct TooltipPreferenceKey: PreferenceKey {
  static var defaultValue: CGRect = .zero

  static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
    value = nextValue()
  }
}

// MARK: - View Extension

extension View {
  /// Adds a custom tooltip that appears faster than the default macOS tooltip
  /// - Parameters:
  ///   - text: The tooltip text to display
  ///   - position: Position of the tooltip relative to the view (default: .bottom)
  ///   - delay: Delay before showing tooltip in seconds (default: 0.3)
  func customTooltip(
    _ text: String,
    position: TooltipPosition = .bottom,
    delay: TimeInterval = 0.3
  ) -> some View {
    self.modifier(CustomTooltipModifier(text: text, position: position, delay: delay))
  }
}
