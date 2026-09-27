// ConnectionTimeout.swift
// Timeout helper for connection attempts (moved out of DatabaseConnectionManager.swift)

import Foundation

/// Error thrown when a task exceeds its timeout
struct TimeoutError: Error {
  let message: String
}

/// Execute an async operation with a timeout
/// - Parameters:
///   - duration: Maximum duration before timing out
///   - operation: The async operation to execute
/// - Returns: Result from the operation
/// - Throws: TimeoutError if operation exceeds duration, or any error from the operation
func withTimeout<T: Sendable>(
  of duration: Duration,
  operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    // Add the main operation task
    group.addTask {
      try await operation()
    }

    // Add the timeout task
    group.addTask {
      try await Task.sleep(for: duration)
      throw TimeoutError(message: "Operation timed out after \(duration)")
    }

    // Wait for first task to complete (either operation or timeout)
    if let result = try await group.next() {
      group.cancelAll()
      return result
    }

    throw TimeoutError(message: "Unexpected task group completion")
  }
}
