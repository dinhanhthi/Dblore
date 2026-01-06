//
//  ExecutionQueueTests.swift
//  SQLNotebookTests
//
//  Tests for the ExecutionQueue system
//

import Foundation
import Testing

@testable import SQLNotebook

@MainActor
struct ExecutionQueueTests {

    // MARK: - Basic Queue Operations

    @Test("Queue enqueues tasks in order")
    func testEnqueueTasks() async throws {
        var executedCellIds: [UUID] = []

        let queue = ExecutionQueue { task in
            executedCellIds.append(task.cellId)
            // Simulate execution
            try? await Task.sleep(for: .milliseconds(10))
            return nil
        }

        let cellId1 = UUID()
        let cellId2 = UUID()
        let cellId3 = UUID()

        queue.enqueue(cellId: cellId1, query: "SELECT 1")
        queue.enqueue(cellId: cellId2, query: "SELECT 2")
        queue.enqueue(cellId: cellId3, query: "SELECT 3")

        #expect(queue.pendingCount == 3)

        // Wait for executions to complete
        try await Task.sleep(for: .milliseconds(200))

        // Verify sequential execution
        #expect(executedCellIds.count == 3)
        #expect(executedCellIds[0] == cellId1)
        #expect(executedCellIds[1] == cellId2)
        #expect(executedCellIds[2] == cellId3)
    }

    @Test("Queue position is correct")
    func testQueuePosition() async throws {
        let queue = ExecutionQueue { task in
            // Never complete (simulate long-running task)
            try? await Task.sleep(for: .seconds(10))
            return nil
        }

        let cellId1 = UUID()
        let cellId2 = UUID()
        let cellId3 = UUID()

        queue.enqueue(cellId: cellId1, query: "SELECT 1")
        queue.enqueue(cellId: cellId2, query: "SELECT 2")
        queue.enqueue(cellId: cellId3, query: "SELECT 3")

        // Give time for first task to start executing
        try await Task.sleep(for: .milliseconds(50))

        // Cell 1 should be executing (nil position)
        #expect(queue.queuePosition(for: cellId1) == nil)

        // Cell 2 should be at position 1
        #expect(queue.queuePosition(for: cellId2) == 1)

        // Cell 3 should be at position 2
        #expect(queue.queuePosition(for: cellId3) == 2)
    }

    // MARK: - Cancellation

    @Test("Cancel specific task")
    func testCancelTask() async throws {
        var executedCellIds: [UUID] = []

        let queue = ExecutionQueue { task in
            executedCellIds.append(task.cellId)
            try? await Task.sleep(for: .milliseconds(50))
            return nil
        }

        let cellId1 = UUID()
        let cellId2 = UUID()
        let cellId3 = UUID()

        queue.enqueue(cellId: cellId1, query: "SELECT 1")
        queue.enqueue(cellId: cellId2, query: "SELECT 2")
        queue.enqueue(cellId: cellId3, query: "SELECT 3")

        // Give time for first task to start
        try await Task.sleep(for: .milliseconds(10))

        // Cancel second task
        queue.cancel(cellId: cellId2)

        // Wait for executions
        try await Task.sleep(for: .milliseconds(300))

        // Cell 2 should not have executed
        #expect(executedCellIds.count == 2)
        #expect(!executedCellIds.contains(cellId2))
    }

    @Test("Cancel all tasks")
    func testCancelAll() async throws {
        var executedCellIds: [UUID] = []

        let queue = ExecutionQueue { task in
            executedCellIds.append(task.cellId)
            try? await Task.sleep(for: .milliseconds(100))
            return nil
        }

        let cellId1 = UUID()
        let cellId2 = UUID()
        let cellId3 = UUID()

        queue.enqueue(cellId: cellId1, query: "SELECT 1")
        queue.enqueue(cellId: cellId2, query: "SELECT 2")
        queue.enqueue(cellId: cellId3, query: "SELECT 3")

        // Give time for first task to start
        try await Task.sleep(for: .milliseconds(10))

        // Cancel all
        queue.cancelAll()

        // Wait a bit
        try await Task.sleep(for: .milliseconds(200))

        // Only the first task should have started executing
        #expect(executedCellIds.count <= 1)
    }

    // MARK: - State Tracking

    @Test("isExecuting returns correct state")
    func testIsExecuting() async throws {
        let queue = ExecutionQueue { task in
            try? await Task.sleep(for: .milliseconds(100))
            return nil
        }

        let cellId = UUID()
        queue.enqueue(cellId: cellId, query: "SELECT 1")

        // Initially not executing
        #expect(!queue.isExecuting(cellId: cellId))

        // Give time to start executing
        try await Task.sleep(for: .milliseconds(10))

        // Should be executing
        #expect(queue.isExecuting(cellId: cellId))

        // Wait for completion
        try await Task.sleep(for: .milliseconds(200))

        // Should no longer be executing
        #expect(!queue.isExecuting(cellId: cellId))
    }

    @Test("isInQueue returns correct state")
    func testIsInQueue() async throws {
        let queue = ExecutionQueue { task in
            try? await Task.sleep(for: .milliseconds(50))
            return nil
        }

        let cellId = UUID()

        // Not in queue initially
        #expect(!queue.isInQueue(cellId: cellId))

        queue.enqueue(cellId: cellId, query: "SELECT 1")

        // Should be in queue
        #expect(queue.isInQueue(cellId: cellId))

        // Wait for completion
        try await Task.sleep(for: .milliseconds(150))

        // Should no longer be in queue after completion
        #expect(!queue.isInQueue(cellId: cellId))
    }

    // MARK: - Clear Completed

    @Test("Clear completed tasks")
    func testClearCompleted() async throws {
        let queue = ExecutionQueue { task in
            try? await Task.sleep(for: .milliseconds(10))
            return nil
        }

        let cellId1 = UUID()
        let cellId2 = UUID()

        queue.enqueue(cellId: cellId1, query: "SELECT 1")
        queue.enqueue(cellId: cellId2, query: "SELECT 2")

        // Wait for executions to complete
        try await Task.sleep(for: .milliseconds(100))

        // Tasks should be in queue (completed)
        #expect(queue.tasks.count == 2)

        // Clear completed
        queue.clearCompleted()

        // Queue should be empty
        #expect(queue.tasks.count == 0)
    }

    // MARK: - ExecutionState Tests

    @Test("ExecutionState isTerminal property")
    func testExecutionStateIsTerminal() {
        #expect(!ExecutionState.pending.isTerminal)
        #expect(!ExecutionState.executing.isTerminal)
        #expect(ExecutionState.cancelled.isTerminal)
        #expect(ExecutionState.failed("error").isTerminal)

        let dummyResult = CellResult.errorResult("test")
        #expect(ExecutionState.completed(dummyResult).isTerminal)
    }

    @Test("ExecutionState equality")
    func testExecutionStateEquality() {
        #expect(ExecutionState.pending == ExecutionState.pending)
        #expect(ExecutionState.executing == ExecutionState.executing)
        #expect(ExecutionState.cancelled == ExecutionState.cancelled)
        #expect(ExecutionState.failed("error") == ExecutionState.failed("error"))
        #expect(ExecutionState.failed("error1") != ExecutionState.failed("error2"))

        // Completed states are equal regardless of result content
        let result1 = CellResult.errorResult("test1")
        let result2 = CellResult.errorResult("test2")
        #expect(ExecutionState.completed(result1) == ExecutionState.completed(result2))

        // Different states should not be equal
        #expect(ExecutionState.pending != ExecutionState.executing)
        #expect(ExecutionState.pending != ExecutionState.cancelled)
    }
}
