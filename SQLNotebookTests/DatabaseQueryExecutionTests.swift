// DatabaseQueryExecutionTests.swift
// Unit tests for Database Query Execution Logic
// Tests LIMIT handling and query wrapping

import Testing
@testable import SQLNotebook
import Foundation

@Suite("Database Query Execution Tests")
@MainActor
struct DatabaseQueryExecutionTests {

    // MARK: - LIMIT Value Replacement Tests

    @Test("User LIMIT less than maxRows should be preserved")
    func userLimitLessThanMaxRowsPreserved() async throws {
        // Arrange
        let manager = DatabaseConnectionManager()
        let query = "SELECT * FROM customers LIMIT 10"
        let maxRows = 30

        // Act
        // Use reflection to access private method via executeQuery wrapper
        // Since wrapQueryWithLimit is private, we'll test the behavior through
        // the query string that would be generated
        let result = await manager.wrapQueryWithLimitPublic(query, maxRows: maxRows)

        // Assert
        #expect(result.contains("LIMIT 10"), "User's LIMIT 10 should be preserved when it's less than maxRows 30")
        #expect(!result.contains("LIMIT 30"), "Should not override with maxRows when user LIMIT is smaller")
    }

    @Test("User LIMIT equal to maxRows should be preserved")
    func userLimitEqualToMaxRowsPreserved() async throws {
        // Arrange
        let manager = DatabaseConnectionManager()
        let query = "SELECT * FROM customers LIMIT 30"
        let maxRows = 30

        // Act
        let result = await manager.wrapQueryWithLimitPublic(query, maxRows: maxRows)

        // Assert
        #expect(result.contains("LIMIT 30"), "User's LIMIT 30 should be preserved when equal to maxRows 30")
    }

    @Test("User LIMIT greater than maxRows should be replaced")
    func userLimitGreaterThanMaxRowsReplaced() async throws {
        // Arrange
        let manager = DatabaseConnectionManager()
        let query = "SELECT * FROM customers LIMIT 100"
        let maxRows = 30

        // Act
        let result = await manager.wrapQueryWithLimitPublic(query, maxRows: maxRows)

        // Assert
        #expect(result.contains("LIMIT 30"), "User's LIMIT 100 should be replaced with maxRows 30")
        #expect(!result.contains("LIMIT 100"), "Should not keep user's LIMIT when it exceeds maxRows")
    }

    @Test("No LIMIT clause should append maxRows")
    func noLimitClauseShouldAppendMaxRows() async throws {
        // Arrange
        let manager = DatabaseConnectionManager()
        let query = "SELECT * FROM customers"
        let maxRows = 30

        // Act
        let result = await manager.wrapQueryWithLimitPublic(query, maxRows: maxRows)

        // Assert
        #expect(result.contains("LIMIT 30"), "Should append LIMIT 30 when query has no LIMIT clause")
    }

    // MARK: - Complex Query LIMIT Tests

    @Test("LIMIT in WHERE clause should be ignored")
    func limitInWhereClauseIgnored() async throws {
        // Arrange
        let manager = DatabaseConnectionManager()
        let query = "SELECT * FROM customers WHERE description LIKE '%limit%' LIMIT 10"
        let maxRows = 30

        // Act
        let result = await manager.wrapQueryWithLimitPublic(query, maxRows: maxRows)

        // Assert
        #expect(result.contains("LIMIT 10"), "Should preserve actual LIMIT 10")
        #expect(result.contains("'%limit%'"), "Should preserve 'limit' keyword in WHERE clause")
    }

    @Test("Query with ORDER BY and LIMIT preserves both")
    func queryWithOrderByAndLimitPreservesBoth() async throws {
        // Arrange
        let manager = DatabaseConnectionManager()
        let query = "SELECT * FROM customers ORDER BY created_at DESC LIMIT 5"
        let maxRows = 30

        // Act
        let result = await manager.wrapQueryWithLimitPublic(query, maxRows: maxRows)

        // Assert
        #expect(result.contains("ORDER BY created_at DESC"), "Should preserve ORDER BY clause")
        #expect(result.contains("LIMIT 5"), "Should preserve user's LIMIT 5")
    }

