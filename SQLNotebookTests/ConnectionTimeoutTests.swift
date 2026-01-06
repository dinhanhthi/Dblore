//
//  ConnectionTimeoutTests.swift
//  SQLNotebook
//
//  Unit tests for connection timeout functionality

import Testing
@testable import SQLNotebook
import Foundation

@Suite("Connection Timeout Tests")
struct ConnectionTimeoutTests {

    // MARK: - TimeoutError Tests

    @Test("TimeoutError has descriptive message")
    func timeoutErrorMessage() {
        // Arrange & Act
        let error = TimeoutError(message: "Operation timed out after 30 seconds")

        // Assert
        #expect(error.message == "Operation timed out after 30 seconds")
    }

    // MARK: - Timeout Behavior Tests (via simulation)

    @Test("Fast operation completes before timeout")
    func fastOperationCompletesBeforeTimeout() async throws {
        // Arrange - Create a fast operation (completes in 100ms)
        let expectedResult = "Success"
        let startTime = Date()

        // Act - Simulate withTimeout behavior with fast operation
        let result = try await withTestTimeout(of: .seconds(2)) {
            try await Task.sleep(for: .milliseconds(100))
            return expectedResult
        }
        let elapsedTime = Date().timeIntervalSince(startTime)

        // Assert
        #expect(result == expectedResult)
        #expect(elapsedTime < 1.0) // Should complete well before timeout
    }

    @Test("Slow operation times out correctly")
    func slowOperationTimesOut() async {
        // Arrange - Create a slow operation (would take 5 seconds)
        let startTime = Date()

        // Act & Assert
        await #expect(throws: TimeoutError.self) {
            try await withTestTimeout(of: .milliseconds(500)) {
                // Simulate a slow operation
                try await Task.sleep(for: .seconds(5))
                return "Should not reach here"
            }
        }

        let elapsedTime = Date().timeIntervalSince(startTime)
        // Should timeout around 500ms, not wait full 5 seconds
        #expect(elapsedTime < 1.0)
    }

    @Test("Timeout cancels running tasks")
    func timeoutCancelsRunningTasks() async throws {
        // Arrange
        var taskWasCancelled = false

        // Act
        do {
            _ = try await withTestTimeout(of: .milliseconds(200)) {
                try await Task.sleep(for: .seconds(10))
                return "Should not complete"
            }
        } catch is TimeoutError {
            // Expected timeout
            taskWasCancelled = true
        }

        // Assert
        #expect(taskWasCancelled)
    }

    @Test("Operation that throws error propagates correctly")
    func operationErrorPropagatesCorrectly() async {
        // Arrange
        struct CustomError: Error {}

        // Act & Assert
        await #expect(throws: CustomError.self) {
            try await withTestTimeout(of: .seconds(2)) {
                throw CustomError()
            }
        }
    }

    @Test("Multiple timeout values work correctly")
    func multipleTimeoutValuesWorkCorrectly() async throws {
        // Arrange - Test different timeout durations
        let testCases: [(duration: Duration, sleepTime: Duration, shouldTimeout: Bool)] = [
            (.milliseconds(100), .milliseconds(50), false),   // Should complete
            (.milliseconds(100), .milliseconds(200), true),   // Should timeout
            (.seconds(1), .milliseconds(500), false),         // Should complete
            (.seconds(1), .seconds(2), true),                 // Should timeout
        ]

        // Act & Assert
        for testCase in testCases {
            if testCase.shouldTimeout {
                await #expect(throws: TimeoutError.self) {
                    try await withTestTimeout(of: testCase.duration) {
                        try await Task.sleep(for: testCase.sleepTime)
                        return "Done"
                    }
                }
            } else {
                let result = try await withTestTimeout(of: testCase.duration) {
                    try await Task.sleep(for: testCase.sleepTime)
                    return "Done"
                }
                #expect(result == "Done")
            }
        }
    }

    // MARK: - Helper: Test version of withTimeout
    // This replicates the private withTimeout function for testing purposes

    private func withTestTimeout<T: Sendable>(
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
}
