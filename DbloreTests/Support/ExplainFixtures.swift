// ExplainFixtures.swift
// Raw EXPLAIN (FORMAT JSON) text captured from PostgreSQL 16.

import Foundation

enum ExplainFixtures {
  static let seqScan = #"""
    [
      {
        "Plan": {
          "Node Type": "Seq Scan",
          "Parallel Aware": false,
          "Async Capable": false,
          "Relation Name": "dblore_explain_seq",
          "Alias": "dblore_explain_seq",
          "Startup Cost": 0.00,
          "Total Cost": 22.70,
          "Plan Rows": 1270,
          "Plan Width": 36
        }
      }
    ]
    """#
  static let hashJoin = #"""
    [
      {
        "Plan": {
          "Node Type": "Hash Join",
          "Parallel Aware": false,
          "Async Capable": false,
          "Join Type": "Inner",
          "Startup Cost": 0.10,
          "Total Cost": 0.21,
          "Plan Rows": 4,
          "Plan Width": 8,
          "Actual Startup Time": 0.015,
          "Actual Total Time": 0.016,
          "Actual Rows": 4,
          "Actual Loops": 1,
          "Inner Unique": false,
          "Hash Cond": "(\"*VALUES*\".column1 = \"*VALUES*_1\".column1)",
          "Shared Hit Blocks": 0,
          "Shared Read Blocks": 0,
          "Shared Dirtied Blocks": 0,
          "Shared Written Blocks": 0,
          "Local Hit Blocks": 0,
          "Local Read Blocks": 0,
          "Local Dirtied Blocks": 0,
          "Local Written Blocks": 0,
          "Temp Read Blocks": 0,
          "Temp Written Blocks": 0,
          "Plans": [
            {
              "Node Type": "Values Scan",
              "Parent Relationship": "Outer",
              "Parallel Aware": false,
              "Async Capable": false,
              "Alias": "*VALUES*",
              "Startup Cost": 0.00,
              "Total Cost": 0.05,
              "Plan Rows": 4,
              "Plan Width": 4,
              "Actual Startup Time": 0.001,
              "Actual Total Time": 0.001,
              "Actual Rows": 4,
              "Actual Loops": 1,
              "Shared Hit Blocks": 0,
              "Shared Read Blocks": 0,
              "Shared Dirtied Blocks": 0,
              "Shared Written Blocks": 0,
              "Local Hit Blocks": 0,
              "Local Read Blocks": 0,
              "Local Dirtied Blocks": 0,
              "Local Written Blocks": 0,
              "Temp Read Blocks": 0,
              "Temp Written Blocks": 0
            },
            {
              "Node Type": "Hash",
              "Parent Relationship": "Inner",
              "Parallel Aware": false,
              "Async Capable": false,
              "Startup Cost": 0.05,
              "Total Cost": 0.05,
              "Plan Rows": 4,
              "Plan Width": 4,
              "Actual Startup Time": 0.004,
              "Actual Total Time": 0.004,
              "Actual Rows": 4,
              "Actual Loops": 1,
              "Hash Buckets": 1024,
              "Original Hash Buckets": 1024,
              "Hash Batches": 1,
              "Original Hash Batches": 1,
              "Peak Memory Usage": 9,
              "Shared Hit Blocks": 0,
              "Shared Read Blocks": 0,
              "Shared Dirtied Blocks": 0,
              "Shared Written Blocks": 0,
              "Local Hit Blocks": 0,
              "Local Read Blocks": 0,
              "Local Dirtied Blocks": 0,
              "Local Written Blocks": 0,
              "Temp Read Blocks": 0,
              "Temp Written Blocks": 0,
              "Plans": [
                {
                  "Node Type": "Values Scan",
                  "Parent Relationship": "Outer",
                  "Parallel Aware": false,
                  "Async Capable": false,
                  "Alias": "*VALUES*_1",
                  "Startup Cost": 0.00,
                  "Total Cost": 0.05,
                  "Plan Rows": 4,
                  "Plan Width": 4,
                  "Actual Startup Time": 0.000,
                  "Actual Total Time": 0.000,
                  "Actual Rows": 4,
                  "Actual Loops": 1,
                  "Shared Hit Blocks": 0,
                  "Shared Read Blocks": 0,
                  "Shared Dirtied Blocks": 0,
                  "Shared Written Blocks": 0,
                  "Local Hit Blocks": 0,
                  "Local Read Blocks": 0,
                  "Local Dirtied Blocks": 0,
                  "Local Written Blocks": 0,
                  "Temp Read Blocks": 0,
                  "Temp Written Blocks": 0
                }
              ]
            }
          ]
        },
        "Planning": {
          "Shared Hit Blocks": 36,
          "Shared Read Blocks": 0,
          "Shared Dirtied Blocks": 0,
          "Shared Written Blocks": 0,
          "Local Hit Blocks": 0,
          "Local Read Blocks": 0,
          "Local Dirtied Blocks": 0,
          "Local Written Blocks": 0,
          "Temp Read Blocks": 0,
          "Temp Written Blocks": 0
        },
        "Planning Time": 0.107,
        "Triggers": [
        ],
        "Execution Time": 0.031
      }
    ]
    """#
  static let nestedLoop = #"""
    [
      {
        "Plan": {
          "Node Type": "Nested Loop",
          "Parallel Aware": false,
          "Async Capable": false,
          "Join Type": "Inner",
          "Startup Cost": 0.01,
          "Total Cost": 0.41,
          "Plan Rows": 4,
          "Plan Width": 8,
          "Actual Startup Time": 0.014,
          "Actual Total Time": 0.016,
          "Actual Rows": 4,
          "Actual Loops": 1,
          "Inner Unique": false,
          "Join Filter": "(a.n = b.n)",
          "Rows Removed by Join Filter": 12,
          "Plans": [
            {
              "Node Type": "Function Scan",
              "Parent Relationship": "Outer",
              "Parallel Aware": false,
              "Async Capable": false,
              "Function Name": "generate_series",
              "Alias": "a",
              "Startup Cost": 0.00,
              "Total Cost": 0.04,
              "Plan Rows": 4,
              "Plan Width": 4,
              "Actual Startup Time": 0.002,
              "Actual Total Time": 0.002,
              "Actual Rows": 4,
              "Actual Loops": 1
            },
            {
              "Node Type": "Function Scan",
              "Parent Relationship": "Inner",
              "Parallel Aware": false,
              "Async Capable": false,
              "Function Name": "generate_series",
              "Alias": "b",
              "Startup Cost": 0.00,
              "Total Cost": 0.04,
              "Plan Rows": 4,
              "Plan Width": 4,
              "Actual Startup Time": 0.003,
              "Actual Total Time": 0.003,
              "Actual Rows": 4,
              "Actual Loops": 4
            }
          ]
        },
        "Planning Time": 0.017,
        "Triggers": [
        ],
        "Execution Time": 0.026
      }
    ]
    """#
  static let parallelGather = #"""
    [
      {
        "Plan": {
          "Node Type": "Gather",
          "Parallel Aware": false,
          "Async Capable": false,
          "Startup Cost": 0.00,
          "Total Cost": 1718.33,
          "Plan Rows": 200000,
          "Plan Width": 4,
          "Actual Startup Time": 0.176,
          "Actual Total Time": 8.579,
          "Actual Rows": 200000,
          "Actual Loops": 1,
          "Workers Planned": 2,
          "Workers Launched": 2,
          "Single Copy": false,
          "Plans": [
            {
              "Node Type": "Seq Scan",
              "Parent Relationship": "Outer",
              "Parallel Aware": true,
              "Async Capable": false,
              "Relation Name": "dblore_explain_parallel",
              "Alias": "dblore_explain_parallel",
              "Startup Cost": 0.00,
              "Total Cost": 1718.33,
              "Plan Rows": 83333,
              "Plan Width": 4,
              "Actual Startup Time": 0.004,
              "Actual Total Time": 1.944,
              "Actual Rows": 66667,
              "Actual Loops": 3,
              "Workers": [
              ]
            }
          ]
        },
        "Planning Time": 0.052,
        "Triggers": [
        ],
        "Execution Time": 11.505
      }
    ]
    """#
  static let cte = #"""
    [
      {
        "Plan": {
          "Node Type": "CTE Scan",
          "Parallel Aware": false,
          "Async Capable": false,
          "CTE Name": "c",
          "Alias": "c",
          "Startup Cost": 1926.67,
          "Total Cost": 1927.12,
          "Plan Rows": 7,
          "Plan Width": 4,
          "Filter": "(id > 0)",
          "Plans": [
            {
              "Node Type": "Gather",
              "Parent Relationship": "InitPlan",
              "Subplan Name": "CTE c",
              "Parallel Aware": false,
              "Async Capable": false,
              "Startup Cost": 0.00,
              "Total Cost": 1926.67,
              "Plan Rows": 20,
              "Plan Width": 4,
              "Workers Planned": 2,
              "Single Copy": false,
              "Plans": [
                {
                  "Node Type": "Seq Scan",
                  "Parent Relationship": "Outer",
                  "Parallel Aware": true,
                  "Async Capable": false,
                  "Relation Name": "dblore_explain_parallel",
                  "Alias": "dblore_explain_parallel",
                  "Startup Cost": 0.00,
                  "Total Cost": 1926.67,
                  "Plan Rows": 8,
                  "Plan Width": 4,
                  "Filter": "(id < 10)"
                }
              ]
            }
          ]
        }
      }
    ]
    """#
}
