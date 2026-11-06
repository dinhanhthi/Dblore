//
//  RunningWorkRegistryTests.swift
//  DbloreTests
//

import Foundation
import Testing

@testable import Dblore

@Suite("Running work registry")
@MainActor
struct RunningWorkRegistryTests {
  private let first = UUID()
  private let second = UUID()

  @Test("Close and disconnect list only their workspace's work; quit lists all of it")
  func scopeFiltersByWorkspace() {
    let registry = RunningWorkRegistry()
    registry.begin(workspaceID: first, label: "Copy Objects to shop", kind: .copyObjects) {}
    registry.begin(workspaceID: second, label: "Import into orders", kind: .dataImport) {}
    registry.begin(workspaceID: nil, label: "Parquet export", kind: .dataExport) {}
    let queries = [
      RunningWorkRegistry.RunningQuery(workspaceID: first, label: "Query in Tab 1"),
      RunningWorkRegistry.RunningQuery(workspaceID: second, label: "Query in Tab 2"),
    ]

    let close = RunningWorkRegistry.decide(
      items: registry.items, runningQueries: queries, scope: .close(workspaceID: first),
      confirmBeforeQuit: false)
    #expect(close.prompt?.lines == ["Query in Tab 1", "Copy Objects to shop"])
    #expect(close.prompt?.stopTitle == "Stop and Close")

    let disconnect = RunningWorkRegistry.decide(
      items: registry.items, runningQueries: queries, scope: .disconnect(workspaceID: second),
      confirmBeforeQuit: false)
    #expect(disconnect.prompt?.lines == ["Query in Tab 2", "Import into orders"])
    #expect(disconnect.prompt?.stopTitle == "Stop and Disconnect")

    let quit = RunningWorkRegistry.decide(
      items: registry.items, runningQueries: queries, scope: .quit, confirmBeforeQuit: false)
    #expect(
      quit.prompt?.lines == [
        "Query in Tab 1", "Query in Tab 2", "Copy Objects to shop", "Import into orders",
        "Parquet export",
      ])
    #expect(quit.prompt?.stopTitle == "Stop and Quit")

