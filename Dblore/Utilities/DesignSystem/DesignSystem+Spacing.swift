//
//  DesignSystem+Spacing.swift
//  Dblore
//
//  Spacing constants and sizing values for the design system
//

import SwiftUI

// MARK: - Spacing

enum Spacing {
  static let xxs: CGFloat = 2
  static let xs: CGFloat = 4
  static let xsm: CGFloat = 6
  static let sm: CGFloat = 8
  static let md: CGFloat = 12
  static let lg: CGFloat = 16
  static let xl: CGFloat = 24
  static let xxl: CGFloat = 32
}

// MARK: - Corner Radius

enum CornerRadius {
  static let sm: CGFloat = 4
  static let md: CGFloat = 6
  static let lg: CGFloat = 8
  static let xl: CGFloat = 12
  static let xxl: CGFloat = 16
  static let xxxl: CGFloat = 20
}

// MARK: - Sizes

enum ComponentSize {
  static let headerHeight: CGFloat = 44
  /// Data viewer header: icon-only Refresh and Search
  static let compactHeaderHeight: CGFloat = 36
  static let footerHeight: CGFloat = 28
  static let sidebarWidth: CGFloat = 320
  static let cellSidebarWidth: CGFloat = 34
  static let buttonHeight: CGFloat = 32
  static let inputHeight: CGFloat = 36
  static let maxResultHeight: CGFloat = 500
  static let minCellHeight: CGFloat = 80
  /// Cell parameter form: adaptive column bounds for one `ParameterInputBlock`.
  static let parameterBlockMinWidth: CGFloat = 220
  static let parameterBlockMaxWidth: CGFloat = 320

  // Tab bar and title bar
  /// Equals the titlebar row of the compact toolbar every document window installs (40pt on
  /// macOS 26+, 38pt before), so the Dblore header fills that row and the native tab bar sits
  /// right below it.
  static let tabBarHeight: CGFloat = {
    if #available(macOS 26, *) { return 40 }
    return 38
  }()
  /// Width the traffic lights (close, minimize, zoom) take at the leading edge of the titlebar
  /// row: AppKit's zoom button maxX (72 on macOS 27) + 16. Fallback for the runtime
  /// `trafficLightsWidth` environment value.
  static let trafficLightWidth: CGFloat = 88
  /// Added to the traffic lights width to place the sidebar toggle button group
  static let sidebarToggleOffset: CGFloat = 11
  /// Width for traffic light buttons + sidebar toggle button
  static let trafficLightAndToggleWidth: CGFloat = trafficLightWidth + sidebarToggleOffset
}
