//
//  AppLogger+FileManagement.swift
//  SQLNotebook
//
//  File operations for logging - write to file, cleanup, statistics
//

import Foundation

// MARK: - File Management

extension AppLogger {
  /// Write log entry to file
  func writeToFile(entry: LogEntry, fileURL: URL) async {
    let logLine = entry.formattedLine + "\n"

    guard let data = logLine.data(using: .utf8) else { return }

    // Check file size before writing to prevent disk issues
    if let currentSize = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size]
      as? Int64
    {
      if currentSize >= 10 * 1024 * 1024 {  // 10MB max
        // File is too large, skip writing
        print("Log file exceeded max size (10MB), skipping write")
        return
      }
    }

    do {
      if FileManager.default.fileExists(atPath: fileURL.path) {
        // Append to existing file
        let fileHandle = try FileHandle(forWritingTo: fileURL)
        try fileHandle.seekToEnd()
        try fileHandle.write(contentsOf: data)
        try fileHandle.close()
      } else {
        // Create new file
        try data.write(to: fileURL)
      }
    } catch {
      // Fallback to print if file writing fails
      print("Failed to write log to file: \(error)")
    }
  }

  /// Clean up log files older than retention period (7 days)
  func cleanupOldLogFiles() async {
    let fileManager = FileManager.default
    guard
      let appSupportURL = fileManager.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first
    else {
      return
    }

    let logDirectory = appSupportURL.appendingPathComponent("SQLNotebook/Logs", isDirectory: true)

    // Get all log files in directory
    guard
      let files = try? fileManager.contentsOfDirectory(
        at: logDirectory,
        includingPropertiesForKeys: [.creationDateKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return
    }

    let cutoffDate = Calendar.current.date(byAdding: .day, value: -7, to: Date())!  // 7 days retention

    var deletedCount = 0
    var totalSizeFreed: Int64 = 0

    for fileURL in files {
      // Only process .log files
      guard fileURL.pathExtension == "log" else { continue }

      // Get file creation date
      guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
        let creationDate = attributes[.creationDate] as? Date
      else {
        continue
      }

      // Delete if older than retention period
      if creationDate < cutoffDate {
        if let fileSize = attributes[.size] as? Int64 {
          totalSizeFreed += fileSize
        }

        try? fileManager.removeItem(at: fileURL)
        deletedCount += 1
      }
    }

    if deletedCount > 0 {
      let sizeMB = Double(totalSizeFreed) / (1024 * 1024)
      print(
        "Cleaned up \(deletedCount) old log file(s), freed \(String(format: "%.2f", sizeMB)) MB")
    }
  }

  /// Export logs to a file
  func exportLogs(to url: URL) async throws {
    let allLogs = getAllLogs().map { $0.formattedLine }.joined(separator: "\n")
    try allLogs.write(to: url, atomically: true, encoding: .utf8)
  }

  /// Get all logs as formatted text (for synchronous export)
  /// Combines all log files within retention period (7 days)
  nonisolated func getAllLogsText() -> String {
    let fileManager = FileManager.default
    guard
      let appSupportURL = fileManager.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first
    else {
      return "No logs available"
    }

    let logDirectory = appSupportURL.appendingPathComponent("SQLNotebook/Logs", isDirectory: true)

    // Get all log files sorted by date (newest first)
    guard
      let files = try? fileManager.contentsOfDirectory(
        at: logDirectory,
        includingPropertiesForKeys: [.creationDateKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return "No logs available"
    }

    // Filter and sort log files by creation date (newest first)
    let logFiles =
      files
      .filter { $0.pathExtension == "log" }
      .sorted { file1, file2 in
        guard
          let date1 = try? fileManager.attributesOfItem(atPath: file1.path)[.creationDate]
            as? Date,
          let date2 = try? fileManager.attributesOfItem(atPath: file2.path)[.creationDate]
            as? Date
        else {
          return false
        }
        return date1 > date2  // Newest first
      }

    var combinedLogs = ""

    // Read and combine all log files
    for fileURL in logFiles {
      if let data = try? Data(contentsOf: fileURL),
        let content = String(data: data, encoding: .utf8)
      {
        let fileName = fileURL.lastPathComponent
        combinedLogs += "=== \(fileName) ===\n"
        combinedLogs += content
        if !content.hasSuffix("\n") {
          combinedLogs += "\n"
        }
        combinedLogs += "\n"
      }
    }

    return combinedLogs.isEmpty ? "No logs available" : combinedLogs
  }

  /// Get current log file URL
  func getLogFileURL() -> URL {
    let fileManager = FileManager.default
    let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first!
    let logDirectory = appSupportURL.appendingPathComponent("SQLNotebook/Logs", isDirectory: true)

    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd"
    let dateString = dateFormatter.string(from: Date())

    return logDirectory.appendingPathComponent("sqlnotebook-\(dateString).log")
  }

  /// Get log file size
  func getLogFileSize() -> Int64? {
    let logFileURL = getLogFileURL()
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: logFileURL.path)
    else {
      return nil
    }
    return attributes[.size] as? Int64
  }

  /// Get statistics about all log files
  func getLogStatistics() -> (
    fileCount: Int, totalSize: Int64, oldestDate: Date?, newestDate: Date?
  ) {
    let fileManager = FileManager.default
    guard
      let appSupportURL = fileManager.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first
    else {
      return (0, 0, nil, nil)
    }

    let logDirectory = appSupportURL.appendingPathComponent("SQLNotebook/Logs", isDirectory: true)

    guard
      let files = try? fileManager.contentsOfDirectory(
        at: logDirectory,
        includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return (0, 0, nil, nil)
    }

    let logFiles = files.filter { $0.pathExtension == "log" }
    var totalSize: Int64 = 0
    var oldestDate: Date?
    var newestDate: Date?

    for fileURL in logFiles {
      if let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path) {
        // Sum up file sizes
        if let fileSize = attributes[.size] as? Int64 {
          totalSize += fileSize
        }

        // Track oldest and newest dates
        if let creationDate = attributes[.creationDate] as? Date {
          if oldestDate == nil || creationDate < oldestDate! {
            oldestDate = creationDate
          }
          if newestDate == nil || creationDate > newestDate! {
            newestDate = creationDate
          }
        }
      }
    }

    return (logFiles.count, totalSize, oldestDate, newestDate)
  }
}