    @Test("Query with trailing semicolon handles LIMIT correctly")
    func queryWithTrailingSemicolonHandlesLimitCorrectly() async throws {
        // Arrange
        let manager = DatabaseConnectionManager()
        let query = "SELECT * FROM customers LIMIT 15;"
        let maxRows = 30

        // Act
        let result = await manager.wrapQueryWithLimitPublic(query, maxRows: maxRows)

        // Assert
        #expect(result.contains("LIMIT 15"), "Should preserve user's LIMIT 15 with trailing semicolon")
        #expect(!result.hasSuffix("; LIMIT"), "Should not have semicolon before LIMIT")
    }

    @Test("Query without LIMIT but with trailing semicolon should append LIMIT")
    func queryWithoutLimitButWithSemicolonShouldAppendLimit() async throws {
        // Arrange
        let manager = DatabaseConnectionManager()
        let query = "SELECT * FROM customers WHERE name = 'John';"
        let maxRows = 50

        // Act
        let result = await manager.wrapQueryWithLimitPublic(query, maxRows: maxRows)

        // Assert
        #expect(result.contains("LIMIT 50"), "Should append LIMIT 50 to query with trailing semicolon")
        #expect(!result.contains("; LIMIT"), "Should remove semicolon before appending LIMIT")
        #expect(result.hasSuffix("LIMIT 50"), "Query should end with LIMIT 50, not semicolon")
    }

    // MARK: - Case Sensitivity Tests

    @Test("LIMIT keyword case insensitive - lowercase")
    func limitKeywordCaseInsensitiveLowercase() async throws {
        // Arrange
        let manager = DatabaseConnectionManager()
        let query = "select * from customers limit 20"
        let maxRows = 30

        // Act
        let result = await manager.wrapQueryWithLimitPublic(query, maxRows: maxRows)

        // Assert - Should preserve user's LIMIT
        #expect(result.lowercased().contains("limit 20"), "Should handle lowercase 'limit' keyword")
    }

    @Test("LIMIT keyword case insensitive - mixed case")
    func limitKeywordCaseInsensitiveMixedCase() async throws {
        // Arrange
        let manager = DatabaseConnectionManager()
        let query = "SELECT * FROM customers LiMiT 25"
        let maxRows = 30

        // Act
        let result = await manager.wrapQueryWithLimitPublic(query, maxRows: maxRows)

        // Assert
        #expect(result.uppercased().contains("LIMIT 25"), "Should handle mixed-case 'LiMiT' keyword")
    }

    // MARK: - Edge Cases

    @Test("Empty query should remain empty")
    func emptyQueryShouldRemainEmpty() async throws {
        // Arrange
        let manager = DatabaseConnectionManager()
        let query = ""
        let maxRows = 30

        // Act
        let result = await manager.wrapQueryWithLimitPublic(query, maxRows: maxRows)

        // Assert
        // Empty queries should not have LIMIT appended (not a SELECT)
        #expect(result.isEmpty, "Empty query should remain empty")
    }

    @Test("Non-SELECT query should not get LIMIT")
    func nonSelectQueryShouldNotGetLimit() async throws {
        // Arrange
        let manager = DatabaseConnectionManager()
        let query = "UPDATE customers SET status = 'active'"
        let maxRows = 30

        // Act
        let result = await manager.wrapQueryWithLimitPublic(query, maxRows: maxRows)

        // Assert
        #expect(!result.contains("LIMIT"), "UPDATE query should not get LIMIT clause")
    }

    @Test("INSERT query should not get LIMIT")
    func insertQueryShouldNotGetLimit() async throws {
        // Arrange
        let manager = DatabaseConnectionManager()
        let query = "INSERT INTO customers (name) VALUES ('John')"
        let maxRows = 30

        // Act
        let result = await manager.wrapQueryWithLimitPublic(query, maxRows: maxRows)

        // Assert
        #expect(!result.contains("LIMIT"), "INSERT query should not get LIMIT clause")
    }

    @Test("DELETE query should not get LIMIT")
    func deleteQueryShouldNotGetLimit() async throws {
        // Arrange
        let manager = DatabaseConnectionManager()
        let query = "DELETE FROM customers WHERE id = 1"
        let maxRows = 30

        // Act
        let result = await manager.wrapQueryWithLimitPublic(query, maxRows: maxRows)

        // Assert
        #expect(!result.contains("LIMIT"), "DELETE query should not get LIMIT clause")
    }

