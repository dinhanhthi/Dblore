// ExplainPlanAnalyzerTests.swift
// Exclusive time, cost, shares, buffers, and warnings for an EXPLAIN tree.

import Foundation
import Testing

@testable import Dblore

@Suite("EXPLAIN plan analyzer")
struct ExplainPlanAnalyzerTests {
  @Test("Exclusive time floors at 0 when children sum past the parent")
  func exclusiveFloorsAtZero() throws {
    let analyzed = try analyze(
      """
      {"Plan":{"Node Type":"Result","Actual Total Time":1,"Actual Loops":1,"Plans":[
        {"Node Type":"Seq Scan","Actual Total Time":5,"Actual Loops":1}
      ]}}
      """
    )

    #expect(analyzed.nodes[0].inclusive == 1)
    #expect(analyzed.nodes[0].exclusive == 0)
    #expect(analyzed.nodes[0].share == 0)
    #expect(analyzed.nodes[1].inclusive == 5)
    #expect(analyzed.nodes[1].exclusive == 5)
    #expect(analyzed.nodes[1].share == 1)
  }

  @Test("Inclusive time multiplies by loops, and nil or zero loops count as one")
  func loopsMultiplyInclusiveTime() throws {
    let analyzed = try analyze(
      """
      {"Plan":{"Node Type":"Result","Actual Total Time":1,"Actual Loops":1,"Plans":[
        {"Node Type":"A","Actual Total Time":2},
        {"Node Type":"B","Actual Total Time":2,"Actual Loops":0},
        {"Node Type":"C","Actual Total Time":2,"Actual Loops":4}
      ]}}
      """
    )
    #expect(analyzed.nodes[1].inclusive == 2)
    #expect(analyzed.nodes[2].inclusive == 2)
    #expect(analyzed.nodes[3].inclusive == 8)

    let plan = try ExplainPlan.parse(.json(ExplainFixtures.nestedLoop))
    let fixture = ExplainPlanAnalyzer.analyze(plan)
    let innerPlan = plan.root.children[1]
    let inner = fixture.nodes[2]
    #expect(inner.node.parentRelationship == "Inner")
    #expect(inner.inclusive == innerPlan.actualTotalTime! * innerPlan.actualLoops!)
    #expect(inner.actualRowsTimesLoops == innerPlan.actualRows! * innerPlan.actualLoops!)
    #expect(inner.misestimateDirection == .under)
    #expect(!fixture.nodes[0].warnings.contains(.nestedLoop))
  }

  @Test("Parallel time divides by workers launched plus one and sets the caveat")
  func parallelDivisionUsesLaunchedWorkers() throws {
    let analyzed = try analyze(
      """
      {"Plan":{"Node Type":"Append","Actual Total Time":20,"Actual Loops":1,"Plans":[
        {"Node Type":"Seq Scan","Parent Relationship":"Member","Actual Total Time":9,"Actual Loops":1,"Workers Launched":2},
        {"Node Type":"Index Scan","Parent Relationship":"Member","Actual Total Time":9,"Actual Loops":1,"Workers Planned":2}
      ]}}
      """
    )
    #expect(analyzed.nodes[1].inclusive == 3)
    #expect(analyzed.nodes[1].parallelCaveat)
    #expect(analyzed.nodes[2].inclusive == 9)
    #expect(!analyzed.nodes[2].parallelCaveat)
    #expect(analyzed.nodes[0].exclusive == 8)

    let launchedZero = try analyze(
      """
      {"Plan":{"Node Type":"Seq Scan","Actual Total Time":4,"Actual Loops":1,"Workers Launched":0}}
      """
    )
    #expect(launchedZero.nodes[0].inclusive == 4)
    #expect(launchedZero.nodes[0].parallelCaveat)

    let plan = try ExplainPlan.parse(.json(ExplainFixtures.parallelGather))
    let fixture = ExplainPlanAnalyzer.analyze(plan)
    let gather = fixture.nodes[0]
    let scan = fixture.nodes[1]
    let launched = Double(plan.root.workersLaunched! + 1)
    #expect(gather.parallelCaveat)
    #expect(gather.inclusive == plan.root.actualTotalTime! * plan.root.actualLoops! / launched)
    #expect(!scan.parallelCaveat)
    #expect(scan.node.workersLaunched == nil)
    #expect(scan.inclusive == scan.node.actualTotalTime! * scan.node.actualLoops!)
    #expect(scan.inclusive > gather.inclusive)
    #expect(gather.exclusive == 0)
  }

