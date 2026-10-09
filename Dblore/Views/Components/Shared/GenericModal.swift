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
      }

      Spacer(minLength: Spacing.sm)

      trailing()

      Button(action: onClose) {
        Image(systemName: "xmark")
      }
      .buttonStyle(GhostButtonStyle(iconOnly: true))
      .help("Close (Esc)")
    }
    .modalBarPadding(vertical: Spacing.sm)
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
    onClose: @escaping () -> Void
  ) {
    self.title = title
    self.titleIcon = titleIcon
    self.titleIconColor = titleIconColor
    self.onClose = onClose
    self.trailing = { EmptyView() }
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
    .background(Color.cardBackground)
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
  func modalOverlay<ModalContent: View>(
    isPresented: Binding<Bool>,
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
            .transition(.scale(scale: 0.95).combined(with: .opacity))
        }
      }
      .allowsHitTesting(isPresented.wrappedValue)
      .animation(.easeOut(duration: 0.2), value: isPresented.wrappedValue)
    }
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
      Color.black.opacity(0.35)
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
      .buttonStyle(SecondaryButtonStyle())

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
