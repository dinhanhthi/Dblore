//
//  ExecutionTask.swift
//  Dblore
//
//  Model representing a cell execution task in the queue
//

import Foundation

/// Represents the state of an execution task
enum ExecutionState: Sendable {
  case pending
  case executing
  case completed(CellResult)
  case cancelled
  case failed(String)  // Using String instead of Error for Equatable conformance

  var isTerminal: Bool {
    switch self {
    case .completed, .cancelled, .failed:
      return true
    case .pending, .executing:
      return false
    }
  }
}

// Manual Equatable implementation since CellResult is not Equatable
extension ExecutionState: Equatable {
  static func == (lhs: ExecutionState, rhs: ExecutionState) -> Bool {
    switch (lhs, rhs) {
    case (.pending, .pending):
      return true
    case (.executing, .executing):
      return true
    case (.completed, .completed):
      return true  // We don't compare CellResults
    case (.cancelled, .cancelled):
      return true
    case (.failed(let lhsMsg), .failed(let rhsMsg)):
      return lhsMsg == rhsMsg
    default:
      return false
    }
  }
}

/// Represents a task in the execution queue
struct ExecutionTask: Identifiable, Sendable {
  let id: UUID
  let cellId: UUID
  var state: ExecutionState
  let createdAt: Date
  let query: String
  /// The Run All batch this task belongs to (nil for a single cell run)
  let batchId: UUID?

  init(cellId: UUID, query: String, batchId: UUID? = nil) {
    self.id = UUID()
    self.cellId = cellId
    self.state = .pending
    self.createdAt = Date()
    self.query = query
    self.batchId = batchId
  }
}
