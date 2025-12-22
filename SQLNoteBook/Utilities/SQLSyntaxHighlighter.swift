//
//  SQLSyntaxHighlighter.swift
//  SQLNotebook
//

import AppKit
import SwiftUI

/// SQL syntax highlighter with token-based coloring
enum SQLSyntaxHighlighter {

    // MARK: - Token Types

    enum TokenType {
        case keyword
        case function
        case string
        case number
        case comment
        case `operator`
        case identifier
        case type

        var color: NSColor {
            switch self {
            case .keyword:
                return NSColor(Color.syntaxKeyword)
            case .function:
                return NSColor(Color.syntaxFunction)
            case .string:
                return NSColor(Color.syntaxString)
            case .number:
                return NSColor(Color.syntaxNumber)
            case .comment:
                return NSColor(Color.syntaxComment)
            case .operator:
                return NSColor(Color.syntaxOperator)
            case .identifier:
                return NSColor(Color.foreground)
            case .type:
                return NSColor(Color.syntaxFunction)
            }
        }
    }

    // MARK: - Keywords

    static let keywords: Set<String> = [
        // DDL
        "CREATE", "ALTER", "DROP", "TABLE", "INDEX", "VIEW", "DATABASE", "SCHEMA",
        "CONSTRAINT", "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "CHECK",
        "DEFAULT", "CASCADE", "RESTRICT", "TRUNCATE",

        // DML
        "SELECT", "INSERT", "UPDATE", "DELETE", "FROM", "WHERE", "JOIN", "ON",
        "AND", "OR", "NOT", "IN", "BETWEEN", "LIKE", "ILIKE", "IS", "NULL", "AS",
        "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "OFFSET", "UNION", "INTERSECT",
        "EXCEPT", "ALL", "DISTINCT", "INTO", "VALUES", "SET", "RETURNING",

        // Joins
        "INNER", "LEFT", "RIGHT", "FULL", "OUTER", "CROSS", "NATURAL",

        // Subqueries
        "EXISTS", "ANY", "SOME",

        // Case
        "CASE", "WHEN", "THEN", "ELSE", "END",

        // Transaction
        "BEGIN", "COMMIT", "ROLLBACK", "TRANSACTION", "SAVEPOINT",

        // Other
        "WITH", "RECURSIVE", "OVER", "PARTITION", "WINDOW", "FILTER",
        "ASC", "DESC", "NULLS", "FIRST", "LAST", "USING", "ONLY", "LATERAL",
        "EXPLAIN", "ANALYZE", "VERBOSE", "GRANT", "REVOKE", "TO", "ROLE"
    ]

    static let functions: Set<String> = [
        // Aggregate
        "COUNT", "SUM", "AVG", "MIN", "MAX", "ARRAY_AGG", "STRING_AGG",
        "BOOL_AND", "BOOL_OR", "BIT_AND", "BIT_OR", "EVERY",

        // String
        "CONCAT", "LENGTH", "LOWER", "UPPER", "TRIM", "LTRIM", "RTRIM",
        "SUBSTRING", "REPLACE", "SPLIT_PART", "POSITION", "LEFT", "RIGHT",
        "LPAD", "RPAD", "REVERSE", "INITCAP", "REPEAT", "OVERLAY",

        // Numeric
        "ABS", "CEIL", "CEILING", "FLOOR", "ROUND", "TRUNC", "MOD",
        "POWER", "SQRT", "SIGN", "RANDOM", "LOG", "LN", "EXP",

        // Date/Time
        "NOW", "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP",
        "DATE_TRUNC", "DATE_PART", "EXTRACT", "AGE", "INTERVAL",
        "TO_DATE", "TO_TIMESTAMP", "TO_CHAR",

        // Type conversion
        "CAST", "COALESCE", "NULLIF", "GREATEST", "LEAST",

        // JSON
        "JSON_BUILD_OBJECT", "JSON_BUILD_ARRAY", "JSON_AGG",
        "JSONB_BUILD_OBJECT", "JSONB_BUILD_ARRAY", "JSONB_AGG",
        "JSON_EXTRACT_PATH", "JSONB_EXTRACT_PATH",

        // Array
        "ARRAY_LENGTH", "ARRAY_POSITION", "ARRAY_REMOVE", "ARRAY_APPEND",
        "UNNEST", "ARRAY_TO_STRING",

        // Window
        "ROW_NUMBER", "RANK", "DENSE_RANK", "NTILE", "LAG", "LEAD",
        "FIRST_VALUE", "LAST_VALUE", "NTH_VALUE"
    ]

