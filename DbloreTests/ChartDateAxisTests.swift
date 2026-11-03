// ChartDateAxisTests.swift
// A date x axis places and labels its ticks in the zone the grid shows the column in: UTC for a
// naive timestamp, the display zone for a zoned one.

import Foundation
import Testing

@testable import Dblore

@Suite("Chart date axis")
struct ChartDateAxisTests {
  /// 2026-10-15 00:00:00 UTC
  private let midnight = Date(timeIntervalSince1970: 1_792_022_400)
  private let english = Locale(identifier: "en_US")

  private func series(wallClock: Bool) -> ChartSeries {
    ChartSeries(points: [], droppedCount: 0, xWallClock: wallClock)
  }

  private func hours(_ hours: Double...) -> [Date] {
    hours.map { midnight.addingTimeInterval($0 * 3_600) }
  }

  /// The labels with the narrow no-break space some locales put before AM / PM made plain
  private func labels(_ axis: ChartDateAxis) -> [String] {
    axis.values.map { axis.format.format($0).replacingOccurrences(of: "\u{202F}", with: " ") }
  }

  @Test("A naive day reads as its wall clock whatever the display zone (regression A5)")
  func naiveDayIsTheWallClock() {
    for zone in ["America/Los_Angeles", "Asia/Ho_Chi_Minh", "UTC"] {
      CellValue.$displayZone.withValue(TimeZone(identifier: zone)!) {
        let axis = ChartDateAxis(
          domain: midnight...midnight.addingTimeInterval(23 * 3_600),
          zone: series(wallClock: true).xTimeZone, locale: english)
        #expect(axis.values == hours(0, 6, 12, 18))
        #expect(labels(axis) == ["12 AM", "6 AM", "12 PM", "6 PM"])
      }
    }
  }

  @Test("A zoned day is placed and labeled in the display zone (regression A5)")
  func zonedDayFollowsTheDisplayZone() {
    CellValue.$displayZone.withValue(TimeZone(identifier: "Asia/Ho_Chi_Minh")!) {
      let axis = ChartDateAxis(
        domain: midnight...midnight.addingTimeInterval(23 * 3_600),
        zone: series(wallClock: false).xTimeZone, locale: english)
      // +07:00: 05:00 UTC is noon there
      #expect(axis.values == hours(5, 11, 17, 23))
      #expect(labels(axis) == ["12 PM", "6 PM", "12 AM", "6 AM"])
    }
  }

  @Test("Longer spans step by days, months, then years")
  func longerSpansUseCoarserSteps() {
    let day = 86_400.0
    let utc = TimeZone(identifier: "UTC")!
    let week = ChartDateAxis(
      domain: midnight...midnight.addingTimeInterval(4 * day), zone: utc, locale: english)
    #expect(labels(week) == ["Oct 15", "Oct 16", "Oct 17", "Oct 18", "Oct 19"])

    let year = ChartDateAxis(
      domain: midnight...midnight.addingTimeInterval(300 * day), zone: utc, locale: english)
    #expect(labels(year).first == "Jan 2027")
    #expect(labels(year).count <= ChartDateAxis.maxTicks)

    let decades = ChartDateAxis(
      domain: midnight...midnight.addingTimeInterval(30 * 365 * day), zone: utc, locale: english)
    #expect(labels(decades) == ["2030", "2035", "2040", "2045", "2050", "2055"])
  }

  @Test("Absurd date spans give an axis instead of trapping")
  func absurdSpansDoNotTrap() {
    let utc = TimeZone(identifier: "UTC")!
    let infinite = ChartDateAxis(
      domain: Date(timeIntervalSince1970: -1e308)...Date(timeIntervalSince1970: 1e308), zone: utc)
    #expect(infinite.values.count == 1)
    let huge = ChartDateAxis(
      domain: Date(timeIntervalSince1970: 0)...Date(timeIntervalSince1970: 1e27), zone: utc)
    #expect(!huge.values.isEmpty)
  }
}