  @Test("An estimate-only plan uses total cost and does not multiply by loops")
  func estimateOnlyFixtureUsesCost() throws {
    let plan = try ExplainPlan.parse(.json(ExplainFixtures.seqScan))
    let analyzed = ExplainPlanAnalyzer.analyze(plan)
    let root = analyzed.nodes[0]
    #expect(plan.root.actualTotalTime == nil)
    #expect(root.inclusive == plan.root.totalCost)
    #expect(root.exclusive == plan.root.totalCost)
    #expect(root.share == 1)
    #expect(root.estimatedRows == 1270)
    #expect(root.actualRowsTimesLoops == nil)
    #expect(root.misestimateFactor == nil)
    #expect(root.misestimateDirection == nil)
    #expect(root.buffersExclusive == nil)
    #expect(!root.parallelCaveat)
    #expect(root.warnings.isEmpty)
    #expect(analyzed.hotNodes.count == 1)

    let cost = try analyze(
      """
      {"Plan":{"Node Type":"Nested Loop","Total Cost":10,"Actual Loops":100,"Plans":[
        {"Node Type":"Seq Scan","Total Cost":3,"Actual Loops":50}
      ]}}
      """
    )
    #expect(cost.nodes[0].inclusive == 10)
    #expect(cost.nodes[1].inclusive == 3)
    #expect(cost.nodes[0].exclusive == 7)
    #expect(!cost.nodes[0].parallelCaveat)

    let zero = try analyze(
      """
      {"Plan":{"Node Type":"Result","Total Cost":0}}
      """
    )
    #expect(zero.nodes[0].inclusive == 0)
    #expect(zero.nodes[0].share == 0)
  }

  @Test("A timed tree counts a child with no actual time as zero")
  func missingActualTimeCountsAsZero() throws {
    let analyzed = try analyze(
      """
      {"Plan":{"Node Type":"Result","Actual Total Time":8,"Actual Loops":1,"Total Cost":1,"Plans":[
        {"Node Type":"Seq Scan","Total Cost":100}
      ]}}
      """
    )
    #expect(analyzed.nodes[0].inclusive == 8)
    #expect(analyzed.nodes[0].exclusive == 8)
    #expect(analyzed.nodes[1].inclusive == 0)
    #expect(analyzed.nodes[1].exclusive == 0)
  }

