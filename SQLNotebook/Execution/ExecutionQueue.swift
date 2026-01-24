//
//  ExecutionQueue.swift
//  SQLNotebook
//
//  Manages the queue of cell execution tasks, ensuring sequential execution
//

import Foundation

/// Actor that manages the execution queue for SQL cells
@MainActor
@Observable
class ExecutionQueue {
  /// All tasks in the queue (pending, executing, completed)
  private(set) var tasks: [ExecutionTask] = []

  /// Currently executing task
  private(set) var currentTask: ExecutionTask?

  /// Task for processing the queue
  private var processingTask: Task<Void, Never>?

  /// Flag to track if queue is processing
  private var isProcessing = false

  /// Maximum history size before auto-clearing (10.1.7 optimization)
  private let maxHistorySize: Int = 10

  /// Callback for executing a task
  private let executeTask: @MainActor (ExecutionTask) async -> CellResult?

  init(executeTask: @escaping @MainActor (ExecutionTask) async -> CellResult?) {
    self.executeTask = executeTask
  }

  // MARK: - Public API

  /// Enqueue a new execution task
  func enqueue(cellId: UUID, query: String) {
    let task = ExecutionTask(cellId: cellId, query: query)
    tasks.append(task)

    // Start processing if not already running
    if !isProcessing {
      startProcessing()
    }
  }

  /// Cancel a specific task by cell ID
  func cancel(cellId: UUID) {
    guard let index = tasks.firstIndex(where: { $0.cellId == cellId && !$0.state.isTerminal })
    else {
      return
    }

    tasks[index].state = .cancelled

    // If this is the current task, we need to handle it specially
    if currentTask?.cellId == cellId {
      // The processing loop will handle this
      processingTask?.cancel()
    }
  }

  /// Cancel all pending and executing tasks
  func cancelAll() {
    for index in tasks.indices where !tasks[index].state.isTerminal {
      tasks[index].state = .cancelled
    }

    processingTask?.cancel()
    currentTask = nil
    isProcessing = false
  }

  /// Clear completed and cancelled tasks
  func clearCompleted() {
    tasks.removeAll { task in
      switch task.state {
      case .completed, .cancelled, .failed:
        return true
      case .pending, .executing:
        return false
      }
    }
  }

  /// Get pending tasks count
  var pendingCount: Int {
    tasks.filter { $0.state == .pending }.count
  }

  /// Get position of a cell in the queue (nil if not in queue or already executing/completed)
  func queuePosition(for cellId: UUID) -> Int? {
    let pendingTasks = tasks.filter { $0.state == .pending }
    guard let index = pendingTasks.firstIndex(where: { $0.cellId == cellId }) else {
      return nil
    }
    return index + 1  // 1-based position
  }

  /// Check if a cell is currently executing
  func isExecuting(cellId: UUID) -> Bool {
    currentTask?.cellId == cellId && currentTask?.state == .executing
  }

  /// Check if a cell is in the queue (pending or executing)
  func isInQueue(cellId: UUID) -> Bool {
    tasks.contains { task in
      task.cellId == cellId && (task.state == .pending || task.state == .executing)
    }
  }

  // MARK: - Private Methods

  private func startProcessing() {
    isProcessing = true

    processingTask = Task { @MainActor in
      await processQueue()
    }
  }

  private func processQueue() async {
    while isProcessing {
      // Find next pending task
      guard let nextTaskIndex = tasks.firstIndex(where: { $0.state == .pending }) else {
        // No more pending tasks
        isProcessing = false
        currentTask = nil
        return
      }

      // Mark as executing
      tasks[nextTaskIndex].state = .executing
      currentTask = tasks[nextTaskIndex]

      // Execute the task
      if Task.isCancelled {
        tasks[nextTaskIndex].state = .cancelled
        currentTask = nil
        continue
      }

      let taskId = tasks[nextTaskIndex].id
      let result = await executeTask(tasks[nextTaskIndex])

      // Re-find the task by ID since the array may have changed during await
      guard let updatedIndex = tasks.firstIndex(where: { $0.id == taskId }) else {
        currentTask = nil
        continue
      }

      // Check if task was cancelled during execution
      if tasks[updatedIndex].state == .cancelled {
        currentTask = nil
        continue
      }

      // Update state based on result
      if let result = result {
        tasks[updatedIndex].state = .completed(result)
      } else {
        tasks[updatedIndex].state = .failed("Execution returned no result")
      }

      currentTask = nil

      // Auto-clear old completed tasks if history exceeds limit (10.1.7 optimization)
      let completedCount = tasks.filter { $0.state.isTerminal }.count
      if completedCount > maxHistorySize {
        // Keep only the most recent maxHistorySize completed tasks
        let completedTasks = tasks.filter { $0.state.isTerminal }
        let tasksToRemove = completedTasks.dropLast(maxHistorySize)
        let idsToRemove = Set(tasksToRemove.map { $0.id })
        tasks.removeAll { idsToRemove.contains($0.id) }
      }
    }
  }
}
