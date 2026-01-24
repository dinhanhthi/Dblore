//
//  TaskExtensions.swift
//  SQLNotebook
//
//  Task utilities for timeout and cancellation
//

import Foundation

// MARK: - Task Timeout Error

enum TaskTimeoutError: Error {
  case timeout(duration: TimeInterval)

  var localizedDescription: String {
    switch self {
    case .timeout(let duration):
      return "Operation timed out after \(Int(duration)) seconds"
    }
  }
}

// MARK: - Task Extensions

extension Task where Failure == Error {
  /// Execute a task with a timeout
  /// - Parameters:
  ///   - timeout: Maximum duration in seconds
  ///   - operation: The async operation to execute
  /// - Returns: Result of the operation
  /// - Throws: TaskTimeoutError if timeout is exceeded, or the operation's error
  static func withTimeout(
    seconds timeout: TimeInterval,
    operation: @escaping @Sendable () async throws -> Success
  ) async throws -> Success {
    try await withThrowingTaskGroup(of: Success?.self) { group in
      // Add the main operation task
      group.addTask {
        try await operation()
      }

      // Add timeout task that returns nil
      group.addTask {
        try await Task<Never, Never>.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        return nil
      }

      // Wait for first task to complete
      guard let firstResult = try await group.next() else {
        throw TaskTimeoutError.timeout(duration: timeout)
      }

      // Cancel remaining tasks
      group.cancelAll()

      // If timeout completed first (nil), throw timeout error
      guard let result = firstResult else {
        throw TaskTimeoutError.timeout(duration: timeout)
      }

      return result
    }
  }
}
