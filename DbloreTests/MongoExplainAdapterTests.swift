// MongoExplainAdapterTests.swift
// MongoDB explain output maps onto the plan tree: stage chain, actual rows and times, index
// names and the summary from MongoDB 8.0 captures (trimmed), and an EXPLAIN column opens the
// plan only for MySQL or MongoDB output.

import Foundation
import Testing

@testable import Dblore

struct MongoExplainAdapterTests {
  private func plan(_ text: String) throws -> ExplainPlan {
    try #require(MongoExplainAdapter.plan(fromJSON: text))
  }

  private func explainCell(_ text: String) -> CellResult {
    CellResult(
      columns: [ColumnInfo(name: "EXPLAIN", type: "JSON")], rows: [[.json(text)]], rowCount: 1)
  }

  @Test("A find with executionStats is SORT over FETCH over IXSCAN, with rows, times and index")
  func findIndexScan() throws {
    let root = try plan(Self.findIxscan).root
    #expect(root.nodeType == "SORT")
    #expect(root.actualRows == 5)
    #expect(root.actualTotalTime == 0)
    #expect(root.extras["sortPattern"] == .object(["b": .number(1)]))
    #expect(root.extras["inputStage"] == nil)
    let fetch = try #require(root.children.first)
    #expect(root.children.count == 1)
    #expect(fetch.nodeType == "FETCH")
    #expect(fetch.actualRows == 10)
    #expect(fetch.extras["docsExamined"] == .number(10))
    let scan = try #require(fetch.children.first)
    #expect(fetch.children.count == 1)
    #expect(scan.nodeType == "IXSCAN")
    #expect(scan.indexName == "a_1")
    #expect(scan.actualRows == 10)
    #expect(scan.actualTotalTime == 0)
    #expect(scan.extras["keysExamined"] == .number(10))
    #expect(scan.children.isEmpty)

    let summary = try #require(MongoExplainAdapter.summary(fromJSON: Self.findIxscan))
    #expect(summary.executionTimeMillis == 3)
    #expect(summary.nReturned == 5)
    #expect(summary.totalDocsExamined == 10)
    #expect(summary.totalKeysExamined == 10)
    #expect(summary.indexNames == ["a_1"])
    #expect(summary.usesCollectionScan == false)
    // No loops in MongoDB output: the analyzer shows the actual rows as they are.
    #expect(
      ExplainPlanAnalyzer.analyze(try plan(Self.findIxscan)).nodes[0].actualRowsTimesLoops == 5)
  }

  @Test("An aggregate puts its later pipeline stages above the plan of its cursor stage")
  func aggregateStages() throws {
    let root = try plan(Self.aggGroup).root
    #expect(root.nodeType == "$sort")
    #expect(root.actualRows == 17)
    #expect(root.actualTotalTime == 1)
    #expect(root.extras["$sort"] == .object(["sortKey": .object(["n": .number(-1)])]))
    let cursor = try #require(root.children.first)
    #expect(root.children.count == 1)
    // explainVersion 2 runs the cursor stage on the slot-based engine: the tree is its
    // classic-shaped query plan, not the internal execution stages. Only its root has actual
    // rows and time, from the cursor stage's totals.
    var chain: [String?] = []
    var node: ExplainNode? = cursor
    while let current = node {
      chain.append(current.nodeType)
      node = current.children.first
    }
    #expect(chain == ["GROUP", "PROJECTION_COVERED", "IXSCAN"])
    #expect(cursor.actualRows == 17)
    #expect(cursor.actualTotalTime == 1)
    #expect(cursor.extras["planNodeId"] == .number(3))
    let projection = try #require(cursor.children.first)
    #expect(projection.extras["transformBy"] == .object(["a": .bool(true), "_id": .bool(false)]))
    let scan = try #require(projection.children.first)
    #expect(scan.indexName == "a_1")
    #expect(scan.actualRows == nil)
    #expect(scan.extras["indexBounds"] == .object(["a": .array([.string("(2, inf.0]")])]))

    let summary = try #require(MongoExplainAdapter.summary(fromJSON: Self.aggGroup))
    #expect(summary.executionTimeMillis == 4)
    #expect(summary.nReturned == 17)
    #expect(summary.totalKeysExamined == 170)
    #expect(summary.totalDocsExamined == 0)
    #expect(summary.indexNames == ["a_1"])
    #expect(summary.usesCollectionScan == false)
    // The cursor time sits on the cursor stage, so `$sort` keeps none of it.
    let analyzed = ExplainPlanAnalyzer.analyze(try plan(Self.aggGroup))
    #expect(
      analyzed.nodes.map(\.node.nodeType) == ["$sort", "GROUP", "PROJECTION_COVERED", "IXSCAN"])
    #expect(analyzed.nodes[0].share == 0)
    #expect(analyzed.nodes[1].share == 1)
  }

  @Test("An EXPLAIN column opens MySQL or MongoDB plans only; a sharded reply stays raw")
  func detection() throws {
    let mysql = explainCell(#"{"query_block": {"select_id": 1}}"#)
    #expect(ExplainResultPlan.parse(mysql)?.root.nodeType == "Result")
    let mongo = try #require(ExplainResultPlan.parse(explainCell(Self.findIxscan)))
    #expect(mongo == MongoExplainAdapter.plan(fromJSON: Self.findIxscan))
    #expect(ExplainResultPlan.parse(explainCell(#"{"stage": "SORT", "ok": 1}"#)) == nil)
    for sharded in [Self.shardedAggregate, Self.mongosFind] {
      #expect(ExplainResultPlan.parse(explainCell(sharded)) == nil)
      #expect(MongoExplainAdapter.plan(fromJSON: sharded) == nil)
      #expect(MongoExplainAdapter.summary(fromJSON: sharded) == nil)
    }
    #expect(MongoExplainAdapter.summary(fromJSON: #"{"query_block": {}}"#) == nil)
  }

  // MARK: - Fixtures (MongoDB 8.0, trimmed)

  private static let findIxscan = #"""
    {
      "explainVersion": "1",
      "queryPlanner": {
        "namespace": "qa_explain_probe.c",
        "winningPlan": {
          "stage": "SORT",
          "sortPattern": {"b": 1},
          "inputStage": {
            "stage": "FETCH",
            "inputStage": {"stage": "IXSCAN", "keyPattern": {"a": 1}, "indexName": "a_1"}
          }
        }
      },
      "executionStats": {
        "executionSuccess": true,
        "nReturned": 5,
        "executionTimeMillis": 3,
        "totalKeysExamined": 10,
        "totalDocsExamined": 10,
        "executionStages": {
          "stage": "SORT",
          "nReturned": 5,
          "executionTimeMillisEstimate": 0,
          "works": 17,
          "sortPattern": {"b": 1},
          "inputStage": {
            "stage": "FETCH",
            "nReturned": 10,
            "executionTimeMillisEstimate": 0,
            "docsExamined": 10,
            "inputStage": {
              "stage": "IXSCAN",
              "nReturned": 10,
              "executionTimeMillisEstimate": 0,
              "keyPattern": {"a": 1},
              "indexName": "a_1",
              "indexBounds": {"a": ["[3, 3]"]},
              "keysExamined": 10
            }
          }
        }
      },
      "ok": 1
    }
    """#

  /// A find through mongos: the shard plans sit under `shards` of the winning plan.
  private static let mongosFind = #"""
    {
      "queryPlanner": {
        "mongosPlannerVersion": 1,
        "winningPlan": {
          "stage": "SINGLE_SHARD",
          "shards": [
            {
              "shardName": "shard-a",
              "explainVersion": "1",
              "namespace": "qa_explain_probe.c",
              "winningPlan": {"stage": "COLLSCAN", "direction": "forward"}
            }
          ]
        }
      },
      "executionStats": {
        "nReturned": 3,
        "executionTimeMillis": 1,
        "totalKeysExamined": 0,
        "totalDocsExamined": 40,
        "executionStages": {
          "stage": "SINGLE_SHARD",
          "nReturned": 3,
          "executionTimeMillis": 1,
          "shards": [
            {
              "shardName": "shard-a",
              "executionSuccess": true,
              "executionStages": {"stage": "COLLSCAN", "nReturned": 3, "docsExamined": 40}
            }
          ]
        }
      },
      "ok": 1
    }
    """#

  /// An aggregate through mongos: one explain reply per shard under top-level `shards`.
  private static let shardedAggregate = #"""
    {
      "mergeType": "mongos",
      "splitPipeline": {
        "shardsPart": [{"$match": {"a": {"$gt": 2}}}],
        "mergerPart": [{"$mergeCursors": {}}]
      },
      "shards": {
        "shard-a": {
          "host": "shard-a:27018",
          "stages": [
            {"$cursor": {"queryPlanner": {"winningPlan": {"stage": "COLLSCAN"}}}}
          ]
        }
      },
      "ok": 1
    }
    """#

  private static let aggGroup = #"""
    {
      "explainVersion": "2",
      "stages": [
        {
          "$cursor": {
            "queryPlanner": {
              "namespace": "qa_explain_probe.c",
              "winningPlan": {
                "isCached": false,
                "queryPlan": {
                  "stage": "GROUP",
                  "planNodeId": 3,
                  "inputStage": {
                    "stage": "PROJECTION_COVERED",
                    "planNodeId": 2,
                    "transformBy": {"a": true, "_id": false},
                    "inputStage": {
                      "stage": "IXSCAN",
                      "planNodeId": 1,
                      "keyPattern": {"a": 1},
                      "indexName": "a_1",
                      "direction": "forward",
                      "indexBounds": {"a": ["(2, inf.0]"]}
                    }
                  }
                },
                "slotBasedPlan": {"slots": "$$RESULT=s7 env: {  }"}
              }
            },
            "executionStats": {
              "executionSuccess": true,
              "nReturned": 17,
              "executionTimeMillis": 4,
              "totalKeysExamined": 170,
              "totalDocsExamined": 0,
              "executionStages": {
                "stage": "project",
                "nReturned": 17,
                "executionTimeMillisEstimate": 0,
                "inputStage": {
                  "stage": "group",
                  "nReturned": 17,
                  "executionTimeMillisEstimate": 0,
                  "inputStage": {
                    "stage": "ixseek",
                    "nReturned": 170,
                    "executionTimeMillisEstimate": 0,
                    "indexName": "a_1",
                    "keysExamined": 170
                  }
                }
              }
            }
          },
          "nReturned": 17,
          "executionTimeMillisEstimate": 1
        },
        {
          "$sort": {"sortKey": {"n": -1}},
          "usedDisk": false,
          "nReturned": 17,
          "executionTimeMillisEstimate": 1
        }
      ],
      "ok": 1
    }
    """#
}
