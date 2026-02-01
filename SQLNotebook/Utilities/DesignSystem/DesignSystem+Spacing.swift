//
//  DesignSystem+Spacing.swift
//  SQLNotebook
//
//  Spacing constants and sizing values for the design system
//

import SwiftUI

// MARK: - Spacing

enum Spacing {
  static let xxs: CGFloat = 2
  static let xs: CGFloat = 4
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
  static let footerHeight: CGFloat = 28
  static let sidebarWidth: CGFloat = 320
  static let cellSidebarWidth: CGFloat = 34
  static let buttonHeight: CGFloat = 32
  static let inputHeight: CGFloat = 36
  static let maxResultHeight: CGFloat = 500
  static let minCellHeight: CGFloat = 80

  // Tab bar and title bar
  static let tabBarHeight: CGFloat = 38
  /// Width for traffic light buttons (close, minimize, zoom) + left padding
  static let trafficLightWidth: CGFloat = 88
  /// Width for traffic light buttons + sidebar toggle button
  static let trafficLightAndToggleWidth: CGFloat = 105
}
