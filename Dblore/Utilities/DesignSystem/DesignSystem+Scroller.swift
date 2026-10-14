//
//  DesignSystem+Scroller.swift
//  Dblore
//
//  Soft scroll bars. The system knob reads too heavy on the Oxide surfaces, so every scroll
//  view swaps its scrollers for `SoftScroller`: the native knob drawn at a fixed, reduced
//  opacity. Shape, width and the overlay fade stay native.
//

import AppKit
import ObjectiveC

/// Native scroller whose knob is drawn at a fixed, lighter opacity.
final class SoftScroller: NSScroller {
  /// Knob opacity
  private static let knobAlpha: CGFloat = 0.4

  // Overriding drawKnob would otherwise force the legacy style
  override class var isCompatibleWithOverlayScrollers: Bool { self == SoftScroller.self }

  override func drawKnob() {
    guard let context = NSGraphicsContext.current?.cgContext else {
      super.drawKnob()
      return
    }
    context.saveGState()
    context.setAlpha(Self.knobAlpha)
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    super.drawKnob()
    context.endTransparencyLayer()
    context.restoreGState()
  }
}

extension NSScrollView {
  /// Route every scroll view's scrollers (SwiftUI ScrollView and List included) through
  /// `SoftScroller`. A scroll view creates its scroller the first time `hasVerticalScroller` /
  /// `hasHorizontalScroller` turns on, so the swap hooks those setters. Call once at launch.
  static func installSoftScrollers() {
    exchange(#selector(setter: hasVerticalScroller), #selector(softSetHasVerticalScroller))
    exchange(#selector(setter: hasHorizontalScroller), #selector(softSetHasHorizontalScroller))
  }

  private static func exchange(_ original: Selector, _ replacement: Selector) {
    guard let originalMethod = class_getInstanceMethod(NSScrollView.self, original),
      let replacementMethod = class_getInstanceMethod(NSScrollView.self, replacement)
    else { return }
    method_exchangeImplementations(originalMethod, replacementMethod)
  }

  // Each calls the original setter: the implementations are exchanged
  @objc private func softSetHasVerticalScroller(_ flag: Bool) {
    softSetHasVerticalScroller(flag)
    if let soft = Self.softened(verticalScroller) { verticalScroller = soft }
  }

  @objc private func softSetHasHorizontalScroller(_ flag: Bool) {
    softSetHasHorizontalScroller(flag)
    if let soft = Self.softened(horizontalScroller) { horizontalScroller = soft }
  }

  /// A `SoftScroller` matching a plain system scroller; nil for none or a custom subclass
  private static func softened(_ scroller: NSScroller?) -> SoftScroller? {
    guard let scroller, type(of: scroller) == NSScroller.self else { return nil }
    let soft = SoftScroller(frame: scroller.frame)
    soft.scrollerStyle = scroller.scrollerStyle
    soft.knobStyle = scroller.knobStyle
    soft.controlSize = scroller.controlSize
    return soft
  }
}