    static let types: Set<String> = [
        // Numeric
        "INTEGER", "INT", "SMALLINT", "BIGINT", "SERIAL", "BIGSERIAL",
        "DECIMAL", "NUMERIC", "REAL", "DOUBLE", "PRECISION", "FLOAT",

        // Character
        "VARCHAR", "CHAR", "CHARACTER", "TEXT", "VARYING",

        // Binary
        "BYTEA", "BLOB",

        // Boolean
        "BOOLEAN", "BOOL",

        // Date/Time
        "DATE", "TIME", "TIMESTAMP", "TIMESTAMPTZ", "INTERVAL",
        "TIMETZ",

        // UUID
        "UUID",

        // JSON
        "JSON", "JSONB",

        // Array
        "ARRAY",

        // Other
        "MONEY", "INET", "CIDR", "MACADDR", "BIT", "XML", "POINT",
        "LINE", "LSEG", "BOX", "PATH", "POLYGON", "CIRCLE"
    ]

    static let operators: Set<String> = [
        "=", "<>", "!=", "<", ">", "<=", ">=",
        "+", "-", "*", "/", "%", "^",
        "||", "->", "->>", "#>", "#>>",
        "@>", "<@", "?", "?|", "?&",
        "~", "~*", "!~", "!~*"
    ]

    // MARK: - Highlighting

    static func highlight(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text)

        // Default attributes
        let defaultAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor(Color.foreground)
        ]
        result.addAttributes(defaultAttributes, range: NSRange(location: 0, length: text.count))

        // Apply highlighting
        highlightComments(in: result, text: text)
        highlightStrings(in: result, text: text)
        highlightNumbers(in: result, text: text)
        highlightKeywords(in: result, text: text)
        highlightFunctions(in: result, text: text)
        highlightTypes(in: result, text: text)

        return result
    }

    // MARK: - Token Highlighting

    private static func highlightComments(in attributed: NSMutableAttributedString, text: String) {
        // Single-line comments: -- ...
        let singleLinePattern = "--[^\n]*"
        applyPattern(singleLinePattern, to: attributed, text: text, type: .comment)

        // Multi-line comments: /* ... */
        let multiLinePattern = "/\\*[\\s\\S]*?\\*/"
        applyPattern(multiLinePattern, to: attributed, text: text, type: .comment)
    }

    private static func highlightStrings(in attributed: NSMutableAttributedString, text: String) {
        // Single-quoted strings
        let singleQuotePattern = "'(?:[^'\\\\]|\\\\.)*'"
        applyPattern(singleQuotePattern, to: attributed, text: text, type: .string)

        // Dollar-quoted strings (PostgreSQL)
        let dollarQuotePattern = "\\$\\$[\\s\\S]*?\\$\\$"
        applyPattern(dollarQuotePattern, to: attributed, text: text, type: .string)
    }

    private static func highlightNumbers(in attributed: NSMutableAttributedString, text: String) {
        // Integers and decimals
        let numberPattern = "\\b\\d+\\.?\\d*\\b"
        applyPattern(numberPattern, to: attributed, text: text, type: .number)
    }

    private static func highlightKeywords(in attributed: NSMutableAttributedString, text: String) {
        for keyword in keywords {
            let pattern = "\\b\(keyword)\\b"
            applyPattern(pattern, to: attributed, text: text, type: .keyword, caseSensitive: false)
        }
    }

    private static func highlightFunctions(in attributed: NSMutableAttributedString, text: String) {
        for function in functions {
            let pattern = "\\b\(function)\\s*(?=\\()"
            applyPattern(pattern, to: attributed, text: text, type: .function, caseSensitive: false)
        }
    }

    private static func highlightTypes(in attributed: NSMutableAttributedString, text: String) {
        for type in types {
            let pattern = "\\b\(type)\\b"
            applyPattern(pattern, to: attributed, text: text, type: .type, caseSensitive: false)
        }
    }

    // MARK: - Helpers

    private static func applyPattern(
        _ pattern: String,
        to attributed: NSMutableAttributedString,
        text: String,
        type: TokenType,
        caseSensitive: Bool = true
    ) {
        var options: NSRegularExpression.Options = []
        if !caseSensitive {
            options.insert(.caseInsensitive)
        }

        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }

        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)

        for match in matches {
            // Check if this range is already inside a comment or string
            // (we process comments and strings first, so skip if already colored differently)
            var existingColor: NSColor?
            attributed.enumerateAttribute(.foregroundColor, in: match.range, options: []) { value, _, _ in
                existingColor = value as? NSColor
            }

            // Only apply highlighting if not already highlighted as comment or string
            // (unless we're highlighting comments or strings themselves)
            let commentColor = NSColor(Color.syntaxComment)
            let stringColor = NSColor(Color.syntaxString)

            if type == .comment || type == .string ||
               (existingColor != commentColor && existingColor != stringColor) {
                attributed.addAttribute(.foregroundColor, value: type.color, range: match.range)
            }
        }
    }
}
