//
//  GenericModal.swift
//  Dblore
//
//  Generic modal component with consistent styling and animations
//  Provides header, content area, and optional footer with zoom animation
//

import SwiftUI

// MARK: - Generic Modal

/// A reusable modal component with consistent styling
/// Provides header with close button, content area, and optional footer
struct GenericModal<Content: View, Footer: View>: View {
  let title: String
  var titleIcon: String?
  var titleIconColor: Color = .foreground
  /// Tag shown right after the title (e.g. the database engine)
  var titleBadge: String? = nil
  let width: CGFloat
  let height: CGFloat
  @Binding var isPresented: Bool
  @ViewBuilder var content: () -> Content
  @ViewBuilder var footer: () -> Footer

  var body: some View {
    VStack(spacing: 0) {
      // Header
      GenericModalHeader(
        title: title,
        titleIcon: titleIcon,
        titleIconColor: titleIconColor,
        titleBadge: titleBadge,
        onClose: { isPresented = false }
      )

      // Content
      content()
      // Cannot put padding here because it will push the scrollbar to the left and there is a gap between the scrollbar and the edge of the window

      // Footer (if provided)
      footer()
    }
    .modalFrame(width: width, height: height)
    .background(Color.cardBackground)
    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.xxl))
    .overlay(
      RoundedRectangle(cornerRadius: CornerRadius.xxl)
        .stroke(Color.border.opacity(0.5), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.25), radius: 24, x: 0, y: 8)
    .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)
  }
}

// MARK: - Modal without Footer

extension GenericModal where Footer == EmptyView {
  init(
    title: String,
    titleIcon: String? = nil,
    titleIconColor: Color = .foreground,
    width: CGFloat,
    height: CGFloat,
    isPresented: Binding<Bool>,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.title = title
    self.titleIcon = titleIcon
    self.titleIconColor = titleIconColor
    self.width = width
    self.height = height
    self._isPresented = isPresented
    self.content = content
    self.footer = { EmptyView() }
  }
}

// MARK: - Modal Header

struct GenericModalHeader<Trailing: View>: View {
  let title: String
  var titleIcon: String?
  var titleIconColor: Color = .foreground
  var titleBadge: String? = nil
  /// Taller for side panels whose header holds a picker
  var verticalPadding: CGFloat = Spacing.sm
  let onClose: () -> Void
  @ViewBuilder var trailing: () -> Trailing

  var body: some View {
    HStack(spacing: Spacing.sm) {
      HStack(spacing: Spacing.xs) {
        if let icon = titleIcon {
          Image(systemName: icon)
            .foregroundColor(titleIconColor)
        }

        Text(title)
          .font(.subheading)
          .foregroundColor(.foreground)

        if let titleBadge {
          Text(titleBadge)
            .font(.small)
            .foregroundColor(.foregroundMuted)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xxs)
            .background(Color.controlBackground, in: Capsule())
            .overlay(HairlineBorder(shape: Capsule()))
            .padding(.leading, Spacing.xs)
        }
      }

      Spacer(minLength: Spacing.sm)

      trailing()

      Button(action: onClose) {
        Image(systemName: "xmark")
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .help("Close (Esc)")
    }
    .modalBarPadding(vertical: verticalPadding)
    .background(Color.cardHeaderBackground)
    .overlay(alignment: .bottom) {
      Divider()
    }
  }
}

extension GenericModalHeader where Trailing == EmptyView {
  init(
    title: String,
    titleIcon: String? = nil,
    titleIconColor: Color = .foreground,
    titleBadge: String? = nil,
    onClose: @escaping () -> Void
  ) {
    self.title = title
    self.titleIcon = titleIcon
    self.titleIconColor = titleIconColor
    self.titleBadge = titleBadge
    self.onClose = onClose
    self.trailing = { EmptyView() }
  }
}

/// Label of a dropdown in a modal header (engine, import source): a white capsule in light.
struct HeaderDropdownLabel: View {
  let title: String

  var body: some View {
    HStack(spacing: Spacing.sm) {
      Text(title)
        .foregroundColor(.foreground)
      Image(systemName: "chevron.up.chevron.down")
        .font(.caption)
        .foregroundColor(.foregroundMuted)
    }
    .dropdownCapsuleStyle()
  }
}

// MARK: - Modal Footer

struct GenericModalFooter<Content: View>: View {
  @ViewBuilder var content: () -> Content

  var body: some View {
    VStack(spacing: 0) {
      Divider()

      HStack {
        content()
      }
      .modalBarPadding()
    }
    .background(Color.modalFooterBackground)
  }
}

