//
//  NotebookCell.swift
//  SQLNotebook
//

import Foundation

/// A single cell in the notebook (either SQL or Markdown)
struct NotebookCell: Codable, Identifiable, Sendable {
    let id: UUID
    var cellType: CellType
    var content: String
    var executionCount: Int?
    var result: CellResult?
    var isRunning: Bool

    nonisolated init(
        id: UUID = UUID(),
        cellType: CellType = .sql,
        content: String = "",
        executionCount: Int? = nil,
        result: CellResult? = nil,
        isRunning: Bool = false
    ) {
        self.id = id
        self.cellType = cellType
        self.content = content
        self.executionCount = executionCount
        self.result = result
        self.isRunning = isRunning
    }
}

/// The type of cell content
enum CellType: String, Codable, Sendable {
    case sql
    case markdown
}

/// Result of executing a SQL cell
struct CellResult: Codable, Sendable {
    let columns: [ColumnInfo]
    let rows: [[CellValue]]
    let executionTime: TimeInterval
    let rowCount: Int
    let timestamp: Date
    var error: String?
    /// True if the result was limited due to reaching max fetch rows
    let wasLimited: Bool

    nonisolated init(
        columns: [ColumnInfo] = [],
        rows: [[CellValue]] = [],
        executionTime: TimeInterval = 0,
        rowCount: Int = 0,
        timestamp: Date = Date(),
        error: String? = nil,
        wasLimited: Bool = false
    ) {
        self.columns = columns
        self.rows = rows
        self.executionTime = executionTime
        self.rowCount = rowCount
        self.timestamp = timestamp
        self.error = error
        self.wasLimited = wasLimited
    }

    /// Creates an error result
    nonisolated static func errorResult(_ message: String, executionTime: TimeInterval = 0) -> CellResult {
        CellResult(
            executionTime: executionTime,
            timestamp: Date(),
            error: message
        )
    }
}

/// Information about a result column
struct ColumnInfo: Codable, Identifiable, Sendable {
    var id: String { name }
    let name: String
    let type: String
}

/// A value in a result cell, supporting multiple SQL types
enum CellValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case json(String)
    case date(Date)
    case data(Data)

    /// Display string for the value
    var displayString: String {
        switch self {
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        case .double(let value):
            return String(format: "%.2f", value)
        case .bool(let value):
            return value ? "true" : "false"
        case .null:
            return "NULL"
        case .json(let value):
            // Show preview for JSON
            if value.hasPrefix("{") {
                return "{...}"
            } else if value.hasPrefix("[") {
                return "[...]"
            }
            return value
        case .date(let value):
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .medium
            return formatter.string(from: value)
        case .data(let value):
            return "<\(value.count) bytes>"
        }
    }

    /// Full string representation (not truncated)
    var fullString: String {
        switch self {
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .null:
            return "NULL"
        case .json(let value):
            return value
        case .date(let value):
            return ISO8601DateFormatter().string(from: value)
        case .data(let value):
            return value.base64EncodedString()
        }
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    var isJSON: Bool {
        if case .json = self { return true }
        return false
    }
}
