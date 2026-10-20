//
//  ConnectionAppearance.swift
//  Dblore
//

import Foundation

/// Saved connections listed under their group name.
nonisolated struct ConnectionGroup: Sendable {
  /// Nil for connections without a group.
  let name: String?
  let entries: [ConnectionHistoryEntry]
}

nonisolated enum ConnectionAppearance {
  /// Groups sorted by name (case-insensitive, localized), ungrouped last. Entries keep their
  /// input order within a group. Names differing only in case stay separate groups.
  static func grouped(_ entries: [ConnectionHistoryEntry]) -> [ConnectionGroup] {
    var byName: [String: [ConnectionHistoryEntry]] = [:]
    var ungrouped: [ConnectionHistoryEntry] = []
    for entry in entries {
      if let name = entry.config.groupName {
        byName[name, default: []].append(entry)
      } else {
        ungrouped.append(entry)
      }
    }
    let names = byName.keys.sorted { lhs, rhs in
      let order = lhs.localizedCaseInsensitiveCompare(rhs)
      return order == .orderedSame ? lhs < rhs : order == .orderedAscending
    }
    var groups = names.map { ConnectionGroup(name: $0, entries: byName[$0] ?? []) }
    if !ungrouped.isEmpty { groups.append(ConnectionGroup(name: nil, entries: ungrouped)) }
    return groups
  }
}
