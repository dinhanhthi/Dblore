//
//  PaginationInfo.swift
//  SQLNotebook
//
//  Model for pagination information in query results
//

import Foundation

/// Information about pagination for a query result
struct PaginationInfo: Sendable {
  /// Current page number (1-based)
  let currentPage: Int
  /// Total number of rows in the database
  let totalRows: Int
  /// Number of rows per page (from LIMIT clause)
  let rowsPerPage: Int
  /// Original query without LIMIT/OFFSET
  let baseQuery: String

  /// Total number of pages
  var totalPages: Int {
    guard rowsPerPage > 0 else { return 0 }
    return (totalRows + rowsPerPage - 1) / rowsPerPage
  }

  /// Check if there is a previous page
  var hasPreviousPage: Bool {
    currentPage > 1
  }

  /// Check if there is a next page
  var hasNextPage: Bool {
    currentPage < totalPages
  }

  /// Calculate OFFSET for a given page number
  func offset(for page: Int) -> Int {
    guard page > 0 else { return 0 }
    return (page - 1) * rowsPerPage
  }

  /// Build query for a specific page
  func queryForPage(_ page: Int) -> String {
    let offset = offset(for: page)
    return "\(baseQuery) LIMIT \(rowsPerPage) OFFSET \(offset)"
  }
}