extension View {
  /// Modal size that shrinks with a smaller window instead of overflowing it. The content
  /// must scroll or stretch (`modalOverlay` keeps a margin around it).
  func modalFrame(width: CGFloat, height: CGFloat) -> some View {
    frame(maxWidth: .infinity, maxHeight: .infinity)
      .frame(maxWidth: width, maxHeight: height)
  }

  /// Horizontal inset stays at the body margin. Title bars and action bars share
  /// the same vertical room.
  func modalBarPadding(vertical: CGFloat = Spacing.sm) -> some View {
    padding(.horizontal, Spacing.md)
      .padding(.vertical, vertical)
  }
}

// MARK: - View Extension for Modal Overlay

extension View {
  /// Wraps any modal content with dimmed/blurred background and zoom animation
  /// Use this to add consistent modal presentation to any custom modal view
  /// - Parameter animated: false for keyboard-toggled overlays (the command palette) that must
  ///   appear and disappear instantly
  func modalOverlay<ModalContent: View>(
    isPresented: Binding<Bool>,
    animated: Bool = true,
    @ViewBuilder modal: @escaping () -> ModalContent
  ) -> some View {
    self.overlay {
      ZStack {
        // Dimmed and blurred background
        if isPresented.wrappedValue {
          ModalBackdrop()
            .ignoresSafeArea()
            .transition(.opacity)
            .onTapGesture {
              dismissPresentedModal(isPresented)
            }
        }

        // Modal content with zoom animation
        if isPresented.wrappedValue {
          modal()
            .padding(Spacing.lg)
            .background {
              ModalEscapeCatcher {
                dismissPresentedModal(isPresented)
              }
            }
            .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
      }
      .allowsHitTesting(isPresented.wrappedValue)
      .animation(
        animated && !SidebarAnimation.reduceMotion ? .snappy(duration: 0.2) : nil,
        value: isPresented.wrappedValue
      )
      // Opt out of the app-wide animation kill switch, only for the show/hide change
      .transaction(value: isPresented.wrappedValue) {
        if animated { $0.disablesAnimations = false }
      }
    }
  }
}

// MARK: - Side Panel Overlay

extension View {
  /// Right sidebar for forms: full height on the trailing edge, slides in from the right over
  /// the dimmed backdrop and back out on close. Esc and a backdrop click close it.
  /// - Parameter maxWidthFraction: caps `width` at this share of the window, so a wide panel
  ///   never reaches the traffic lights
  func sidePanelOverlay<PanelContent: View>(
    isPresented: Binding<Bool>,
    width: CGFloat,
    maxWidthFraction: CGFloat? = nil,
    @ViewBuilder panel: () -> PanelContent
  ) -> some View {
    // Built here, in the caller's body, so state the content reads updates it
    overlay {
      SidePanelHost(
        isPresented: isPresented, width: width, maxWidthFraction: maxWidthFraction,
        panel: panel())
    }
  }
}

private struct SidePanelHost<PanelContent: View>: View {
  @Binding var isPresented: Bool
  let width: CGFloat
  let maxWidthFraction: CGFloat?
  let panel: PanelContent

  @Environment(\.pixelLength) private var pixelLength
  @ReduceMotion private var reduceMotion

  private func panelWidth(in containerWidth: CGFloat) -> CGFloat {
    guard let maxWidthFraction else { return width }
    return min(width, containerWidth * maxWidthFraction)
  }

  // The cap is read in the same layout pass (the host stays mounted, so the panel slides in at
  // its final width). Measuring the width into state instead crashed a live resize with the
  // panel open: each state write asked the window for another constraints pass.
  var body: some View {
    GeometryReader { proxy in
      panelStack(panelWidth: panelWidth(in: proxy.size.width))
    }
    .allowsHitTesting(isPresented)
    .animation(reduceMotion ? nil : SidebarAnimation.panel(width: width), value: isPresented)
    // Opt out of the app-wide animation kill switch, only for the show/hide change
    .transaction(value: isPresented) { $0.disablesAnimations = false }
  }

