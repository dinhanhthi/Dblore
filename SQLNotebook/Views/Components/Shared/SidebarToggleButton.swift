//
//  SidebarToggleButton.swift
//  SQLNotebook
//

import SwiftUI

/// Reusable toggle button for showing/hiding the left sidebar
/// Used in both tab bar (when sidebar hidden) and sidebar header (when sidebar visible)
struct SidebarToggleButton: View {
  /// Whether the sidebar is currently visible
  let isSidebarVisible: Bool
  /// Action to toggle sidebar visibility
  let action: () -> Void

  var body: some View {
    Button {
      action()
    } label: {
      Image(systemName: "sidebar.left")
        .font(.system(size: 16, weight: .medium))
        .foregroundColor(isSidebarVisible ? Color.accent : Color.foregroundMuted)
        .frame(width: 16, height: 16)
    }
    .buttonStyle(.plain)
    .pointerStyle(.link)
    .padding(.trailing, Spacing.sm)
    .blockDoubleClickZoom()
    .help(isSidebarVisible ? "Hide sidebar" : "Show sidebar")
  }
}
