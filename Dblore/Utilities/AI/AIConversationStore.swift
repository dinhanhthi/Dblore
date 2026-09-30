// AIConversationStore.swift
// Saved AI assistant conversations of one workspace, stored as a JSON file in Application Support

import Foundation

struct AIConversation: Codable, Identifiable, Equatable {
  let id: UUID
  var title: String
  var updatedAt: Date
  var messages: [AIChatEntry]
}

final class AIConversationStore {
  private let fileURL: URL

  init(fileURL: URL) {
    self.fileURL = fileURL
  }

  convenience init(workspaceId: UUID, root: URL = AIConversationStore.defaultRoot) {
    self.init(fileURL: root.appendingPathComponent("\(workspaceId.uuidString).json"))
  }

  nonisolated static var defaultRoot: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Dblore", isDirectory: true)
      .appendingPathComponent("AIChats", isDirectory: true)
  }

  func load() -> [AIConversation] {
    guard let data = try? Data(contentsOf: fileURL),
      let conversations = try? JSONDecoder().decode([AIConversation].self, from: data)
    else { return [] }
    return conversations
  }

  func save(_ conversations: [AIConversation]) {
    guard let data = try? JSONEncoder().encode(conversations) else { return }
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: fileURL, options: .atomic)
    } catch {
      let message = "Failed to save AI conversations: \(error)"
      Task { await AppLogger.shared.error(message, category: "AI") }
    }
  }
}