    // A workspace with nothing running closes at once
    let other = RunningWorkRegistry.decide(
      items: registry.items, runningQueries: queries, scope: .close(workspaceID: UUID()),
      confirmBeforeQuit: true)
    #expect(other == .proceed)
  }

  @Test("Confirm before quit only adds the generic question when nothing runs at quit")
  func settingOnlyAffectsNothingRunning() {
    let registry = RunningWorkRegistry()
    for scope: RunningWorkRegistry.Scope in [
      .quit, .close(workspaceID: first), .disconnect(workspaceID: first),
    ] {
      #expect(
        RunningWorkRegistry.decide(
          items: [], runningQueries: [], scope: scope, confirmBeforeQuit: false) == .proceed)
    }
    #expect(
      RunningWorkRegistry.decide(
        items: [], runningQueries: [], scope: .quit, confirmBeforeQuit: true) == .confirmQuit)
    #expect(
      RunningWorkRegistry.decide(
        items: [], runningQueries: [], scope: .close(workspaceID: first),
        confirmBeforeQuit: true) == .proceed)
    #expect(
      RunningWorkRegistry.decide(
        items: [], runningQueries: [], scope: .disconnect(workspaceID: first),
        confirmBeforeQuit: true) == .proceed)

    registry.begin(workspaceID: first, label: "SQL dump of shop", kind: .dump) {}
    let on = RunningWorkRegistry.decide(
      items: registry.items, runningQueries: [], scope: .quit, confirmBeforeQuit: true)
    let off = RunningWorkRegistry.decide(
      items: registry.items, runningQueries: [], scope: .quit, confirmBeforeQuit: false)
    #expect(on == off)
    #expect(on.prompt?.lines == ["SQL dump of shop"])

    // A running query alone asks too, whatever the setting
    let query = RunningWorkRegistry.decide(
      items: [], runningQueries: [.init(workspaceID: first, label: "Query in Tab 1")],
      scope: .quit, confirmBeforeQuit: false)
    #expect(query.prompt?.lines == ["Query in Tab 1"])
  }

  @Test("A restore line says what stopping does on its engine")
  func restoreWordingPerEngine() {
    let rolledBack = "will be stopped and rolled back"
    let kept = "will be stopped; statements already run stay in the database"
    #expect(RunningWorkRegistry.restoreConsequence(.postgresql) == rolledBack)
    #expect(RunningWorkRegistry.restoreConsequence(.sqlite) == rolledBack)
    #expect(RunningWorkRegistry.restoreConsequence(.duckdb) == rolledBack)
    #expect(RunningWorkRegistry.restoreConsequence(.mysql) == kept)
    #expect(RunningWorkRegistry.restoreConsequence(.mongodb) == kept)

    let registry = RunningWorkRegistry()
    registry.begin(workspaceID: first, label: "Restore of shop.sql", kind: .restore(.postgresql)) {}
    registry.begin(workspaceID: first, label: "Restore of crm.sql", kind: .restore(.mysql)) {}
    registry.begin(workspaceID: first, label: "SQL dump of shop", kind: .dump) {}
    registry.begin(workspaceID: first, label: "Script", kind: .schemaChange(.mysql)) {}
    #expect(registry.items.map(\.stopConsequence) == [rolledBack, kept, nil, kept])

    let decision = RunningWorkRegistry.decide(
      items: registry.items, runningQueries: [], scope: .quit, confirmBeforeQuit: false)
    #expect(
      decision.prompt?.lines == [
        "Restore of shop.sql \(rolledBack)", "Restore of crm.sql \(kept)", "SQL dump of shop",
        "Script \(kept)",
      ])
  }

  @Test("End after cancel removes the entry once and leaves the others")
  func endAfterCancel() {
    let registry = RunningWorkRegistry()
    var cancelled: [String] = []
    let copy = registry.begin(workspaceID: first, label: "Copy", kind: .copyObjects) {
      cancelled.append("copy")
    }
    registry.begin(workspaceID: second, label: "Import", kind: .dataImport) {
      cancelled.append("import")
    }

    registry.cancelAll(in: .close(workspaceID: first))
    #expect(cancelled == ["copy"])
    // Cancelling does not remove the entry: the work leaves when it ends
    #expect(registry.items.map(\.label) == ["Copy", "Import"])

    registry.end(copy)
    #expect(registry.items.map(\.label) == ["Import"])
    registry.end(copy)
    #expect(registry.items.map(\.label) == ["Import"])

    registry.cancelAll(in: .quit)
    #expect(cancelled == ["copy", "import"])
  }

  @Test(
    "Quit with work running asks once, whatever Confirm before quit; Stop or Cancel is the answer")
  func quitAsksOnce() {
    /// The prompts shown, and the answer they get
    final class Answers {
      var prompts: [RunningWorkRegistry.Prompt] = []
      var stops = false
    }
    let registry = RunningWorkRegistry()
    let answers = Answers()
    registry.presentPrompt = { prompt in
      answers.prompts.append(prompt)
      return answers.stops
    }
    // Nothing runs: only the generic question, which the caller asks (no running-work prompt)
    #expect(registry.ask(.quit, runningQueries: [], confirmBeforeQuit: true) == .confirmQuit)
    #expect(registry.ask(.quit, runningQueries: [], confirmBeforeQuit: false) == .proceed)
    #expect(answers.prompts.isEmpty)

    // Cmd+Q with the setting on and a dump running: the running-work prompt alone
    registry.begin(workspaceID: first, label: "SQL dump of shop", kind: .dump) {}
    #expect(registry.ask(.quit, runningQueries: [], confirmBeforeQuit: true) == .cancel)
    #expect(answers.prompts.map(\.lines) == [["SQL dump of shop"]])
    #expect(answers.prompts.first?.stopTitle == "Stop and Quit")

    answers.stops = true
    #expect(registry.ask(.quit, runningQueries: [], confirmBeforeQuit: true) == .stop)
    #expect(answers.prompts.count == 2)
  }

  @Test("Stop waits until the work ended, and never longer than its limit when a cancel hangs")
  func stopWaitIsBounded() async {
    let registry = RunningWorkRegistry()
    var stoppedQuietly: [Bool] = []
    var copy: RunningWorkRegistry.Token?
    copy = registry.begin(workspaceID: first, label: "Copy", kind: .copyObjects) {
      // A second close or disconnect while the stop waits is ignored
      stoppedQuietly.append(registry.stopsWithoutAsking(workspaceID: first))
      copy.map(registry.end)
    }
    var queryRuns = true
    let clock = ContinuousClock()
    // No wall-clock bound here: a loaded test host can starve the main actor for many seconds.
    // The stop ending its work and every query is what the checks below prove.
    await registry.stop(
      .close(workspaceID: first),
      stopQueries: {
        queryRuns = false
        return []
      },
      queriesRunning: { queryRuns }, limit: .seconds(30))
    #expect(!queryRuns)
    #expect(stoppedQuietly == [true])
    #expect(registry.items.isEmpty)
    // After the stop, a close or disconnect asks as usual
    #expect(!registry.stopsWithoutAsking(workspaceID: first))

    // A cancel that never ends its work, and a query that never stops: the wait ends at the limit
    registry.begin(workspaceID: second, label: "Import", kind: .dataImport) {}
    let hung = await clock.measure {
      await registry.stop(
        .quit, stopQueries: { [] }, queriesRunning: { true }, limit: .milliseconds(200))
    }
    #expect(hung >= .milliseconds(200))
    #expect(registry.items.map(\.label) == ["Import"])
  }

  @Test("A label is shown on one line: breaks, control and bidi characters become spaces")
  func labelOnOneLine() {
    let registry = RunningWorkRegistry()
    registry.begin(
      workspaceID: first, label: " Import into or\nders\u{202E}lmth.exe\u{0007}\n",
      kind: .dataImport
    ) {}
    #expect(registry.items.map(\.label) == ["Import into or ders lmth.exe"])
  }
}
