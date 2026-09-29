//
//  SQLAutocompleteProvider+Keywords.swift
//  Dblore
//
//  SQL keyword definitions for autocomplete
//

import Foundation

// MARK: - SQL Keywords

extension SQLAutocompleteProvider {
  // Common SQL keywords (PostgreSQL focus but covers standard SQL)
  static let sqlKeywords: [String] = [
    // DML (Data Manipulation Language)
    "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
    "JOIN", "INNER JOIN", "LEFT JOIN", "RIGHT JOIN", "FULL JOIN", "CROSS JOIN",
    "ON", "AND", "OR", "NOT", "IN", "EXISTS", "BETWEEN", "LIKE", "ILIKE",
    "IS NULL", "IS NOT NULL", "AS", "DISTINCT", "ALL",

    // Aggregation & Grouping
    "GROUP BY", "HAVING", "ORDER BY", "ASC", "DESC", "LIMIT", "OFFSET",
    "COUNT", "SUM", "AVG", "MIN", "MAX",

    // DDL (Data Definition Language)
    "CREATE", "CREATE TABLE", "CREATE INDEX", "CREATE VIEW",
    "ALTER", "ALTER TABLE", "DROP", "DROP TABLE", "TRUNCATE",

    // DCL (Data Control Language)
    "GRANT", "REVOKE",

    // Transaction Control
    "BEGIN", "COMMIT", "ROLLBACK", "SAVEPOINT",

    // Data Types
    "INTEGER", "BIGINT", "SMALLINT", "SERIAL", "BIGSERIAL",
    "VARCHAR", "TEXT", "CHAR", "CHARACTER VARYING",
    "BOOLEAN", "DATE", "TIME", "TIMESTAMP", "TIMESTAMPTZ",
    "NUMERIC", "DECIMAL", "REAL", "DOUBLE PRECISION",
    "JSON", "JSONB", "UUID", "BYTEA", "ARRAY",

    // Constraints
    "PRIMARY KEY", "FOREIGN KEY", "REFERENCES", "UNIQUE", "NOT NULL",
    "CHECK", "DEFAULT", "CASCADE",

    // Window Functions
    "OVER", "PARTITION BY", "ROW_NUMBER", "RANK", "DENSE_RANK",
    "LAG", "LEAD", "FIRST_VALUE", "LAST_VALUE",

    // CTEs and Subqueries
    "WITH", "RECURSIVE", "UNION", "UNION ALL", "INTERSECT", "EXCEPT",

    // PostgreSQL Specific
    "RETURNING", "CONFLICT", "DO NOTHING", "DO UPDATE",
    "LATERAL", "TABLESAMPLE", "MATERIALIZED", "REFRESH",
    "CONCURRENTLY", "IF EXISTS", "IF NOT EXISTS",

    // Case & Casting
    "CASE", "WHEN", "THEN", "ELSE", "END", "CAST", "::text", "::integer",

    // String Functions
    "CONCAT", "LENGTH", "LOWER", "UPPER", "TRIM", "SUBSTRING",

    // Date Functions
    "NOW", "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP",
    "EXTRACT", "DATE_TRUNC", "INTERVAL",

    // NULL Handling
    "COALESCE", "NULLIF",

    // Logical
    "TRUE", "FALSE", "NULL",
  ]
}
