//
//  AIBubbleOverlay.swift
//  Dblore
//
//  Floating AI bubble: draggable icon circle and the chat card above it
//

import AppKit
import SwiftUI

/// Fills the workspace content area. Only the circle, its hover badge and the card take
/// clicks; empty space passes through to the views underneath.
struct AIBubbleOverlay: View {
  @Bindable var assistant: AIAssistantViewModel
  let activeTab: NotebookViewModel?
  let tables: [DatabaseTable]

  /// Live horizontal drag translation, committed to `AppSettings` on drag end
  @State private var dragOffset: CGFloat = 0
  /// Live card resize (points added to the saved width / height), committed on drag end
  @State private var widthDrag: CGFloat = 0
  @State private var heightDrag: CGFloat = 0
  @State private var isPressed = false
  @State private var isDragging = false
  @State private var isHovering = false
  @ReduceMotion private var reduceMotion

  /// Movement below this is a click, not a drag
  private static let dragThreshold: CGFloat = 4
  private static let radius = AIBubbleLayout.circleDiameter / 2

  var body: some View {
    GeometryReader { geometry in
      let size = geometry.size
      let centerX = circleCenterX(containerWidth: size.width)
      let centerY = size.height - AIBubbleLayout.margin - Self.radius
      let cardWidth = cardWidth(containerWidth: size.width)
      let cardHeight = cardHeight(containerHeight: size.height)
      let cardMinX = AIBubbleLayout.cardMinX(
        circleCenterX: centerX, cardWidth: cardWidth, containerWidth: size.width)
      let cardTop = centerY - Self.radius - AIBubbleLayout.gap - cardHeight

      ZStack(alignment: .topLeading) {
        // Always-present slot sized as the card, so the transition scales in card space
        ZStack {
          if assistant.isBubbleExpanded {
            card(width: cardWidth, height: cardHeight, containerSize: size)
              .transition(
                .scale(
                  scale: 0.9,
                  anchor: AIBubbleLayout.scaleAnchor(
                    circleCenterX: centerX, cardMinX: cardMinX, cardWidth: cardWidth,
                    cardHeight: cardHeight)
                )
                .combined(with: .opacity))
          }
        }
        .frame(width: cardWidth, height: cardHeight)
        .offset(x: cardMinX, y: cardTop)

        circle(containerWidth: size.width)
          .offset(x: centerX - Self.radius, y: centerY - Self.radius)
      }
    }
    // A card closed mid-resize (Escape) never ends its drag: drop the live resize
    .onChange(of: assistant.isBubbleExpanded) {
      widthDrag = 0
      heightDrag = 0
    }
  }

  /// Saved position plus the live drag, clamped into the valid center range
  private func circleCenterX(containerWidth: CGFloat) -> CGFloat {
    let saved = AIBubbleLayout.circleCenterX(
      fraction: AppSettings.shared.aiBubblePosition, containerWidth: containerWidth)
    return AIBubbleLayout.circleCenterX(
      fraction: AIBubbleLayout.fraction(
        forCenterX: saved + dragOffset, containerWidth: containerWidth),
      containerWidth: containerWidth)
  }

  /// Saved card width plus the live resize, clamped to the container
  private func cardWidth(containerWidth: CGFloat) -> CGFloat {
    let saved = AIBubbleLayout.cardWidth(
      preferred: AppSettings.shared.aiBubbleCardWidth.map { CGFloat($0) },
      containerWidth: containerWidth)
    guard widthDrag != 0 else { return saved }
    return AIBubbleLayout.cardWidth(preferred: saved + widthDrag, containerWidth: containerWidth)
  }

  /// Saved card height plus the live resize, clamped to the container
  private func cardHeight(containerHeight: CGFloat) -> CGFloat {
    let saved = AIBubbleLayout.cardHeight(
      preferred: AppSettings.shared.aiBubbleCardHeight.map { CGFloat($0) },
      containerHeight: containerHeight)
    guard heightDrag != 0 else { return saved }
    return AIBubbleLayout.cardHeight(
      preferred: saved + heightDrag, containerHeight: containerHeight)
  }

  // MARK: - Card