  private func panelStack(panelWidth: CGFloat) -> some View {
    ZStack(alignment: .trailing) {
      if isPresented {
        ModalBackdrop()
          .ignoresSafeArea()
          .transition(.opacity)
          .onTapGesture {
            dismissPresentedModal($isPresented)
          }
      }

      if isPresented {
        panel
          .frame(width: panelWidth)
          .frame(maxHeight: .infinity)
          // Panels fill with `.background(Color)`, which bleeds into the safe area by default and
          // drew the panel over the native tab bar; keep it inside its frame
          .clipped()
          // Only a leaf rectangle behind the panel casts the shadow: a shadow on the panel, or a
          // shadowed fill style as its background, also shadowed every card and field inside
          .background {
            Rectangle().fill(Color.cardBackground).shadow(color: .shadow, radius: 16, x: -2)
          }
          .overlay(alignment: .leading) {
            Rectangle().fill(Color.border).frame(width: pixelLength)
          }
          .background {
            ModalEscapeCatcher {
              dismissPresentedModal($isPresented)
            }
          }
          .transition(SidebarAnimation.trailingSlide)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
  }
}

/// Releases the field editor on the next turn, then closes the modal.
private func dismissPresentedModal(_ isPresented: Binding<Bool>) {
  // Async so AppKit drops the current first responder before the modal goes away.
  DispatchQueue.main.async {
    isPresented.wrappedValue = false
    NSApp.keyWindow?.makeFirstResponder(nil)
  }
}

// MARK: - Modal Backdrop

/// Background view for modals: a clear blur of the window content plus a moderate dim, so the
/// modal stands out while the app behind it stays recognizable
struct ModalBackdrop: View {
  var body: some View {
    ZStack {
      Rectangle().fill(.thinMaterial).opacity(0.8)
      Color.scrim
    }
    .contentShape(Rectangle())
  }
}

// MARK: - View Extension for Generic Modal

extension View {
  /// Shows a generic modal with zoom animation from center
  func genericModal<Content: View, Footer: View>(
    isPresented: Binding<Bool>,
    title: String,
    titleIcon: String? = nil,
    titleIconColor: Color = .foreground,
    width: CGFloat,
    height: CGFloat,
    @ViewBuilder content: @escaping () -> Content,
    @ViewBuilder footer: @escaping () -> Footer
  ) -> some View {
    modalOverlay(isPresented: isPresented) {
      GenericModal(
        title: title,
        titleIcon: titleIcon,
        titleIconColor: titleIconColor,
        width: width,
        height: height,
        isPresented: isPresented,
        content: content,
        footer: footer
      )
    }
  }

  /// Shows a generic modal without footer
  func genericModal<Content: View>(
    isPresented: Binding<Bool>,
    title: String,
    titleIcon: String? = nil,
    titleIconColor: Color = .foreground,
    width: CGFloat,
    height: CGFloat,
    @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    genericModal(
      isPresented: isPresented,
      title: title,
      titleIcon: titleIcon,
      titleIconColor: titleIconColor,
      width: width,
      height: height,
      content: content,
      footer: { EmptyView() }
    )
  }
}

// MARK: - Preview

#Preview("Generic Modal") {
  @Previewable @State var isPresented = true

  Color.appBackground
    .frame(width: 800, height: 700)
    .genericModal(
      isPresented: $isPresented,
      title: "Settings",
      titleIcon: "gear",
      width: 400,
      height: 500
    ) {
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.md) {
          Text("Modal Content")
            .font(.headline)
          Text("This is a generic modal component that can be reused across the app.")
            .foregroundColor(.foregroundMuted)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    } footer: {
      Spacer()
      Button("Cancel") {
        isPresented = false
      }
      .buttonStyle(FilledSecondaryButtonStyle())

      Button("Save") {
        isPresented = false
      }
      .buttonStyle(PrimaryButtonStyle())
    }
}

#Preview("Generic Modal - No Footer") {
  @Previewable @State var isPresented = true

  Color.appBackground
    .frame(width: 800, height: 700)
    .genericModal(
      isPresented: $isPresented,
      title: "Information",
      width: 350,
      height: 300
    ) {
      VStack(spacing: Spacing.md) {
        Image(systemName: "info.circle.fill")
          .font(.system(size: 48))
          .foregroundColor(.accent)

        Text("This modal has no footer")
          .font(.body)
          .foregroundColor(.foregroundMuted)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview("Generic Modal - With Icon") {
  @Previewable @State var isPresented = true

  Color.appBackground
    .frame(width: 800, height: 700)
    .genericModal(
      isPresented: $isPresented,
      title: "Connected",
      titleIcon: "bolt.fill",
      titleIconColor: .success,
      width: 380,
      height: 420
    ) {
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.md) {
          Text("Connection Details")
            .font(.headline)
          Text("Host: localhost")
          Text("Port: 5432")
          Text("Database: mydb")
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    } footer: {
      Spacer()
      Button("Disconnect") {}
        .buttonStyle(DangerButtonStyle())
    }
}
