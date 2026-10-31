// SchemaLayoutEngineTests.swift
// The diagram lays out at most SchemaLayoutEngine.maxTables tables: above that it returns the
// count without laying out, and a cancelled layout returns no graph (never a half-moved one).

import CoreGraphics
import Foundation
import Testing
import os

@testable import Dblore

@Suite("Schema layout engine")
struct SchemaLayoutEngineTests {
  private static func tables(_ count: Int) -> [DatabaseTable] {
    (0..<count).map { index in
      DatabaseTable(
        schema: "public", name: "t\(index)",
        columns: [DatabaseColumn(name: "id", type: "integer", isPrimaryKey: true)])
    }
  }

  @Test("Above the cap the engine returns the table count without laying out")
  func tooManyTables() {
    let result = SchemaLayoutEngine().calculateLayout(
      tables: Self.tables(SchemaLayoutEngine.maxTables + 1), foreignKeys: [],
      canvasSize: CGSize(width: 800, height: 600))
    guard case .tooManyTables(let count) = result else {
      Issue.record("expected tooManyTables, got \(result)")
      return
    }
    #expect(count == SchemaLayoutEngine.maxTables + 1)
  }

  @Test("A cancelled layout returns no graph")
  func cancelledLayout() async {
    // Seconds of simulation at the cap: the cancel lands 50 ms after the layout starts, so even
    // a slow scheduler cannot let it finish first
    let tables = Self.tables(SchemaLayoutEngine.maxTables)
    let started = OSAllocatedUnfairLock(initialState: false)
    let task = Task.detached {
      started.withLock { $0 = true }
      return SchemaLayoutEngine().calculateLayout(
        tables: tables, foreignKeys: [], canvasSize: CGSize(width: 30_000, height: 24_000))
    }
    while !started.withLock({ $0 }) { await Task.yield() }
    // Past the entry check, into the simulation
    try? await Task.sleep(for: .milliseconds(50))
    task.cancel()
    let result = await task.value
    guard case .cancelled = result else {
      Issue.record("expected cancelled, got \(result)")
      return
    }
  }
}
