//
//  PerfSignpostTests.swift
//  DbloreTests
//

import Foundation
import Testing

@testable import Dblore

struct PerfSignpostTests {

  private struct SampleError: Error {}

  @Test("interval returns the body value")
  func testIntervalReturnsValue() {
    let value = PerfSignpost.interval("test") { 42 }
    #expect(value == 42)
  }

  @Test("interval rethrows the body error")
  func testIntervalRethrows() {
    #expect(throws: SampleError.self) {
      try PerfSignpost.interval("test") { () throws -> Int in throw SampleError() }
    }
  }

  @Test("async interval returns value")
  func testAsyncIntervalReturnsValue() async {
    let value = await PerfSignpost.interval("test") { () async -> Int in 7 }
    #expect(value == 7)
  }
}