  private func card(width: CGFloat, height: CGFloat, containerSize: CGSize) -> some View {
    AIAssistantPanel(
      assistant: assistant, activeTab: activeTab, tables: tables, isFloating: true, width: width
    )
    .frame(height: height)
    .background(Color.cardBackground)
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.xxl))
    .overlay(
      HairlineBorder(
        shape: RoundedRectangle(cornerRadius: CornerRadius.xxl), color: .border.opacity(0.5))
    )
    .shadow(color: .black.opacity(0.25), radius: 24, x: 0, y: 8)
    .background {
      ModalEscapeCatcher {
        withSidebarAnimation(SidebarAnimation.bubble) { assistant.collapseBubble() }
      }
    }
    .overlay(alignment: .leading) {
      resizeHandle(.leading, containerSize: containerSize).offset(x: -4)
    }
    .overlay(alignment: .trailing) {
      resizeHandle(.trailing, containerSize: containerSize).offset(x: 4)
    }
    .overlay(alignment: .top) {
      resizeHandle(.top, containerSize: containerSize).offset(y: -4)
    }
  }

  // MARK: - Card Resize

  /// Invisible 8pt edge strip. The card stays centered on the circle, so a side edge drag of
  /// d changes the width by 2d (the dragged edge follows the pointer unless the card is pinned
  /// to a margin). The top edge drag changes the height; the bottom stays above the circle.
  /// Double-click resets that dimension to its default.
  private func resizeHandle(_ edge: Edge, containerSize: CGSize) -> some View {
    let isTop = edge == .top
    return Color.clear
      .frame(width: isTop ? nil : 8, height: isTop ? 8 : nil)
      .contentShape(Rectangle())
      .onHover { hovering in
        if hovering {
          (isTop ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).push()
        } else {
          NSCursor.pop()
        }
      }
      .onTapGesture(count: 2) {
        withTransaction(Transaction(animation: nil)) {
          if isTop {
            AppSettings.shared.aiBubbleCardHeight = nil
          } else {
            AppSettings.shared.aiBubbleCardWidth = nil
          }
        }
      }
      .gesture(resizeGesture(edge, containerSize: containerSize))
  }

  private func resizeGesture(_ edge: Edge, containerSize: CGSize) -> some Gesture {
    // Global space: the handle moves with the card while it resizes
    DragGesture(minimumDistance: 1, coordinateSpace: .global)
      .onChanged { value in
        withTransaction(Transaction(animation: nil)) {
          switch edge {
          case .top: heightDrag = -value.translation.height
          case .leading: widthDrag = -2 * value.translation.width
          default: widthDrag = 2 * value.translation.width
          }
        }
      }
      .onEnded { _ in
        withTransaction(Transaction(animation: nil)) {
          if edge == .top {
            AppSettings.shared.aiBubbleCardHeight = Double(
              cardHeight(containerHeight: containerSize.height))
            heightDrag = 0
          } else {
            AppSettings.shared.aiBubbleCardWidth = Double(
              cardWidth(containerWidth: containerSize.width))
            widthDrag = 0
          }
        }
      }
  }

  // MARK: - Circle

  private func circle(containerWidth: CGFloat) -> some View {
    circleBase
      .gesture(dragGesture(containerWidth: containerWidth))
      .accessibilityElement()
      .accessibilityLabel("AI Assistant")
      .accessibilityAddTraits(.isButton)
      .accessibilityAction { toggleExpanded() }
      // After the gesture so the badge hit-tests first
      .overlay(alignment: .topTrailing) { hideBadge }
      .onHover { isHovering = $0 }
  }

  private var circleBase: some View {
    Image("AIBubbleIcon")
      .resizable()
      .interpolation(.high)
      .scaleEffect(assistant.isBubbleExpanded ? 0.9 : 1)
      .frame(width: AIBubbleLayout.circleDiameter, height: AIBubbleLayout.circleDiameter)
      .background {
        ZStack {
          Color.aiBubbleBackground
          // Expanded: bright accent gradient on white, light enough to keep the logo readable
          LinearGradient(
            colors: [Color.white, Color.accent.opacity(0.35)],
            startPoint: .topLeading, endPoint: .bottomTrailing
          )
          .background(Color.white)
          .opacity(assistant.isBubbleExpanded ? 1 : 0)
        }
      }
      .clipShape(Circle())
      .overlay(
        Circle()
          .strokeBorder(Color.accent.opacity(0.4), lineWidth: 1)
          .opacity(assistant.isBubbleExpanded ? 1 : 0)
      )
      .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 2)
      .contentShape(Circle())
      .scaleEffect(isPressed && !reduceMotion ? 0.92 : 1)
      .animation(
        reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.6), value: isPressed
      )
      // Opt out of the app-wide animation kill switch so the press spring animates
      .transaction { $0.disablesAnimations = false }
  }

  private var hideBadge: some View {
    let visible = isHovering && !isDragging
    return Button {
      withSidebarAnimation(SidebarAnimation.bubble) { assistant.hide() }
    } label: {
      Image(systemName: "xmark")
        .font(.system(size: 8, weight: .bold))
        .foregroundColor(.foregroundMuted)
        .frame(width: 16, height: 16)
        .background(Circle().fill(Color.cardBackground))
        .overlay(HairlineBorder(shape: Circle()))
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .help("Hide AI bubble")
    .accessibilityLabel("Hide AI bubble")
    .opacity(visible ? 1 : 0)
    .allowsHitTesting(visible)
    .animation(.easeOut(duration: 0.15), value: isHovering)
    // Opt out of the app-wide animation kill switch so the badge fade animates
    .transaction { $0.disablesAnimations = false }
  }

  // MARK: - Gesture

  private func dragGesture(containerWidth: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .global)
      .onChanged { value in
        isPressed = true
        let distance = hypot(value.translation.width, value.translation.height)
        guard isDragging || distance >= Self.dragThreshold else { return }
        withTransaction(Transaction(animation: nil)) {
          isDragging = true
          dragOffset = value.translation.width
        }
      }
      .onEnded { _ in
        isPressed = false
        guard isDragging else {
          toggleExpanded()
          return
        }
        withTransaction(Transaction(animation: nil)) {
          AppSettings.shared.aiBubblePosition = AIBubbleLayout.fraction(
            forCenterX: circleCenterX(containerWidth: containerWidth),
            containerWidth: containerWidth)
          dragOffset = 0
          isDragging = false
        }
      }
  }

  private func toggleExpanded() {
    withSidebarAnimation(SidebarAnimation.bubble) { assistant.toggleBubbleExpanded() }
  }
}

#Preview("AIBubbleOverlay") {
  let assistant = AIAssistantViewModel()
  assistant.toggleVisibility(defaultMode: .bubble)
  return AIBubbleOverlay(
    assistant: assistant, activeTab: nil,
    tables: [DatabaseTable(schema: "public", name: "customers")]
  )
  .frame(width: 900, height: 700)
}
