//
//  DesignSystem+Pointer.swift
//  Dblore
//
//  Pointing-hand cursor for clickable controls. Views call `linkPointer()`
//  instead of raw `pointerStyle(.link)`, which needs macOS 15 and on macOS 27
//  leaves the arrow; it pushes and pops `NSCursor.pointingHand` on hover.
//

import AppKit
import SwiftUI

// MARK: - Pointer Modifiers

extension View {
  /// Show the pointing-hand cursor while hovering this view.
  func linkPointer() -> some View {
    modifier(LinkPointer())
  }
}

/// Push once on enter, pop once on exit, and pop if the view goes away while hovered
/// (SwiftUI sends no hover exit then), so the cursor stack stays balanced. Every move inside
/// sets the hand again: entering from another view or a modal, AppKit can put the arrow back
/// right after the push.
private struct LinkPointer: ViewModifier {
  @State private var pushed = false

  func body(content: Content) -> some View {
    content
      .onContinuousHover { phase in
        switch phase {
        case .active:
          if pushed {
            NSCursor.pointingHand.set()
          } else {
            NSCursor.pointingHand.push()
            pushed = true
          }
        case .ended:
          if pushed {
            NSCursor.pop()
            pushed = false
          }
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