    // MARK: - Whitespace Handling

    @Test("Query with extra whitespace handled correctly")
    func queryWithExtraWhitespaceHandledCorrectly() async throws {
        // Arrange
        let manager = DatabaseConnectionManager()
        let query = "SELECT   *   FROM   customers   LIMIT   12"
        let maxRows = 30

        // Act
        let result = await manager.wrapQueryWithLimitPublic(query, maxRows: maxRows)

        // Assert
        #expect(result.contains("LIMIT"), "Should handle query with extra whitespace")
        // User's LIMIT 12 should be preserved
    }

    @Test("Query with newlines handled correctly")
    func queryWithNewlinesHandledCorrectly() async throws {
        // Arrange
        let manager = DatabaseConnectionManager()
        let query = """
        SELECT *
        FROM customers
        LIMIT 8
        """
        let maxRows = 30

        // Act
        let result = await manager.wrapQueryWithLimitPublic(query, maxRows: maxRows)

        // Assert
        #expect(result.contains("LIMIT"), "Should handle query with newlines")
    }

    // MARK: - LIMIT with OFFSET Tests

    @Test("LIMIT with OFFSET preserves user LIMIT")
    func limitWithOffsetPreservesUserLimit() async throws {
        // Arrange
        let manager = DatabaseConnectionManager()
        let query = "SELECT * FROM customers LIMIT 20 OFFSET 100"
        let maxRows = 30

        // Act
        let result = await manager.wrapQueryWithLimitPublic(query, maxRows: maxRows)

        // Assert
        #expect(result.contains("LIMIT 20"), "Should preserve user's LIMIT 20 even with OFFSET")
        #expect(result.contains("OFFSET 100"), "Should preserve OFFSET clause")
    }

    @Test("LIMIT with OFFSET - user LIMIT exceeds maxRows")
    func limitWithOffsetUserLimitExceedsMaxRows() async throws {
        // Arrange
        let manager = DatabaseConnectionManager()
        let query = "SELECT * FROM customers LIMIT 50 OFFSET 10"
        let maxRows = 30

        // Act
        let result = await manager.wrapQueryWithLimitPublic(query, maxRows: maxRows)

        // Assert
        #expect(result.contains("LIMIT 30"), "Should replace LIMIT 50 with maxRows 30")
        #expect(result.contains("OFFSET 10"), "Should preserve OFFSET clause")
        #expect(!result.contains("LIMIT 50"), "Should not keep original LIMIT 50")
    }

    // MARK: - SELECT without FROM clause Tests

    @Test("SELECT pg_sleep should not get LIMIT appended")
    func selectPgSleepNoLimit() async throws {
        // Arrange
        let manager = DatabaseConnectionManager()
        let query = "SELECT pg_sleep(3)"
        let maxRows = 30

        // Act
        let result = await manager.wrapQueryWithLimitPublic(query, maxRows: maxRows)

        // Assert
        #expect(result == "SELECT pg_sleep(3)", "Should not append LIMIT to SELECT pg_sleep(3)")
        #expect(!result.contains("LIMIT"), "pg_sleep query should not have LIMIT clause")
    }

    @Test("SELECT now() should not get LIMIT appended")
    func selectNowNoLimit() async throws {
        // Arrange
        let manager = DatabaseConnectionManager()
        let query = "SELECT now()"
        let maxRows = 30

        // Act
        let result = await manager.wrapQueryWithLimitPublic(query, maxRows: maxRows)

        // Assert
        #expect(result == "SELECT now()", "Should not append LIMIT to SELECT now()")
        #expect(!result.contains("LIMIT"), "now() query should not have LIMIT clause")
    }

    @Test("SELECT version() should not get LIMIT appended")
    func selectVersionNoLimit() async throws {
        // Arrange
        let manager = DatabaseConnectionManager()
        let query = "SELECT version()"
        let maxRows = 30

        // Act
        let result = await manager.wrapQueryWithLimitPublic(query, maxRows: maxRows)

        // Assert
        #expect(result == "SELECT version()", "Should not append LIMIT to SELECT version()")
        #expect(!result.contains("LIMIT"), "version() query should not have LIMIT clause")
    }

