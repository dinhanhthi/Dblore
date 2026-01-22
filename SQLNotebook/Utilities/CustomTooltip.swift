//
//  CustomTooltip.swift
//  SQLNotebook
//
//  Smart tooltip implementation with automatic positioning and native macOS blur effect.
//  Automatically positions tooltip above or below based on screen position.
//

import SwiftUI

// MARK: - Public API

extension View {
  /// Add smart custom tooltip that appears on hover with automatic positioning
  ///
  /// Tooltip automatically positions itself above or below the view based on
  /// available screen space to avoid going off-screen or hiding the element.
  ///
  /// Usage:
  /// ```swift
  /// Button("Save") { ... }
  ///   .customTooltip("Save file to disk")
  /// ```
  ///
  /// - Parameter text: Tooltip text to display
  /// - Returns: View with smart tooltip modifier
  func customTooltip(_ text: String) -> some View {
    self.modifier(SmartTooltipModifier(text: text))
  }
}

// MARK: - Smart Tooltip Modifier

/// A view modifier that adds a smart tooltip with automatic positioning.
///
/// The tooltip automatically positions itself above or below the view based on
/// the view's position on screen to prevent going off-screen or hiding the element.
/// Uses native macOS visual effects for consistent appearance across light/dark modes.
///
/// Positioning logic:
/// - Views near top of screen (< 200pt from top) → tooltip appears below
/// - Views elsewhere on screen → tooltip appears above
///
/// - SeeAlso: `customTooltip(_:)` for usage examples
private struct SmartTooltipModifier: ViewModifier {
  @State private var isHovering = false
  @State private var viewFrame: CGRect = .zero
  let text: String

  func body(content: Content) -> some View {
    content
      .background(
        GeometryReader { geometry in
          Color.clear
            .preference(key: ViewFrameKey.self, value: geometry.frame(in: .global))
        }
      )
      .onPreferenceChange(ViewFrameKey.self) { frame in
        viewFrame = frame
      }
      .onHover { hovering in
        withAnimation(.easeInOut(duration: 0.1)) {
          isHovering = hovering
        }
      }
      .overlay(
        Group {
          if isHovering {
            tooltipView
              .offset(y: tooltipOffset)
              .transition(.opacity)
          }
        },
        alignment: tooltipAlignment
      )
  }

  /// Tooltip content with native macOS blur effect
  private var tooltipView: some View {
    Text(text)
      .font(.caption)
      .foregroundColor(.primary)
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(
        VisualEffectView(material: .popover, blendingMode: .withinWindow)
          .clipShape(RoundedRectangle(cornerRadius: 6))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 6)
          .stroke(Color.primary.opacity(0.1), lineWidth: 1)
      )
      .shadow(color: Color.black.opacity(0.1), radius: 4, y: 2)
      .fixedSize()  // Prevent text wrapping
  }

  /// Calculate tooltip alignment based on view's position on screen.
  ///
  /// Returns `.bottom` for views near the top of the screen (< 200pt from top edge),
  /// and `.top` for all other views to avoid hiding the element.
  ///
  /// - Returns: `.bottom` if view is near top, `.top` otherwise
  private var tooltipAlignment: Alignment {
    guard NSScreen.main != nil else { return .top }

    let viewMinY = viewFrame.minY

    // If view is in top half of screen (less than 200pt from top), show below
    // Otherwise show above to avoid hiding the button
    if viewMinY < 200 {
      return .bottom
    } else {
      return .top
    }
  }

  /// Calculate tooltip vertical offset based on view's position on screen.
  ///
  /// Returns positive offset (35pt) for views near top to show tooltip below,
  /// and negative offset (-35pt) for other views to show tooltip above.
  ///
  /// - Returns: `+35` if view is near top, `-35` otherwise
  private var tooltipOffset: CGFloat {
    guard NSScreen.main != nil else { return -35 }

    let viewMinY = viewFrame.minY

    // If view is in top half of screen, show below (positive offset)
    // Otherwise show above (negative offset)
    if viewMinY < 200 {
      return 35
    } else {
      return -35
    }
  }
}

// MARK: - Visual Effect View (Native macOS Blur)

/// A SwiftUI wrapper for `NSVisualEffectView` to create native macOS blur effects.
///
/// Provides a translucent background with vibrancy effect that automatically
/// adapts to light and dark modes. Commonly used for popovers, tooltips, and
/// overlay UI elements.
///
/// Example:
/// ```swift
/// VisualEffectView(material: .popover, blendingMode: .withinWindow)
///     .clipShape(RoundedRectangle(cornerRadius: 6))
/// ```
///
/// - Note: The blur effect is hardware-accelerated and performs well even
///   with frequent updates or animations.
///
/// - SeeAlso: [NSVisualEffectView - Apple Developer](https://developer.apple.com/documentation/appkit/nsvisualeffectview)
struct VisualEffectView: NSViewRepresentable {
  /// The material appearance of the visual effect view (e.g., `.popover`, `.menu`)
  let material: NSVisualEffectView.Material

  /// The blending mode for compositing with underlying content
  let blendingMode: NSVisualEffectView.BlendingMode

  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = material
    view.blendingMode = blendingMode
    view.state = .active
    return view
  }

  func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Preference Key

private struct ViewFrameKey: PreferenceKey {
  static var defaultValue: CGRect = .zero
  static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
    value = nextValue()
  }
}

// MARK: - Preview

#if DEBUG
  struct CustomTooltip_Previews: PreviewProvider {
    static var previews: some View {
      VStack(spacing: 40) {
        // Example at top of screen (should show below)
        Button("Top Button") {}
          .buttonStyle(.bordered)
          .customTooltip("This tooltip appears below because button is at top")
          .position(x: 250, y: 50)

        // Example in middle/bottom of screen (should show above)
        Button("Bottom Button") {}
          .buttonStyle(.bordered)
          .customTooltip("This tooltip appears above to avoid hiding the button")
          .position(x: 250, y: 400)

        // Example with long text
        Button("Long Text") {}
          .buttonStyle(.bordered)
          .customTooltip(
            "This is a longer tooltip text that demonstrates auto-sizing with fixedSize modifier"
          )
          .position(x: 250, y: 300)
      }
      .frame(width: 500, height: 500)
      .background(Color.gray.opacity(0.1))
    }
  }
#endif
