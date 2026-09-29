//
//  PerfSignpost.swift
//  SQLNotebook
//
//  Points-of-interest signposts for Instruments performance measurement
//

import Foundation
import OSLog

nonisolated enum PerfSignpost {
  private static let signposter = OSSignposter(
    subsystem: Bundle.main.bundleIdentifier ?? "SQLNotebook",
    category: .pointsOfInterest
  )

  /// Measure a synchronous block as a signpost interval
  static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
    let state = signposter.beginInterval(name)
    defer { signposter.endInterval(name, state) }
    return try body()
  }

  /// Measure an async block as a signpost interval
  static func interval<T>(_ name: StaticString, _ body: () async throws -> T) async rethrows -> T {
    let state = signposter.beginInterval(name)
    defer { signposter.endInterval(name, state) }
    return try await body()
  }

  /// Emit a single point-in-time signpost event
  static func event(_ name: StaticString) {
    signposter.emitEvent(name)
  }
}
