// AppleIntelligenceAvailability.swift
// Whether Apple Intelligence can run requests on this Mac, readable on every SDK and macOS

import Foundation

#if canImport(FoundationModels)
  import FoundationModels
#endif

nonisolated enum AppleIntelligenceAvailability: Equatable, Sendable {
  case available
  case deviceNotEligible
  case notEnabled
  case modelNotReady
  /// Below macOS 26, or an SDK without FoundationModels
  case osTooOld
  /// A reason a later macOS adds
  case unavailable

  var isAvailable: Bool { self == .available }

  /// Why Apple Intelligence cannot be used; nil when it can
  var message: String? {
    switch self {
    case .available: return nil
    case .deviceNotEligible: return "This Mac can't run Apple Intelligence."
    case .notEnabled: return "Turn on Apple Intelligence in System Settings."
    case .modelNotReady: return "Apple Intelligence is still getting ready."
    case .osTooOld: return "Apple Intelligence needs macOS 26 or later."
    case .unavailable: return "Apple Intelligence isn't available on this Mac right now."
    }
  }

  /// The system model's availability: a synchronous property read (its cost is not measured),
  /// never a crash on macOS 14 and 15 (FoundationModels is weak-linked and only touched on
  /// macOS 26 and later)
  static var current: AppleIntelligenceAvailability {
    #if canImport(FoundationModels)
      if #available(macOS 26, *) {
        return map(SystemLanguageModel.default.availability)
      }
    #endif
    return .osTooOld
  }

  #if canImport(FoundationModels)
    @available(macOS 26, *)
    private static func map(_ availability: SystemLanguageModel.Availability) -> Self {
      switch availability {
      case .available: return .available
      case .unavailable(let reason):
        switch reason {
        case .deviceNotEligible: return .deviceNotEligible
        case .appleIntelligenceNotEnabled: return .notEnabled
        case .modelNotReady: return .modelNotReady
        @unknown default: return .unavailable
        }
      }
    }
  #endif
}
