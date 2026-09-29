//
//  DesignSystem+Pointer.swift
//  Dblore
//
//  Pointing-hand cursor for clickable controls. Views call `linkPointer()`
//  instead of raw `pointerStyle(.link)`, which needs macOS 15; below that it
//  falls back to pushing and popping `NSCursor.pointingHand` on hover.
//

import AppKit
import SwiftUI

// MARK: - Pointer Modifiers

extension View {
  /// Show the pointing-hand cursor while hovering this view.
  @ViewBuilder
  func linkPointer() -> some View {
    if #available(macOS 15, *) {
      pointerStyle(.link)
    } else {
      modifier(LinkPointerFallback())
    }
  }
}

/// macOS 14: push once on enter, pop once on exit, and pop if the view goes away while
/// hovered (SwiftUI sends no hover exit then), so the cursor stack stays balanced.
private struct LinkPointerFallback: ViewModifier {
  @State private var pushed = false

  func body(content: Content) -> some View {
    content
      .onHover { inside in
        if inside, !pushed {
          NSCursor.pointingHand.push()
          pushed = true
        } else if !inside, pushed {
          NSCursor.pop()
          pushed = false
        }
      }
      .onDisappear {
        if pushed {
          NSCursor.pop()
          pushed = false
        }
      }
  }
}
