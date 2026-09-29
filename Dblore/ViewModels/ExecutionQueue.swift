//
//  ExecutionQueue.swift
//  Dblore
//
//  Manages the queue of cell execution tasks, ensuring sequential execution
//  10.2.2 Optimization: Queue processing runs off main actor for non-blocking UI
//

import Foundation

/// Class that manages the execution queue for notebook cells
/// UI state is @MainActor for SwiftUI observation, but processing runs off main thread
@MainActor
@Observable
class ExecutionQueue {
  /// All tasks in the queue (pending, executing, completed)
  private(set) var tasks: [ExecutionTask] = []

  /// Currently executing task
  private(set) var currentTask: ExecutionTask?

  /// Task for processing the queue (runs detached from main actor)
  private var processingTask: Task<Void, Never>?

  /// Flag to track if queue is processing
  private(set) var isProcessing = false

  /// Identifies the current processing run: a run stopped by `cancelAll` (its statement may
  /// still be finishing) exits instead of picking up cells enqueued after the cancel
  private var runGeneration: UInt64 = 0

  /// Maximum history size before auto-clearing (10.1.7 optimization)
  private let maxHistorySize: Int = 10

  /// Callback for executing a task (runs on main actor for UI updates)
  private let executeTask: @MainActor (ExecutionTask) async -> CellResult?

  /// Continuations waiting for queue to become idle
  private var idleContinuations: [CheckedContinuation<Void, Never>] = []

  /// Continuations waiting for specific task completion
  private var taskCompletionContinuations: [UUID: [CheckedContinuation<ExecutionState, Never>]] =
    [:]

  /// Continuations waiting for specific task to start executing
  private var taskExecutingContinuations: [UUID: [CheckedContinuation<Void, Never>]] = [:]

  init(executeTask: @escaping @MainActor (ExecutionTask) async -> CellResult?) {
    self.executeTask = executeTask
  }

  // MARK: - Public API

  /// Enqueue a new execution task (`batchId`: the Run All batch it belongs to)
  func enqueue(cellId: UUID, query: String, batchId: UUID? = nil) {
    let task = ExecutionTask(cellId: cellId, query: query, batchId: batchId)
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

    // Notify waiters that task was cancelled
    notifyTaskCompletion(cellId: cellId, state: .cancelled)

    // If this is the current task, we need to handle it specially
    if currentTask?.cellId == cellId {
      // The processing loop will handle this
      processingTask?.cancel()
    }
  }

  /// Cancel all pending and executing tasks
  func cancelAll() {
    for index in tasks.indices where !tasks[index].state.isTerminal {
      let cellId = tasks[index].cellId
      tasks[index].state = .cancelled
      // Notify waiters that task was cancelled
      notifyTaskCompletion(cellId: cellId, state: .cancelled)
    }

    processingTask?.cancel()
    runGeneration &+= 1
    currentTask = nil
    isProcessing = false

    // Notify idle waiters since we're now idle
    notifyIdle()
  }

