//
//  CommitStyle.swift
//  Dblore
//

import Foundation

/// How a connection confirms a write. Stronger styles have a higher `strength`.
enum CommitStyle: String, Codable, Sendable {
  case immediate
  case confirm
  case review
  case password

  /// immediate < confirm < review < password.
  var strength: Int {
    switch self {
    case .immediate: 0
    case .confirm: 1
    case .review: 2
    case .password: 3
    }
  }

  var confirmsWrites: Bool {
    self == .confirm || self == .password
  }

  var requiresPassword: Bool {
    self == .password
  }

  var opensReviewTransaction: Bool {
    self == .review
  }

  var legacyProjection: (protectedMode: Bool, safeMode: SafeMode) {
    switch self {
    case .immediate: (protectedMode: false, safeMode: .silent)
    case .confirm: (protectedMode: false, safeMode: .alertRead)
    case .review: (protectedMode: true, safeMode: .silent)
    case .password: (protectedMode: false, safeMode: .safeRead)
    }
  }

  /// Protected plus password becomes review, and that mapping is accepted.
  static func migrate(protectedMode: Bool, safeMode: SafeMode?) -> CommitStyle? {
    if protectedMode {
      return .review
    }
    switch safeMode {
    case nil:
      return nil
    case .silent:
      return .immediate
    case .alertRead, .alertAll:
      return .confirm
    case .safeRead, .safeAll:
      return .password
    }
  }

  static func migrateGlobal(stored: SafeMode?, keyPresent: Bool) -> CommitStyle {
    guard keyPresent else { return .review }
    switch stored {
    case .silent:
      return .immediate
    case .alertRead, .alertAll:
      return .confirm
    case .safeRead, .safeAll:
      return .password
    case nil:
      return .review
    }
  }
}
