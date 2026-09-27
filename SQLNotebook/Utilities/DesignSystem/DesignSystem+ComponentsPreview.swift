//
//  DesignSystem+ComponentsPreview.swift
//  SQLNotebook
//
//  Preview for all button styles in the design system
//

import SwiftUI

// Helper to avoid naming conflict with View.background() method
private let previewBackground: Color = .appBackground

// MARK: - All Buttons Preview

private struct AllButtonsPreview: View {
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.xl) {
        primarySection
        Divider()
        secondarySection
        Divider()
        filledSecondarySection
        Divider()
        dangerSection
        Divider()
        ghostSection
        Divider()
        sidebarHeaderSection
        Divider()
        floatingActionSection
        Divider()
        floatingPanelSection
      }
      .padding(Spacing.lg)
    }
    .frame(width: 500, height: 700)
    .background(previewBackground)
  }

  private var primarySection: some View {
    Group {
      Text("Primary").font(.headline)
      HStack(spacing: Spacing.md) {
        Button("Primary") {}.buttonStyle(PrimaryButtonStyle())
        Button {
        } label: {
          Label("Icon", systemImage: "plus")
        }.buttonStyle(PrimaryButtonStyle())
        Button {
        } label: {
          Image(systemName: "plus")
        }.buttonStyle(PrimaryButtonStyle(iconOnly: true))
        Button("Disabled") {}.buttonStyle(PrimaryButtonStyle()).disabled(true)
      }
    }
  }

  private var secondarySection: some View {
    Group {
      Text("Secondary").font(.headline)
      HStack(spacing: Spacing.md) {
        Button("Secondary") {}.buttonStyle(SecondaryButtonStyle())
        Button {
        } label: {
          Label("Icon", systemImage: "doc")
        }.buttonStyle(SecondaryButtonStyle())
        Button {
        } label: {
          Image(systemName: "doc")
        }.buttonStyle(SecondaryButtonStyle(iconOnly: true))
        Button("Disabled") {}.buttonStyle(SecondaryButtonStyle()).disabled(true)
      }
    }
  }

  private var filledSecondarySection: some View {
    Group {
      Text("Filled Secondary").font(.headline)
      HStack(spacing: Spacing.md) {
        Button("Filled") {}.buttonStyle(FilledSecondaryButtonStyle())
        Button {
        } label: {
          Label("Icon", systemImage: "doc.on.doc")
        }.buttonStyle(FilledSecondaryButtonStyle())
        Button {
        } label: {
          Image(systemName: "doc.on.doc")
        }.buttonStyle(FilledSecondaryButtonStyle(iconOnly: true))
        Button("Disabled") {}.buttonStyle(FilledSecondaryButtonStyle()).disabled(true)
      }
    }
  }

  private var dangerSection: some View {
    Group {
      Text("Danger").font(.headline)
      HStack(spacing: Spacing.md) {
        Button("Danger") {}.buttonStyle(DangerButtonStyle())
        Button {
        } label: {
          Label("Delete", systemImage: "trash")
        }.buttonStyle(DangerButtonStyle())
        Button {
        } label: {
          Image(systemName: "trash")
        }.buttonStyle(DangerButtonStyle(iconOnly: true))
        Button("Disabled") {}.buttonStyle(DangerButtonStyle()).disabled(true)
      }
    }
  }

  private var ghostSection: some View {
    Group {
      Text("Ghost").font(.headline)
      HStack(spacing: Spacing.md) {
        Button("Ghost") {}.buttonStyle(GhostButtonStyle())
        Button {
        } label: {
          Label("Settings", systemImage: "gear")
        }.buttonStyle(GhostButtonStyle())
        Button {
        } label: {
          Image(systemName: "gear")
        }.buttonStyle(GhostButtonStyle(iconOnly: true))
        Button {
        } label: {
          Image(systemName: "play.fill")
        }.buttonStyle(GhostButtonStyle(iconOnly: true))
        Button {
        } label: {
          Image(systemName: "stop.fill")
        }.buttonStyle(GhostButtonStyle(isActive: true, iconOnly: true))
      }
    }
  }

  private var sidebarHeaderSection: some View {
    Group {
      Text("Ghost Icon Only").font(.headline)
      HStack(spacing: Spacing.md) {
        Button {
        } label: {
          Image(systemName: "plus")
        }.buttonStyle(GhostButtonStyle(iconOnly: true))
        Button {
        } label: {
          Image(systemName: "folder")
        }.buttonStyle(GhostButtonStyle(isActive: true, iconOnly: true))
      }
    }
  }

  private var floatingActionSection: some View {
    Group {
      Text("Floating Action").font(.headline)
      HStack(spacing: Spacing.md) {
        Button {
        } label: {
          Image(systemName: "plus")
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(.foregroundMuted)
        }.buttonStyle(FloatingActionButtonStyle())
        Button {
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.foregroundMuted)
        }.buttonStyle(FloatingActionButtonStyle())
      }
    }
  }

  private var floatingPanelSection: some View {
    Group {
      Text("Floating Panel").font(.headline)
      HStack(spacing: Spacing.md) {
        Button {
        } label: {
          Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 12, weight: .medium))
        }.buttonStyle(FloatingPanelButtonStyle())
        Button {
        } label: {
          Image(systemName: "pin").font(.system(size: 12, weight: .medium))
        }.buttonStyle(FloatingPanelToggleButtonStyle(isActive: false))
        Button {
        } label: {
          Image(systemName: "pin.fill").font(.system(size: 12, weight: .medium))
        }.buttonStyle(FloatingPanelToggleButtonStyle(isActive: true))
      }
    }
  }
}

#Preview("All Buttons") {
  AllButtonsPreview()
}

#Preview("All Buttons (Small)") {
  AllButtonsPreview()
    .controlSize(.small)
}

// MARK: - Glass Preview

private struct GlassPreview: View {
  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xl) {
      Text("Chrome Glass").font(.headline)
      Text("Tab bar / header strip")
        .frame(maxWidth: .infinity, minHeight: ComponentSize.headerHeight)
        .chromeGlass()

      Text("Floating Bar Glass").font(.headline)
      HStack(spacing: Spacing.sm) {
        Image(systemName: "doc.on.doc")
        Text("Copy query")
      }
      .padding(.vertical, Spacing.sm)
      .padding(.horizontal, Spacing.md)
      .floatingBarGlass()

      Text("Glass Toolbar Group").font(.headline)
      GlassToolbarGroup {
        Button {
        } label: {
          Image(systemName: "play.fill")
        }.buttonStyle(.glassProminent)
        Button {
        } label: {
          Image(systemName: "stop.fill")
        }.buttonStyle(.glass)
        Button {
        } label: {
          Image(systemName: "gear")
        }.buttonStyle(.glass)
      }
    }
    .padding(Spacing.lg)
    .frame(width: 500, height: 400)
    // Colorful backdrop so the glass effect is visible
    .background(
      LinearGradient(
        colors: [.accent, .success, .warning],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    )
  }
}

#Preview("Glass (Light)") {
  GlassPreview()
    .preferredColorScheme(.light)
}

#Preview("Glass (Dark)") {
  GlassPreview()
    .preferredColorScheme(.dark)
}
