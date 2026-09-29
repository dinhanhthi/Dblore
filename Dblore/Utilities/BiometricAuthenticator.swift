//
//  BiometricAuthenticator.swift
//  Dblore
//

import Foundation
import LocalAuthentication

/// Biometric unlock (Touch ID) for Safe Mode. The app uses `LAContextBiometricAuthenticator`;
/// under XCTest a stub that never prompts is used (a system prompt would hang the test run).
protocol BiometricAuthenticator: AnyObject {
  /// True if biometrics are enrolled and usable right now (never prompts)
  var canUseBiometrics: Bool { get }
  /// Prompts for biometrics; false on failure, cancel or when unavailable
  func authenticate(reason: String) async -> Bool
}

/// Touch ID via `LAContext`, biometrics only: the system passcode fallback is hidden because
/// the app shows its own Safe Mode password field as the fallback.
final class LAContextBiometricAuthenticator: BiometricAuthenticator {
  var canUseBiometrics: Bool {
    LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
  }

  func authenticate(reason: String) async -> Bool {
    // A fresh context per prompt: a context is single-use once evaluated
    let context = LAContext()
    context.localizedFallbackTitle = ""
    do {
      return try await context.evaluatePolicy(
        .deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
    } catch {
      return false
    }
  }
}

/// Biometrics that are never available (used under XCTest)
final class UnavailableBiometricAuthenticator: BiometricAuthenticator {
  var canUseBiometrics: Bool { false }

  func authenticate(reason: String) async -> Bool { false }
}
