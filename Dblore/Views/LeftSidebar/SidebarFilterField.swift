//
//  SidebarFilterField.swift
//  Dblore
//
//  Compact keyword filter pinned to the top of a left-sidebar tab body. The field shows every
//  keystroke; the bound text follows 150 ms after the last one (a filter over a large catalog
//  runs once per pause, not per letter), and clearing applies at once.
//

import SwiftUI

/// Shared chrome for every left-sidebar filter row, so switching tabs does not jump.
enum SidebarFilterMetrics {
  static let controlHeight: CGFloat = 26
}

struct SidebarFilterField<Trailing: View>: View {
  @Binding var text: String
  var placeholder: String = "filter"
  /// Fixed capsule height for the field and its trailing control. Nil keeps the field's padding.
  var controlHeight: CGFloat? = SidebarFilterMetrics.controlHeight
  var topPadding: CGFloat = Spacing.sm
  var bottomPadding: CGFloat = Spacing.sm
  var trailingSpacing: CGFloat = Spacing.sm
  /// How long after the last keystroke `text` takes the typed value. Nil applies every
  /// keystroke (a caller that waits on its own). Clearing always applies at once.
  var applyDelay: Duration? = .milliseconds(150)
  private var trailing: Trailing
  /// What the field shows, ahead of `text` while typing
  @State private var draft: String
  @State private var pendingApply: Task<Void, Never>?

  init(
    text: Binding<String>,
    placeholder: String = "filter",
    controlHeight: CGFloat? = SidebarFilterMetrics.controlHeight,
    topPadding: CGFloat = Spacing.sm,
    bottomPadding: CGFloat = Spacing.sm,
    trailingSpacing: CGFloat = Spacing.sm,
    applyDelay: Duration? = .milliseconds(150),
    @ViewBuilder trailing: () -> Trailing
  ) {
    self._text = text
    self._draft = State(initialValue: text.wrappedValue)
    self.applyDelay = applyDelay
    self.placeholder = placeholder
    self.controlHeight = controlHeight
    self.topPadding = topPadding
    self.bottomPadding = bottomPadding
    self.trailingSpacing = trailingSpacing
    self.trailing = trailing()
  }

  /// Empty trailing must not take a slot, or the field picks up a gap on the right.
  private var showsTrailing: Bool {
    Trailing.self != EmptyView.self
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .center, spacing: showsTrailing ? trailingSpacing : 0) {
        field
        if showsTrailing {
          trailing
            .frame(height: controlHeight)
        }
      }
      .padding(.horizontal, Spacing.sm)
      .padding(.top, topPadding)
      .padding(.bottom, bottomPadding)

      Divider()
    }
    .onChange(of: draft) { _, value in apply(value) }
    // Set from outside: show it
    .onChange(of: text) { _, value in
      guard value != draft else { return }
      pendingApply?.cancel()
      draft = value
    }
    // Leaving with a keystroke not yet applied applies it
    .onDisappear {
      pendingApply?.cancel()
      if draft != text { text = draft }
    }
  }

  /// `value` into `text`: at once when cleared or without a delay, else after `applyDelay`
  /// unless another keystroke comes first
  private func apply(_ value: String) {
    pendingApply?.cancel()
    guard value != text else { return }
    guard let applyDelay, !value.isEmpty else {
      text = value
      return
    }
    pendingApply = Task {
      try? await Task.sleep(for: applyDelay)
      guard !Task.isCancelled else { return }
      text = value
    }
  }

  private var field: some View {
    HStack(spacing: Spacing.xs) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 11))
        .foregroundColor(.foregroundSubtle)

      TextField(placeholder, text: $draft)
        .textFieldStyle(.plain)
        .font(.small)
        .autocorrectionDisabled()

      if !draft.isEmpty {
        Button {
          pendingApply?.cancel()
          draft = ""
          text = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 11))
            .foregroundColor(.foregroundSubtle)
        }
        .buttonStyle(.plain)
        .help("Clear filter")
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, controlHeight == nil ? Spacing.xsm : 0)
    .frame(maxWidth: .infinity)
    .frame(height: controlHeight)
    .background(Capsule().fill(Color.controlBackground))
    .overlay(HairlineBorder(shape: Capsule()))
  }
}

extension SidebarFilterField where Trailing == EmptyView {
  init(text: Binding<String>, placeholder: String = "filter") {
    self.init(text: text, placeholder: placeholder) { EmptyView() }
  }
}
