//
//  SearchModels.swift
//  SQLNotebook
//
//  Created by Claude Code on 2026-01-07.
//

import Foundation

/// Search match representing a single match trong notebook
struct SearchMatch: Identifiable, Equatable, Sendable {
    let id: UUID = UUID()
    let cellId: UUID
    let matchType: SearchMatchType
    let matchRange: Range<String.Index>
    let contextText: String // Preview text với match highlighted
    let lineNumber: Int? // For SQL content matches

    enum SearchMatchType: Equatable, Sendable {
        case sqlContent
        case tableData(rowIndex: Int, columnName: String)
        case errorMessage
        case columnName(String)
    }
}

/// Search state configuration
struct SearchState: Equatable, Sendable {
    var query: String = ""
    var isCaseSensitive: Bool = false
    var matches: [SearchMatch] = []
    var currentMatchIndex: Int = 0
    var isSearching: Bool = false

    var currentMatch: SearchMatch? {
        guard !matches.isEmpty, currentMatchIndex < matches.count else { return nil }
        return matches[currentMatchIndex]
    }

    var matchCountText: String {
        guard !matches.isEmpty else { return "No matches" }
        return "\(currentMatchIndex + 1) of \(matches.count)"
    }
}
