//
//  SafeModeIndicator.swift
//  SQLNotebook
//
//  Shows current Safe Mode level - clickable to open settings
//

import SwiftUI

/// Shows current Safe Mode level - clickable to open settings
/// Shows per-connection SafeMode if set, otherwise shows global SafeMode
struct SafeModeIndicator: View {
  @Bindable private var appSettings = AppSettings.shared
  var connectionConfig: ConnectionConfig?  // Current connection's config (if connected)
  var onTap: () -> Void

  /// The effective SafeMode - per-connection override or global setting
  private var effectiveSafeMode: SafeMode {
    connectionConfig?.safeMode ?? appSettings.safeMode
  }

  /// Whether showing per-connection override vs global setting
  private var isPerConnectionOverride: Bool {
    connectionConfig?.safeMode != nil
  }

  var body: some View {
    let safeMode = effectiveSafeMode

    // Only show indicator for non-Silent modes
    if safeMode != .silent {
      Button(action: onTap) {
        HStack(spacing: 4) {
          Image(systemName: safeModeIcon)
            .font(.system(size: 9))
          Text(safeMode.badgeText)
            .font(.small)
        }
        .foregroundColor(safeModeColor)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 2)
        .tintedCapsuleGlass(safeModeColor)
      }
      .buttonStyle(.plain)
      .linkPointer()
      .help(helpText)
      .onHover { hovering in
        if hovering {
          NSCursor.pointingHand.push()
        } else {
          NSCursor.pop()
        }
      }
    }
  }

  private var helpText: String {
    let modeDescription = effectiveSafeMode.shortDescription
    let source = isPerConnectionOverride ? "Per-connection" : "Global"
    return "\(source): \(modeDescription)\nClick to configure"
  }

  private var safeModeIcon: String {
    switch effectiveSafeMode {
    case .silent:
      return "bolt.fill"
    case .alertRead, .alertAll:
      return "exclamationmark.triangle.fill"
    case .safeRead, .safeAll:
      return "lock.shield.fill"
    }
  }

  private var safeModeColor: Color {
    switch effectiveSafeMode {
    case .silent:
      return .foregroundMuted
    case .alertRead, .alertAll:
      return .warning
    case .safeRead, .safeAll:
      return .accent
    }
  }
}
