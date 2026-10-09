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
  @State private var isPressed = false
  @State private var isDragging = false
  @State private var isHovering = false

  /// Movement below this is a click, not a drag
  private static let dragThreshold: CGFloat = 4
  private static let radius = AIBubbleLayout.circleDiameter / 2

  var body: some View {
    GeometryReader { geometry in
      let size = geometry.size
      let centerX = circleCenterX(containerWidth: size.width)
      let centerY = size.height - AIBubbleLayout.margin - Self.radius
      let cardHeight = AIBubbleLayout.cardHeight(containerHeight: size.height)
      let cardMinX = AIBubbleLayout.cardMinX(circleCenterX: centerX, containerWidth: size.width)
      let cardTop = centerY - Self.radius - AIBubbleLayout.gap - cardHeight

      ZStack(alignment: .topLeading) {
        // Always-present slot sized as the card, so the transition scales in card space
        ZStack {
          if assistant.isBubbleExpanded {
            card(height: cardHeight)
              .transition(
                .scale(
                  scale: 0.1,
                  anchor: AIBubbleLayout.scaleAnchor(
                    circleCenterX: centerX, cardMinX: cardMinX, cardHeight: cardHeight)
                )
                .combined(with: .opacity))
          }
        }
        .frame(width: AIBubbleLayout.cardWidth, height: cardHeight)
        .offset(x: cardMinX, y: cardTop)

        circle(containerWidth: size.width)
          .offset(x: centerX - Self.radius, y: centerY - Self.radius)
      }
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

  // MARK: - Card

  private func card(height: CGFloat) -> some View {
    AIAssistantPanel(assistant: assistant, activeTab: activeTab, tables: tables, isFloating: true)
      .frame(height: height)
      .background(Color.cardBackground)
      .clipShape(RoundedRectangle(cornerRadius: CornerRadius.xxl))
      .overlay(
        RoundedRectangle(cornerRadius: CornerRadius.xxl)
          .stroke(Color.border.opacity(0.5), lineWidth: 1)
      )
      .shadow(color: .black.opacity(0.25), radius: 24, x: 0, y: 8)
      .background {
        ModalEscapeCatcher {
          withSidebarAnimation(SidebarAnimation.bubble) { assistant.collapseBubble() }
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
      .background(Color.aiBubbleBackground)
      .clipShape(Circle())
      .overlay(
        Circle()
          .stroke(Color.accent, lineWidth: 2)
          .opacity(assistant.isBubbleExpanded ? 1 : 0)
      )
      .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 2)
      .contentShape(Circle())
      .scaleEffect(isPressed ? 0.92 : 1)
      .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isPressed)
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
        .overlay(Circle().stroke(Color.border, lineWidth: 1))
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
