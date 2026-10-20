// SearchResponsivenessTests.swift
// The notebook search scans up to the row cap of every result: the scan must not run on the
// main actor, or the window freezes for the whole scan. Compared within one run (stall vs
// total search time), so a slow runner does not fail it. Other suites share this process's
// main actor: when it is busy right before or after the search, the stall check is skipped
// and reported as a known issue.

import Foundation
import Testing

@testable import Dblore

@Suite("Search responsiveness", .serialized)
@MainActor
struct SearchResponsivenessTests {
  private static func ms(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
  }

  /// Main-actor ticker: a gap between two 1 ms sleeps is time the main actor was busy
  private static func startTicker() -> Task<Duration, Never> {
    Task { @MainActor in
      var maxGap = Duration.zero
      while !Task.isCancelled {
        let start = ContinuousClock.now
        try? await Task.sleep(for: .milliseconds(1))
        maxGap = max(maxGap, ContinuousClock.now - start)
      }
      return maxGap
    }
  }

  /// Longest main-actor gap over a quiet 100 ms window (nothing of this test runs in it)
  private static func controlGap() async -> Double {
    let ticker = startTicker()
    try? await Task.sleep(for: .milliseconds(100))
    ticker.cancel()
    return ms(await ticker.value)
  }

  @Test("Searching a 10k x 30 result leaves the main actor free during the scan")
  func scanDoesNotStallMainActor() async {
    let viewModel = NotebookViewModel()
    var cell = NotebookCell(cellType: .sql, content: "SELECT * FROM big")
    cell.result = PerfFixtures.cellResult(rows: 10_000, columns: 30)
    viewModel.notebook.cells = [cell]

    let before = await Self.controlGap()
    let ticker = Self.startTicker()
    await Task.yield()
    let start = ContinuousClock.now
    await viewModel.performSearch(query: "no-such-value", caseSensitive: false)
    let totalMs = Self.ms(ContinuousClock.now - start)
    ticker.cancel()
    let stallMs = Self.ms(await ticker.value)
    let after = await Self.controlGap()

    #expect(viewModel.searchState.matches.isEmpty)
    #expect(!viewModel.searchState.isSearching)
    PerfReport.record("search10kx30.total", ms: totalMs)
    PerfReport.record("search10kx30.maxMainStall", ms: stallMs)
    // The main actor was shared with other suites: the stall is not this search's
    let quiet = before < 20 && after < 20
    withKnownIssue("Main actor busy around the search; stall check skipped", isIntermittent: true) {
      #expect(quiet, "main actor busy: \(before) ms before, \(after) ms after")
    }
    guard quiet else { return }
    #expect(stallMs < totalMs * 0.25, "main actor stalled \(stallMs) ms of a \(totalMs) ms search")
  }
}
