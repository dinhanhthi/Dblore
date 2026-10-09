// ExplainPlanComparisonTests.swift
// EXPLAIN plan diff by tree path and node type.

import Foundation
import Testing

@testable import Dblore

@Suite("EXPLAIN plan comparison")
struct ExplainPlanComparisonTests {
  private func root(_ json: String) throws -> ExplainNode {
    try ExplainPlan.parse(.json(json)).root
  }

  @Test("Identical plans have no changes and zero root deltas")
  func identicalPlans() throws {
    let json = """
      {"Plan":{"Node Type":"Hash Join","Total Cost":100,"Actual Total Time":5,"Actual Rows":10,
        "Plans":[{"Node Type":"Seq Scan","Total Cost":40,"Actual Total Time":2,"Actual Rows":10}]}}
      """
    let diff = ExplainPlanComparison.compare(baseline: try root(json), current: try root(json))

    #expect(diff.hasChanges == false)
    #expect(diff.paired.count == 2)
    #expect(diff.added.isEmpty && diff.removed.isEmpty && diff.nodeTypeChanges.isEmpty)
    #expect(diff.rootTotalCostDelta == 0)
    #expect(diff.rootActualTotalTimeDelta == 0)
  }

  @Test("A changed node type at a path is flagged, and children still pair by path")
  func nodeTypeChanged() throws {
    let baseline = try root(
      """
      {"Plan":{"Node Type":"Hash Join","Total Cost":100,
        "Plans":[{"Node Type":"Seq Scan","Total Cost":40},{"Node Type":"Seq Scan","Total Cost":30}]}}
      """)
    let current = try root(
      """
      {"Plan":{"Node Type":"Hash Join","Total Cost":60,
        "Plans":[{"Node Type":"Seq Scan","Total Cost":40},{"Node Type":"Index Scan","Total Cost":5}]}}
      """)

    let diff = ExplainPlanComparison.compare(baseline: baseline, current: current)

    #expect(
      diff.nodeTypeChanges == [
        ExplainPlanDiff.NodeTypeChange(
          path: [1], baselineNodeType: "Seq Scan", currentNodeType: "Index Scan")
      ])
    #expect(diff.removed.map(\.path) == [[1]])
    #expect(diff.added.map(\.path) == [[1]])
    #expect(diff.paired.map(\.path) == [[], [0]])
    #expect(diff.hasChanges)
  }

  @Test("A subtree only in the current plan lists every node as added")
  func subtreeAdded() throws {
    let baseline = try root(
      """
      {"Plan":{"Node Type":"Append","Plans":[{"Node Type":"Seq Scan","Relation Name":"a"}]}}
      """)
    let current = try root(
      """
      {"Plan":{"Node Type":"Append","Plans":[
        {"Node Type":"Seq Scan","Relation Name":"a"},
        {"Node Type":"Hash","Plans":[{"Node Type":"Seq Scan","Relation Name":"b"}]}
      ]}}
      """)

    let diff = ExplainPlanComparison.compare(baseline: baseline, current: current)

    #expect(diff.added.map(\.path) == [[1], [1, 0]])
    #expect(diff.added.map(\.nodeType) == ["Hash", "Seq Scan"])
    #expect(diff.added.last?.relationName == "b")
    #expect(diff.removed.isEmpty)
    #expect(diff.nodeTypeChanges.isEmpty)

    let reversed = ExplainPlanComparison.compare(baseline: current, current: baseline)
    #expect(reversed.removed.map(\.path) == [[1], [1, 0]])
    #expect(reversed.added.isEmpty)
  }

  @Test("Paired node deltas are current minus baseline")
  func deltaValues() throws {
    let baseline = try root(
      """
      {"Plan":{"Node Type":"Seq Scan","Total Cost":100.5,"Actual Total Time":12,"Actual Rows":50}}
      """)
    let current = try root(
      """
      {"Plan":{"Node Type":"Seq Scan","Total Cost":80.5,"Actual Total Time":15,"Actual Rows":20}}
      """)

    let diff = ExplainPlanComparison.compare(baseline: baseline, current: current)

    let node = try #require(diff.paired.first)
    #expect(node.totalCostDelta == -20)
    #expect(node.actualTotalTimeDelta == 3)
    #expect(node.actualRowsDelta == -30)
    #expect(diff.rootTotalCostDelta == -20)
    #expect(diff.rootActualTotalTimeDelta == 3)
    #expect(diff.hasChanges)
  }

  @Test("Plain EXPLAIN without ANALYZE gives nil time and row deltas")
  func missingActuals() throws {
    let baseline = try root(#"{"Plan":{"Node Type":"Seq Scan","Total Cost":10,"Plan Rows":5}}"#)
    let current = try root(#"{"Plan":{"Node Type":"Seq Scan","Total Cost":12,"Plan Rows":5}}"#)

    let diff = ExplainPlanComparison.compare(baseline: baseline, current: current)

    let node = try #require(diff.paired.first)
    #expect(node.totalCostDelta == 2)
    #expect(node.actualTotalTimeDelta == nil)
    #expect(node.actualRowsDelta == nil)
    #expect(diff.rootActualTotalTimeDelta == nil)
    #expect(diff.rootTotalCostDelta == 2)
  }
}
