// ExplainPlanDecodingTests.swift
// PostgreSQL EXPLAIN JSON decodes into an ExplainPlan tree.

import Foundation
import Testing

@testable import Dblore

@Suite("EXPLAIN plan decoding")
struct ExplainPlanDecodingTests {
  @Test("Seq scan estimate exposes Seq Scan and no execution time")
  func seqScanEstimate() throws {
    let plan = try ExplainPlan.parse(.json(ExplainFixtures.seqScan))
    #expect(plan.root.nodeType == "Seq Scan")
    #expect(plan.root.relationName == "dblore_explain_seq")
    #expect(plan.executionTime == nil)
    #expect(plan.planningTime == nil)
    #expect(plan.triggers.isEmpty)
    #expect(plan.root.actualRows == nil)
    let asString = try ExplainPlan.parse(.string(ExplainFixtures.seqScan))
    #expect(asString == plan)
  }

  @Test("Hash join analyze exposes Hash Join and shared buffer counts")
  func hashJoinAnalyze() throws {
    let plan = try ExplainPlan.parse(.json(ExplainFixtures.hashJoin))
    #expect(plan.root.nodeType == "Hash Join")
    #expect(plan.root.joinType == "Inner")
    #expect(plan.root.hashCond != nil)
    #expect(plan.root.sharedHitBlocks == 0)
    #expect(plan.executionTime != nil)
    #expect(plan.planningTime != nil)
    #expect(plan.triggers.isEmpty)
    let hash = plan.root.children.first { $0.nodeType == "Hash" }
    #expect(hash?.extras["Hash Batches"] == .number(1))
  }

  @Test("Nested loop inner node has actual loops greater than one")
  func nestedLoopLoops() throws {
    let plan = try ExplainPlan.parse(.json(ExplainFixtures.nestedLoop))
    #expect(plan.root.nodeType == "Nested Loop")
    let inner = plan.root.children.first { $0.parentRelationship == "Inner" }
    #expect((inner?.actualLoops ?? 0) > 1)
  }

  @Test("Parallel gather exposes workers planned and launched")
  func parallelGather() throws {
    let plan = try ExplainPlan.parse(.json(ExplainFixtures.parallelGather))
    #expect(plan.root.nodeType == "Gather")
    #expect(plan.root.workersPlanned == 2)
    #expect(plan.root.workersLaunched == 2)
  }

  @Test("CTE scan exposes an InitPlan child")
  func cteInitPlan() throws {
    let plan = try ExplainPlan.parse(.json(ExplainFixtures.cte))
    #expect(plan.root.nodeType == "CTE Scan")
    #expect(plan.root.filter == "(id > 0)")
    let initPlan = plan.root.children.first { $0.parentRelationship == "InitPlan" }
    #expect(initPlan?.nodeType == "Gather")
  }

  @Test("An unknown node key is kept in extras and modeled keys are not")
  func unknownKeyKeptInExtras() throws {
    let plan = try ExplainPlan.parse(.json(ExplainFixtures.seqScan))
    #expect(plan.root.extras["Parallel Aware"] == .bool(false))
    #expect(plan.root.extras["Async Capable"] == .bool(false))
    #expect(plan.root.extras["Node Type"] == nil)
    #expect(plan.root.extras["Relation Name"] == nil)
    #expect(plan.root.extras["Startup Cost"] == nil)

    let objectForm = """
      {"Plan":{"Node Type":"Result","Output":["id"],"Dblore Probe":"kept"}}
      """
    let objectPlan = try ExplainPlan.parse(.string(objectForm))
    #expect(objectPlan.root.nodeType == "Result")
    #expect(objectPlan.root.output == ["id"])
    #expect(objectPlan.root.extras["Dblore Probe"] == .string("kept"))
    #expect(objectPlan.root.extras["Output"] == nil)
    #expect(objectPlan.root.extras["Node Type"] == nil)

    let first = try ExplainPlan.parse(
      .json(
        """
        [{"Plan":{"Node Type":"Result"}},{"Plan":{"Node Type":"Seq Scan"}}]
        """
      )
    )
    #expect(first.root.nodeType == "Result")
  }

  @Test("A trigger keeps its name and ignores unknown keys")
  func triggerKeepsName() throws {
    let json = """
      [{"Plan":{"Node Type":"Result"},"Triggers":[{"Trigger Name":"t_row","Time":1.5,"Calls":2}]}]
      """
    let plan = try ExplainPlan.parse(.json(json))
    #expect(plan.triggers.count == 1)
    #expect(plan.triggers[0].name == "t_row")
    #expect(plan.triggers[0].time == 1.5)
  }

  @Test("Malformed JSON throws ExplainPlanError")
  func malformedThrows() {
    #expect(throws: ExplainPlanError.self) {
      try ExplainPlan.parse(.json("{not json"))
    }
    #expect(throws: ExplainPlanError.self) {
      try ExplainPlan.parse(.string("[]"))
    }
    #expect(throws: ExplainPlanError.self) {
      try ExplainPlan.parse(.json(#"{"Planning Time": 1.0}"#))
    }
  }

  @Test("A non-JSON cell value throws ExplainPlanError")
  func nonJSONThrows() {
    #expect(throws: ExplainPlanError.self) {
      try ExplainPlan.parse(.int(1))
    }
    #expect(throws: ExplainPlanError.self) {
      try ExplainPlan.parse(.null)
    }
  }
}
