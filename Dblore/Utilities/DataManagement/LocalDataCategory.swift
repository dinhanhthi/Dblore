// LocalDataCategory.swift
// The local data a person can export or remove. Secrets are a separate inventory.

import Foundation

extension Notification.Name {
  /// Posted after a category is cleared or replaced. `userInfo` holds `LocalDataCategory.userInfoKey`.
  nonisolated static let localDataChanged = Notification.Name("localDataChanged")
}

/// One kind of data the app stores on this Mac, excluding Keychain secrets.
nonisolated enum LocalDataCategory: String, CaseIterable, Sendable {
  case queryHistory
  case connectionHistory
  case recentItems
  case openTabs
  case savedFilters
  case schemaLayout
  case aiChats
  case aiSettings
  case localModels
  case logs
  case appSettings

  /// Key in the `localDataChanged` userInfo dictionary. The value is `rawValue`.
  nonisolated static let userInfoKey = "category"

  /// True when `notification` names `category`, or names no category (everything changed).
  static func notification(_ notification: Notification, includes category: Self) -> Bool {
    guard let info = notification.userInfo, info[userInfoKey] != nil else { return true }
    return (info[userInfoKey] as? String) == category.rawValue
  }

  var title: String {
    switch self {
    case .queryHistory: "Query History"
    case .connectionHistory: "Connection History"
    case .recentItems: "Recent Workspaces and Files"
    case .openTabs: "Open Tabs"
    case .savedFilters: "Saved Filters and Highlights"
    case .schemaLayout: "Schema Diagram Layout"
    case .aiChats: "AI Chats"
    case .aiSettings: "AI Settings"
    case .localModels: "Local AI Models"
    case .logs: "Logs"
    case .appSettings: "App Settings"
    }
  }

  /// SF Symbol used beside the title.
  var symbolName: String {
    switch self {
    case .queryHistory: "clock.arrow.circlepath"
    case .connectionHistory: "server.rack"
    case .recentItems: "clock"
    case .openTabs: "square.stack"
    case .savedFilters: "line.3.horizontal.decrease.circle"
    case .schemaLayout: "point.3.connected.trianglepath.dotted"
    case .aiChats: "bubble.left.and.bubble.right"
    case .aiSettings: "slider.horizontal.3"
    case .localModels: "cpu"
    case .logs: "doc.text"
    case .appSettings: "gearshape"
    }
  }

  var description: String {
    switch self {
    case .queryHistory: "Statements you have run"
    case .connectionHistory: "Saved database connections, without passwords"
    case .recentItems: "Workspaces and files you opened recently"
    case .openTabs: "Tabs restored at the next launch. Open tabs stay until you quit."
    case .savedFilters: "Filters and highlights saved for tables"
    case .schemaLayout: "Positions of tables on the schema diagram"
    case .aiChats: "Conversations with the AI assistant"
    case .aiSettings: "Provider and model choices, without API keys"
    case .localModels: "On-device models downloaded for local AI"
    case .logs: "Diagnostic log files"
    case .appSettings: "Appearance, editor, and other preferences"
    }
  }

  /// Local AI models are large enough that a full backup should leave them out unless asked.
  var isLarge: Bool { self == .localModels }
}

/// Removes its `localDataChanged` token when released, so the owner stops observing on deinit.
nonisolated final class LocalDataChangeObserver: @unchecked Sendable {
  private var token: NSObjectProtocol?

  func start(_ handle: @escaping @Sendable (Notification) -> Void) {
    guard token == nil else { return }
    token = NotificationCenter.default.addObserver(
      forName: .localDataChanged, object: nil, queue: .main, using: handle)
  }

  deinit {
    if let token {
      NotificationCenter.default.removeObserver(token)
    }
  }
}

/// How much of one category is on disk.
nonisolated struct LocalDataSummary: Equatable, Sendable {
  var bytes: Int64
  var itemCount: Int
  var location: URL?
}

/// Reads, exports, replaces, and clears one `LocalDataCategory`.
nonisolated protocol LocalDataProvider: Sendable {
  var category: LocalDataCategory { get }
  func summary() async -> LocalDataSummary
  func export(to folder: URL) async throws
  func importData(from folder: URL) async throws
  func clear() async throws
}