  /// Cancel the pending tasks only; the executing one finishes normally and the queue then
  /// becomes idle.
  /// - Returns: the number of tasks cancelled.
  @discardableResult
  func cancelPending() -> Int {
    var count = 0
    for index in tasks.indices where tasks[index].state == .pending {
      tasks[index].state = .cancelled
      notifyTaskCompletion(cellId: tasks[index].cellId, state: .cancelled)
      count += 1
    }
    return count
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
    // If this cell is currently executing, it's not in the pending queue
    if currentTask?.cellId == cellId {
      return nil
    }
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

  // MARK: - Async Waiting Methods (for testing and synchronization)

  /// Wait for the queue to become idle (no pending or executing tasks)
  /// Returns immediately if queue is already idle
  func waitForIdle() async {
    // If already idle, return immediately
    if !isProcessing && pendingCount == 0 && currentTask == nil {
      return
    }

    // Wait for idle notification
    await withCheckedContinuation { continuation in
      idleContinuations.append(continuation)
    }
  }

  /// Wait for a specific task to complete and return its final state
  /// Returns nil if the task doesn't exist
  func waitForTask(cellId: UUID) async -> ExecutionState? {
    // Find the task
    guard let task = tasks.first(where: { $0.cellId == cellId }) else {
      return nil
    }

    // If already terminal, return immediately
    if task.state.isTerminal {
      return task.state
    }

    // Wait for completion notification
    return await withCheckedContinuation { continuation in
      if taskCompletionContinuations[cellId] == nil {
        taskCompletionContinuations[cellId] = []
      }
      taskCompletionContinuations[cellId]?.append(continuation)
    }
  }

  /// Wait for a specific task to start executing
  /// Returns true when task starts executing, false if task doesn't exist or is already terminal
  func waitForExecuting(cellId: UUID) async -> Bool {
    // Find the task
    guard let task = tasks.first(where: { $0.cellId == cellId }) else {
      return false
    }

    // If already executing, return immediately
    if task.state == .executing || currentTask?.cellId == cellId {
      return true
    }

    // If already terminal, return false
    if task.state.isTerminal {
      return false
    }

    // Wait for executing notification
    await withCheckedContinuation { continuation in
      if taskExecutingContinuations[cellId] == nil {
        taskExecutingContinuations[cellId] = []
      }
      taskExecutingContinuations[cellId]?.append(continuation)
    }
    return true
  }

  /// Notify waiting continuations that a task started executing
  private func notifyTaskExecuting(cellId: UUID) {
    if let continuations = taskExecutingContinuations.removeValue(forKey: cellId) {
      for continuation in continuations {
        continuation.resume()
      }
    }
  }

  /// Notify waiting continuations that a task completed
  private func notifyTaskCompletion(cellId: UUID, state: ExecutionState) {
    if let continuations = taskCompletionContinuations.removeValue(forKey: cellId) {
      for continuation in continuations {
        continuation.resume(returning: state)
      }
    }
  }

  /// Notify waiting continuations that queue is idle
  private func notifyIdle() {
    let continuations = idleContinuations
    idleContinuations.removeAll()
    for continuation in continuations {
      continuation.resume()
    }
  }

  // MARK: - Private Methods

  private func startProcessing() {
    isProcessing = true
    runGeneration &+= 1
    let generation = runGeneration

    // 10.2.2 Optimization: Run queue processing in detached task to avoid blocking main actor
    // The processing loop itself runs off main thread, only UI updates hop to main actor
    processingTask = Task.detached { [weak self] in
      await self?.processQueue(generation: generation)
    }
  }

  /// Process the queue - runs in detached task, hops to main actor for state access
  /// Using nonisolated to actually run off main actor
  nonisolated private func processQueue(generation: UInt64) async {
    // Claim the next pending task on main actor (quick UI state read); a stale run stops
    while let taskToExecute = await MainActor.run(body: {
      self.claimNextTask(generation: generation)
    }) {
      // Check cancellation
      if Task.isCancelled {
        await MainActor.run {
          guard let index = self.tasks.firstIndex(where: { $0.id == taskToExecute.id }) else {
            return
          }
          self.tasks[index].state = .cancelled
          if self.currentTask?.id == taskToExecute.id { self.currentTask = nil }
          self.notifyTaskCompletion(cellId: taskToExecute.cellId, state: .cancelled)
        }
        continue
      }

      // Execute the task on main actor (the callback handles UI updates internally)
      let result = await self.executeTaskOnMainActor(taskToExecute)

      // Update state on main actor based on result
      await MainActor.run {
        self.updateTaskResult(taskId: taskToExecute.id, result: result)
      }
    }
  }

  /// The next pending task, marked executing, for the run `generation`. Nil when that run must
  /// stop: it was replaced (`cancelAll`, then a new run), or nothing is pending (the queue
  /// becomes idle).
  private func claimNextTask(generation: UInt64) -> ExecutionTask? {
    guard isProcessing, runGeneration == generation else { return nil }
    guard let index = tasks.firstIndex(where: { $0.state == .pending }) else {
      // No more pending tasks
      isProcessing = false
      currentTask = nil
      notifyIdle()
      return nil
    }
    tasks[index].state = .executing
    currentTask = tasks[index]
    // Notify any waiters that this task started executing
    notifyTaskExecuting(cellId: tasks[index].cellId)
    return tasks[index]
  }

  // MARK: - Private Helpers

  /// Execute task callback on main actor (async wrapper for nonisolated context)
  @MainActor
  private func executeTaskOnMainActor(_ task: ExecutionTask) async -> CellResult? {
    await executeTask(task)
  }

  /// Update task result and auto-clear old tasks
  private func updateTaskResult(taskId: UUID, result: CellResult?) {
    // Re-find the task by ID since the array may have changed during await
    // A run stopped by `cancelAll` must not clear the task of the run started after it
    if currentTask?.id == taskId { currentTask = nil }
    guard let updatedIndex = tasks.firstIndex(where: { $0.id == taskId }) else {
      return
    }

    let cellId = tasks[updatedIndex].cellId

    // Check if task was cancelled during execution
    if tasks[updatedIndex].state == .cancelled {
      notifyTaskCompletion(cellId: cellId, state: .cancelled)
      return
    }

    // Update state based on result
    let finalState: ExecutionState
    if let result = result {
      finalState = .completed(result)
    } else {
      finalState = .failed("Execution returned no result")
    }
    tasks[updatedIndex].state = finalState

    // Notify any waiters for this specific task
    notifyTaskCompletion(cellId: cellId, state: finalState)

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
