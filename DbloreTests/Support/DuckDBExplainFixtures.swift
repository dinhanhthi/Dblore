// DuckDBExplainFixtures.swift
// Real `EXPLAIN (FORMAT JSON)` output captured from the dev DuckDB plugin (spike 2.2), for
// plan-view parsing tests that must run without the plugin.

nonisolated enum DuckDBExplainFixtures {
  /// DuckDB v1.5.6 (dev plugin), captured 2026-10-19 by DuckDBExportSpikeTests.explainJSON.
  /// `EXPLAIN (FORMAT JSON)` of `DuckDBExportSpikeTests.explainedQuery` (join + filter +
  /// aggregate + order over in-memory tables `t`, 1,000 rows, and `cats`, 3 rows). The plan is
  /// the `explain_value` column of the single (`explain_key`, `explain_value`) row: an array of
  /// root nodes, each `{"name", "children", "extra_info"}`, no timings.
  static let joinFilterAggregateJSON = #"""
    [
        {
            "name": "PROJECTION",
            "children": [
                {
                    "name": "ORDER_BY",
                    "children": [
                        {
                            "name": "PROJECTION",
                            "children": [
                                {
                                    "name": "PROJECTION",
                                    "children": [
                                        {
                                            "name": "HASH_GROUP_BY",
                                            "children": [
                                                {
                                                    "name": "PROJECTION",
                                                    "children": [
                                                        {
                                                            "name": "PROJECTION",
                                                            "children": [
                                                                {
                                                                    "name": "HASH_JOIN",
                                                                    "children": [
                                                                        {
                                                                            "name": "SEQ_SCAN",
                                                                            "children": [],
                                                                            "extra_info": {
                                                                                "Table": "memory.main.t",
                                                                                "Type": "Sequential Scan",
                                                                                "Projections": [
                                                                                    "i",
                                                                                    "d"
                                                                                ],
                                                                                "Filters": "flag",
                                                                                "Estimated Cardinality": "200"
                                                                            }
                                                                        },
                                                                        {
                                                                            "name": "SEQ_SCAN",
                                                                            "children": [],
                                                                            "extra_info": {
                                                                                "Table": "memory.main.cats",
                                                                                "Type": "Sequential Scan",
                                                                                "Projections": [
                                                                                    "id",
                                                                                    "name"
                                                                                ],
                                                                                "Estimated Cardinality": "3"
                                                                            }
                                                                        }
                                                                    ],
                                                                    "extra_info": {
                                                                        "Join Type": "INNER",
                                                                        "Conditions": "(i % 3) = id",
                                                                        "Estimated Cardinality": "0"
                                                                    }
                                                                }
                                                            ],
                                                            "extra_info": {
                                                                "Projections": [
                                                                    "#0",
                                                                    "__internal_compress_string_ubigint(#1)"
                                                                ],
                                                                "Estimated Cardinality": "0"
                                                            }
                                                        }
                                                    ],
                                                    "extra_info": {
                                                        "Projections": [
                                                            "name",
                                                            "d"
                                                        ],
                                                        "Estimated Cardinality": "0"
                                                    }
                                                }
                                            ],
                                            "extra_info": {
                                                "Groups": "#0",
                                                "Aggregates": [
                                                    "count_star()",
                                                    "sum(#1)"
                                                ],
                                                "Estimated Cardinality": "0"
                                            }
                                        }
                                    ],
                                    "extra_info": {
                                        "Projections": [
                                            "__internal_decompress_string(#0)",
                                            "#1",
                                            "#2"
                                        ],
                                        "Estimated Cardinality": "0"
                                    }
                                }
                            ],
                            "extra_info": {
                                "Projections": [
                                    "__internal_compress_string_ubigint(#0)",
                                    "#1",
                                    "#2"
                                ],
                                "Estimated Cardinality": "0"
                            }
                        }
                    ],
                    "extra_info": {
                        "Order By": "c.\"name\" ASC"
                    }
                }
            ],
            "extra_info": {
                "Projections": [
                    "__internal_decompress_string(#0)",
                    "#1",
                    "#2"
                ],
                "Estimated Cardinality": "0"
            }
        }
    ]
    """#

  /// `EXPLAIN (ANALYZE, FORMAT JSON)` of the same query, from the same capture, trimmed: the
  /// operators between the top PROJECTION and the HASH_JOIN, `query_name` (the statement text)
  /// and most query metrics are left out. One root object of query metrics whose only child is
  /// EXPLAIN_ANALYZE; `operator_timing` is each operator's own time in seconds.
  static let joinAnalyzeJSON = #"""
    {
        "rows_returned": 0,
        "latency": 0.001170792,
        "extra_info": {},
        "cpu_time": 0.0008562550000000002,
        "children": [
            {
                "operator_type": "EXPLAIN_ANALYZE",
                "operator_timing": 2.08e-7,
                "extra_info": {},
                "operator_name": "EXPLAIN_ANALYZE",
                "operator_cardinality": 0,
                "children": [
                    {
                        "operator_cardinality": 3,
                        "operator_name": "PROJECTION",
                        "extra_info": {
                            "Projections": [
                                "__internal_decompress_string(#0)",
                                "#1",
                                "#2"
                            ],
                            "Estimated Cardinality": "0"
                        },
                        "operator_timing": 2.92e-7,
                        "operator_type": "PROJECTION",
                        "children": [
                            {
                                "operator_type": "HASH_JOIN",
                                "operator_timing": 0.00028970900000000003,
                                "extra_info": {
                                    "Join Type": "INNER",
                                    "Conditions": "(i % 3) = id",
                                    "Estimated Cardinality": "0"
                                },
                                "operator_name": "HASH_JOIN",
                                "operator_cardinality": 500,
                                "children": [
                                    {
                                        "operator_cardinality": 500,
                                        "operator_name": "SEQ_SCAN",
                                        "extra_info": {
                                            "Table": "memory.main.t",
                                            "Type": "Sequential Scan",
                                            "Projections": [
                                                "i",
                                                "d"
                                            ],
                                            "Filters": "flag",
                                            "Estimated Cardinality": "200"
                                        },
                                        "operator_timing": 0.000005917,
                                        "operator_type": "TABLE_SCAN",
                                        "children": []
                                    },
                                    {
                                        "operator_cardinality": 3,
                                        "operator_name": "SEQ_SCAN",
                                        "extra_info": {
                                            "Table": "memory.main.cats",
                                            "Type": "Sequential Scan",
                                            "Projections": [
                                                "id",
                                                "name"
                                            ],
                                            "Estimated Cardinality": "3"
                                        },
                                        "operator_timing": 0.000003,
                                        "operator_type": "TABLE_SCAN",
                                        "children": []
                                    }
                                ]
                            }
                        ]
                    }
                ]
            }
        ]
    }
    """#
}
