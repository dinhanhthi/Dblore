// DateBindText.swift
// PostgreSQL bind text for a decoded `.date`: UTC ISO 8601 with exactly six fractional digits,
// rounded to the nearest microsecond, so a `timestamp`/`timestamptz` key matches its row.
// Used by inline-edit primary keys and foreign key lookups. SQLite never decodes `.date`.

import Foundation

nonisolated enum DateBindText {
  /// `yyyy-MM-ddTHH:mm:ss.ffffffZ`. Seconds are floored, so -0.5 s is `23:59:59.500000Z`.
  /// A date beyond Int64 microseconds (PostgreSQL `infinity`) has no fraction.
  static func string(from date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    guard let micros = Int64(exactly: (date.timeIntervalSince1970 * 1_000_000).rounded()) else {
      return formatter.string(from: date)
    }
    var (seconds, fraction) = micros.quotientAndRemainder(dividingBy: 1_000_000)
    if fraction < 0 {
      seconds -= 1
      fraction += 1_000_000
    }
    let whole = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    return whole.dropLast() + String(format: ".%06lldZ", fraction)
  }
}
