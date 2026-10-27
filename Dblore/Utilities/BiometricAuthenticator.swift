//
//  BiometricAuthenticator.swift
//  Dblore
//

import Foundation
import LocalAuthentication

/// Biometric unlock (Touch ID) for Safe Mode and owner authentication (Touch ID or the Mac
/// password) for Lock. The app uses `LAContextBiometricAuthenticator`; under XCTest a stub
/// that never prompts is used (a system prompt would hang the test run).
protocol BiometricAuthenticator: AnyObject {
  /// True if biometrics are enrolled and usable right now (never prompts)
  var canUseBiometrics: Bool { get }
  /// Prompts for biometrics; false on failure, cancel or when unavailable
  func authenticate(reason: String) async -> Bool
  /// Prompts for Touch ID or the Mac password; returns the proof (the evaluated context, for
  /// Keychain reuse through kSecUseAuthenticationContext), nil on failure or cancel
  func authenticateOwner(reason: String) async -> OwnerAuthentication?
}

extension BiometricAuthenticator {
  /// Test doubles never prompt
  func authenticateOwner(reason: String) async -> OwnerAuthentication? { nil }
}

/// Proof of a successful owner authentication: only `authenticateOwner(reason:)` in this file
/// makes one, so a proof-gated read (`LockKeyStore.read`) cannot run on a bare context.
/// Invalidate it once the protected read is done.
nonisolated struct OwnerAuthentication {
  /// The evaluated context
  let context: LAContext

  fileprivate init(context: LAContext) {
    self.context = context
  }

  /// Ends the context's reuse window, so a later read prompts again
  func invalidate() { context.invalidate() }
}

/// Touch ID via `LAContext`. `authenticate` is biometrics only: the system passcode fallback is
/// hidden because the app shows its own Safe Mode password field as the fallback.
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

  func authenticateOwner(reason: String) async -> OwnerAuthentication? {
    // The system password fallback stays visible: the Mac password is an accepted owner proof
    let context = LAContext()
    do {
      guard
        try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
      else { return nil }
      return OwnerAuthentication(context: context)
    } catch {
      return nil
    }
  }
}

/// Biometrics that are never available (used under XCTest)
final class UnavailableBiometricAuthenticator: BiometricAuthenticator {
  var canUseBiometrics: Bool { false }

  func authenticate(reason: String) async -> Bool { false }
}

#if DEBUG
  /// Grants owner authentication without prompting (an unevaluated context), so unit tests can
  /// reach proof-gated reads against an in-memory Keychain. Debug builds only; the app never
  /// uses it.
  final class GrantingOwnerTestAuthenticator: BiometricAuthenticator {
    var canUseBiometrics: Bool { false }

    func authenticate(reason: String) async -> Bool { false }

    func authenticateOwner(reason: String) async -> OwnerAuthentication? {
      OwnerAuthentication(context: LAContext())
    }
  }
#endif
