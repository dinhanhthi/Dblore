// CivilDate.swift
// A DATE's day count as `YYYY-MM-DD` text in the proleptic Gregorian calendar, and back (Howard
// Hinnant's civil-from-days and days-from-civil algorithms). Foundation's Gregorian calendar is
// Julian before 1582-10-15 and has no BC marker, so DATE text never goes through it.

import Foundation

nonisolated enum CivilDate {
  /// `days` since 1970-01-01 as `YYYY-MM-DD`; a year before 1 prints as its BC year (year 0 is
  /// 1 BC) followed by `bcSuffix`, the engine's own marker.
  static func text(daysSince1970 days: Int, bcSuffix: String) -> String {
    let z = days + 719_468  // days since 0000-03-01
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let dayOfEra = z - era * 146_097
    let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
    let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
    let shiftedMonth = (5 * dayOfYear + 2) / 153
    let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
    let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
    let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
    let text = String(format: "%04d-%02d-%02d", year > 0 ? year : 1 - year, month, day)
    return year > 0 ? text : text + bcSuffix
  }

  /// Days since 1970-01-01 of a proleptic Gregorian date; `year` is astronomical (0 is 1 BC).
  static func daysSince1970(year: Int, month: Int, day: Int) -> Int {
    let y = month <= 2 ? year - 1 : year
    let era = (y >= 0 ? y : y - 399) / 400
    let yearOfEra = y - era * 400
    let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
  }
}