  @Test("Hot nodes are the five largest exclusive values, stable in preorder")
  func hotNodesKeepPreorderOnTies() throws {
    let analyzed = try analyze(
      """
      {"Plan":{"Node Type":"Append","Actual Total Time":1000,"Actual Loops":1,"Plans":[
        {"Node Type":"A","Actual Total Time":10,"Actual Loops":1},
        {"Node Type":"B","Actual Total Time":50,"Actual Loops":1},
        {"Node Type":"C","Actual Total Time":50,"Actual Loops":1},
        {"Node Type":"D","Actual Total Time":40,"Actual Loops":1},
        {"Node Type":"E","Actual Total Time":30,"Actual Loops":1},
        {"Node Type":"F","Actual Total Time":20,"Actual Loops":1},
        {"Node Type":"G","Actual Total Time":5,"Actual Loops":1}
      ]}}
      """
    )
    #expect(
      analyzed.nodes.map(\.node.nodeType) == ["Append", "A", "B", "C", "D", "E", "F", "G"]
    )
    #expect(analyzed.hotNodes.map(\.node.nodeType) == ["Append", "B", "C", "D", "E"])
    #expect(analyzed.hotNodes.map(\.exclusive) == [795, 50, 50, 40, 30])
  }

  @Test("InitPlan, SubPlan, and CTE Scan children are not subtracted")
  func excludedChildrenAreNotSubtracted() throws {
    let analyzed = try analyze(
      """
      {"Plan":{"Node Type":"Result","Actual Total Time":100,"Actual Loops":1,"Plans":[
        {"Node Type":"Seq Scan","Parent Relationship":"Outer","Actual Total Time":10,"Actual Loops":1},
        {"Node Type":"Result","Parent Relationship":"InitPlan","Actual Total Time":40,"Actual Loops":1},
        {"Node Type":"Result","Parent Relationship":"SubPlan","Actual Total Time":30,"Actual Loops":1},
        {"Node Type":"CTE Scan","Parent Relationship":"Outer","Actual Total Time":20,"Actual Loops":1}
      ]}}
      """
    )
    #expect(analyzed.nodes.count == 5)
    #expect(analyzed.nodes[0].exclusive == 90)
    #expect(analyzed.nodes[1].inclusive == 10)
    #expect(analyzed.nodes[2].node.parentRelationship == "InitPlan")
    #expect(analyzed.nodes[2].inclusive == 40)
    #expect(analyzed.nodes[3].node.parentRelationship == "SubPlan")
    #expect(analyzed.nodes[3].inclusive == 30)
    #expect(analyzed.nodes[4].node.nodeType == "CTE Scan")
    #expect(analyzed.nodes[4].inclusive == 20)

    let plan = try ExplainPlan.parse(.json(ExplainFixtures.cte))
    let fixture = ExplainPlanAnalyzer.analyze(plan)
    #expect(plan.root.actualTotalTime == nil)
    #expect(fixture.nodes[0].inclusive == plan.root.totalCost)
    #expect(fixture.nodes[0].exclusive == plan.root.totalCost)
    #expect(fixture.nodes[1].node.parentRelationship == "InitPlan")
    #expect(fixture.nodes[1].inclusive == plan.root.children[0].totalCost)
    #expect(fixture.nodes[1].exclusive == 0)
    #expect(!fixture.nodes[1].parallelCaveat)
    #expect(fixture.nodes[1].node.workersPlanned == 2)
    #expect(fixture.nodes[1].node.workersLaunched == nil)
    #expect(fixture.nodes[2].inclusive == plan.root.children[0].children[0].totalCost)
  }

  @Test("Exclusive buffers subtract included children and floor at zero")
  func buffersExclusiveSubtractIncludedChildren() throws {
    let analyzed = try analyze(
      """
      {"Plan":{"Node Type":"Hash Join","Actual Total Time":1,"Actual Loops":1,
        "Shared Hit Blocks":100,"Shared Read Blocks":40,"Shared Dirtied Blocks":10,"Shared Written Blocks":4,
        "Plans":[
          {"Node Type":"Seq Scan","Parent Relationship":"Outer","Actual Total Time":1,"Actual Loops":1,
            "Shared Hit Blocks":30,"Shared Read Blocks":50,"Shared Dirtied Blocks":1,"Shared Written Blocks":0},
          {"Node Type":"Hash","Parent Relationship":"InitPlan","Actual Total Time":1,"Actual Loops":1,
            "Shared Hit Blocks":1000,"Shared Read Blocks":1000,"Shared Dirtied Blocks":1000,"Shared Written Blocks":1000},
          {"Node Type":"CTE Scan","Parent Relationship":"Outer","Actual Total Time":1,"Actual Loops":1,
            "Shared Hit Blocks":7,"Shared Read Blocks":7,"Shared Dirtied Blocks":7,"Shared Written Blocks":7}
        ]}}
      """
    )
    #expect(
      analyzed.nodes[0].buffersExclusive
        == ExplainBuffers(sharedHit: 70, sharedRead: 0, sharedDirtied: 9, sharedWritten: 4)
    )

    let partial = try analyze(
      """
      {"Plan":{"Node Type":"Seq Scan","Actual Total Time":1,"Actual Loops":1,"Shared Hit Blocks":5}}
      """
    )
    #expect(
      partial.nodes[0].buffersExclusive
        == ExplainBuffers(sharedHit: 5, sharedRead: 0, sharedDirtied: 0, sharedWritten: 0)
    )

    let absent = try analyze(
      """
      {"Plan":{"Node Type":"Result","Actual Total Time":1,"Actual Loops":1}}
      """
    )
    #expect(absent.nodes[0].buffersExclusive == nil)

    let plan = try ExplainPlan.parse(.json(ExplainFixtures.hashJoin))
    let fixture = ExplainPlanAnalyzer.analyze(plan)
    let zeros = ExplainBuffers(sharedHit: 0, sharedRead: 0, sharedDirtied: 0, sharedWritten: 0)
    #expect(fixture.nodes[0].buffersExclusive == zeros)
    #expect(
      fixture.nodes.map(\.node.nodeType) == ["Hash Join", "Values Scan", "Hash", "Values Scan"])
    let root = fixture.nodes[0]
    let outer = fixture.nodes[1]
    let hash = fixture.nodes[2]
    #expect(root.inclusive == plan.root.actualTotalTime! * plan.root.actualLoops!)
    #expect(root.exclusive == root.inclusive - outer.inclusive - hash.inclusive)
  }

  @Test("Disk sort warns only when sort space type is Disk")
  func diskSortWarning() throws {
    let disk = try analyze(
      """
      {"Plan":{"Node Type":"Sort","Sort Space Type":"disk","Actual Total Time":1,"Actual Loops":1}}
      """
    )
    #expect(disk.nodes[0].warnings.contains(.diskSort))

    let memory = try analyze(
      """
      {"Plan":{"Node Type":"Sort","Sort Space Type":"Memory","Actual Total Time":1,"Actual Loops":1}}
      """
    )
    #expect(!memory.nodes[0].warnings.contains(.diskSort))
  }

  @Test("Misestimate uses actual rows times loops, direction, and a factor of at least 10")
  func misestimateWarningAndDirection() throws {
    let under = try analyze(
      """
      {"Plan":{"Node Type":"Seq Scan","Plan Rows":1,"Actual Rows":10,"Actual Loops":1,"Actual Total Time":1}}
      """
    )
    #expect(under.nodes[0].actualRowsTimesLoops == 10)
    #expect(under.nodes[0].misestimateFactor == 10)
    #expect(under.nodes[0].misestimateDirection == .under)
    #expect(under.nodes[0].warnings.contains(.misestimate))

    let over = try analyze(
      """
      {"Plan":{"Node Type":"Seq Scan","Plan Rows":100,"Actual Rows":10,"Actual Loops":1,"Actual Total Time":1}}
      """
    )
    #expect(over.nodes[0].misestimateFactor == 10)
    #expect(over.nodes[0].misestimateDirection == .over)
    #expect(over.nodes[0].warnings.contains(.misestimate))

    let below = try analyze(
      """
      {"Plan":{"Node Type":"Seq Scan","Plan Rows":10,"Actual Rows":50,"Actual Loops":1,"Actual Total Time":1}}
      """
    )
    #expect(below.nodes[0].misestimateFactor == 5)
    #expect(below.nodes[0].misestimateDirection == .under)
    #expect(!below.nodes[0].warnings.contains(.misestimate))

    let equal = try analyze(
      """
      {"Plan":{"Node Type":"Seq Scan","Plan Rows":8,"Actual Rows":2,"Actual Loops":4,"Actual Total Time":1}}
      """
    )
    #expect(equal.nodes[0].actualRowsTimesLoops == 8)
    #expect(equal.nodes[0].misestimateFactor == 1)
    #expect(equal.nodes[0].misestimateDirection == nil)
    #expect(!equal.nodes[0].warnings.contains(.misestimate))

    let zeroActual = try analyze(
      """
      {"Plan":{"Node Type":"Seq Scan","Plan Rows":10,"Actual Rows":0,"Actual Loops":1,"Actual Total Time":1}}
      """
    )
    #expect(zeroActual.nodes[0].actualRowsTimesLoops == 0)
    #expect(zeroActual.nodes[0].misestimateFactor == nil)
    #expect(zeroActual.nodes[0].misestimateDirection == nil)
    #expect(!zeroActual.nodes[0].warnings.contains(.misestimate))

    let missing = try analyze(
      """
      {"Plan":{"Node Type":"Seq Scan","Plan Rows":10,"Total Cost":1}}
      """
    )
    #expect(missing.nodes[0].actualRowsTimesLoops == nil)
    #expect(missing.nodes[0].misestimateFactor == nil)
    #expect(!missing.nodes[0].warnings.contains(.misestimate))
  }

  @Test("Seq scan filter warns only for a large mostly-filtered scan")
  func seqScanFilterWarning() throws {
    let hit = try analyze(
      """
      {"Plan":{"Node Type":"Seq Scan","Rows Removed by Filter":10000,"Actual Rows":100,"Actual Loops":1,"Actual Total Time":1}}
      """
    )
    #expect(hit.nodes[0].warnings.contains(.seqScanFilter))

    let tooFew = try analyze(
      """
      {"Plan":{"Node Type":"Seq Scan","Rows Removed by Filter":9999,"Actual Rows":1,"Actual Loops":1,"Actual Total Time":1}}
      """
    )
    #expect(!tooFew.nodes[0].warnings.contains(.seqScanFilter))

    let atBoundary = try analyze(
      """
      {"Plan":{"Node Type":"Seq Scan","Rows Removed by Filter":18000,"Actual Rows":2000,"Actual Loops":1,"Actual Total Time":1}}
      """
    )
    #expect(!atBoundary.nodes[0].warnings.contains(.seqScanFilter))

    let missingRows = try analyze(
      """
      {"Plan":{"Node Type":"Seq Scan","Rows Removed by Filter":100000,"Total Cost":1}}
      """
    )
    #expect(!missingRows.nodes[0].warnings.contains(.seqScanFilter))

    let indexScan = try analyze(
      """
      {"Plan":{"Node Type":"Index Scan","Rows Removed by Filter":10000,"Actual Rows":100,"Actual Loops":1,"Actual Total Time":1}}
      """
    )
    #expect(!indexScan.nodes[0].warnings.contains(.seqScanFilter))
  }

  @Test("Nested loop warns when this node or a direct child loops at least 1000 times")
  func nestedLoopWarning() throws {
    let childLoops = try analyze(
      """
      {"Plan":{"Node Type":"Nested Loop","Actual Loops":1,"Actual Total Time":1,"Plans":[
        {"Node Type":"Seq Scan","Actual Loops":1000,"Actual Total Time":1}
      ]}}
      """
    )
    #expect(childLoops.nodes[0].warnings.contains(.nestedLoop))
    #expect(!childLoops.nodes[1].warnings.contains(.nestedLoop))

    let selfLoops = try analyze(
      """
      {"Plan":{"Node Type":"Nested Loop","Actual Loops":1000,"Actual Total Time":1,"Plans":[
        {"Node Type":"Seq Scan","Actual Loops":1,"Actual Total Time":1}
      ]}}
      """
    )
    #expect(selfLoops.nodes[0].warnings.contains(.nestedLoop))

    let below = try analyze(
      """
      {"Plan":{"Node Type":"Nested Loop","Actual Loops":999,"Actual Total Time":1,"Plans":[
        {"Node Type":"Seq Scan","Actual Loops":999,"Actual Total Time":1}
      ]}}
      """
    )
    #expect(!below.nodes[0].warnings.contains(.nestedLoop))

    let otherJoin = try analyze(
      """
      {"Plan":{"Node Type":"Hash Join","Actual Loops":1,"Actual Total Time":1,"Plans":[
        {"Node Type":"Seq Scan","Actual Loops":5000,"Actual Total Time":1}
      ]}}
      """
    )
    #expect(!otherJoin.nodes[0].warnings.contains(.nestedLoop))

    let grandchild = try analyze(
      """
      {"Plan":{"Node Type":"Nested Loop","Actual Loops":1,"Actual Total Time":1,"Plans":[
        {"Node Type":"Result","Actual Loops":1,"Actual Total Time":1,"Plans":[
          {"Node Type":"Seq Scan","Actual Loops":1000,"Actual Total Time":1}
        ]}
      ]}}
      """
    )
    #expect(!grandchild.nodes[0].warnings.contains(.nestedLoop))
  }
}

private func analyze(_ json: String) throws -> AnalyzedPlan {
  try ExplainPlanAnalyzer.analyze(ExplainPlan.parse(.json(json)))
}