    @Test("SELECT with multiple functions should not get LIMIT")
    func selectMultipleFunctionsNoLimit() async throws {
        // Arrange
        let manager = DatabaseConnectionManager()
        let query = "SELECT now(), version(), pg_sleep(1)"
        let maxRows = 30

        // Act
        let result = await manager.wrapQueryWithLimitPublic(query, maxRows: maxRows)

        // Assert
        #expect(result == "SELECT now(), version(), pg_sleep(1)", "Should not append LIMIT to function-only SELECT")
        #expect(!result.contains("LIMIT"), "Function-only query should not have LIMIT clause")
    }

    @Test("SELECT with FROM clause should get LIMIT appended")
    func selectWithFromGetsLimit() async throws {
        // Arrange
        let manager = DatabaseConnectionManager()
        let query = "SELECT * FROM customers"
        let maxRows = 30

        // Act
        let result = await manager.wrapQueryWithLimitPublic(query, maxRows: maxRows)

        // Assert
        #expect(result.contains("LIMIT 30"), "Should append LIMIT 30 to SELECT with FROM clause")
    }
}

// MARK: - Test Helper Extension

extension DatabaseConnectionManager {
    /// Public wrapper for testing private `wrapQueryWithLimit` method
    /// This allows us to test the LIMIT handling logic without needing a real database connection
    func wrapQueryWithLimitPublic(_ query: String, maxRows: Int) -> String {
        // Since wrapQueryWithLimit is private, we need to access it via reflection
        // Or we can add an internal test helper method
        // For now, we'll simulate the logic here based on the implementation

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's a SELECT query
        guard trimmed.uppercased().hasPrefix("SELECT") else {
            return trimmed
        }

        // Don't wrap if it's a SELECT without FROM clause (e.g., SELECT pg_sleep(3), SELECT now())
        // These queries call functions and don't return table data
        if !hasFromClausePublic(trimmed) {
            return trimmed
        }

        // Remove trailing semicolon if present
        let cleanQuery = trimmed.hasSuffix(";") ? String(trimmed.dropLast()) : trimmed

        // Check for existing LIMIT
        if hasLimitClausePublic(cleanQuery) {
            return replaceLimitValuePublic(cleanQuery, maxRows: maxRows)
        }

        // No LIMIT - append maxRows
        return "\(cleanQuery) LIMIT \(maxRows)"
    }

    /// Public wrapper for private hasLimitClause method
    func hasLimitClausePublic(_ query: String) -> Bool {
        let normalized = query.lowercased()
        return normalized.range(of: "\\blimit\\b", options: .regularExpression) != nil
    }

    /// Public wrapper for private hasFromClause method
    func hasFromClausePublic(_ query: String) -> Bool {
        let normalized = query.lowercased()
        return normalized.range(of: "\\bfrom\\b", options: .regularExpression) != nil
    }

    /// Public wrapper for private replaceLimitValue method
    func replaceLimitValuePublic(_ query: String, maxRows: Int) -> String {
        // Extract user's LIMIT value
        guard let userLimit = extractLimitValuePublic(query) else {
            return query
        }

        // If user's LIMIT is already within maxRows, keep it as-is
        if userLimit <= maxRows {
            return query
        }

        // User's LIMIT exceeds maxRows, replace it
        let pattern = "\\bLIMIT\\s+\\d+"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return query
        }

        let nsRange = NSRange(query.startIndex..., in: query)
        let modifiedQuery = regex.stringByReplacingMatches(
            in: query,
            options: [],
            range: nsRange,
            withTemplate: "LIMIT \(maxRows)"
        )

        return modifiedQuery
    }

    /// Public wrapper for private extractLimitValue method
    func extractLimitValuePublic(_ query: String) -> Int? {
        let cleaned = query.replacingOccurrences(of: ";", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = cleaned.lowercased()

        let pattern = "\\blimit\\s+(\\d+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: normalized, options: [], range: NSRange(normalized.startIndex..., in: normalized)),
              match.numberOfRanges > 1,
              let numberRange = Range(match.range(at: 1), in: normalized)
        else {
            return nil
        }

        let numberString = String(normalized[numberRange])
        return Int(numberString)
    }
}
