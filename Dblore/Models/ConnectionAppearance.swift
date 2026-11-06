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

/// One level of a group path (`ConnectionConfig.normalizedGroupName`): the connections filed
/// at this level and its subgroups.
nonisolated struct ConnectionGroupNode: Sendable {
  /// This level's name, the last part of `path`
  let name: String
  /// The levels up to this one joined with `ConnectionAppearance.pathSeparator`; unique, so it
  /// identifies the node
  let path: String
  /// 0 for a top-level group, at most 2
  let depth: Int
  let entries: [ConnectionHistoryEntry]
  let children: [ConnectionGroupNode]
}

/// Saved connections as group trees, and those without a group.
nonisolated struct ConnectionTree: Sendable {
  let groups: [ConnectionGroupNode]
  let ungrouped: [ConnectionHistoryEntry]
}

nonisolated enum ConnectionAppearance {
  /// Joins the levels of a normalized group path
  static let pathSeparator = " / "

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
    let names = byName.keys.sorted(by: isOrderedBefore)
    var groups = names.map { ConnectionGroup(name: $0, entries: byName[$0] ?? []) }
    if !ungrouped.isEmpty { groups.append(ConnectionGroup(name: nil, entries: ungrouped)) }
    return groups
  }

  /// Groups nested by path level, each level sorted as `grouped` sorts names, ungrouped
  /// connections apart. Entries keep their input order within a level.
  static func tree(_ entries: [ConnectionHistoryEntry]) -> ConnectionTree {
    var filed: [(levels: ArraySlice<String>, entry: ConnectionHistoryEntry)] = []
    var ungrouped: [ConnectionHistoryEntry] = []
    for entry in entries {
      if let path = entry.config.groupName {
        filed.append((path.components(separatedBy: pathSeparator)[...], entry))
      } else {
        ungrouped.append(entry)
      }
    }
    return ConnectionTree(groups: nodes(filed, parent: nil, depth: 0), ungrouped: ungrouped)
  }

  /// `nodes` in pre-order, without the subgroups of a node whose path is in `collapsed`.
  static func flattened(
    _ nodes: [ConnectionGroupNode], collapsed: Set<String> = []
  ) -> [ConnectionGroupNode] {
    nodes.flatMap { node in
      [node] + (collapsed.contains(node.path) ? [] : flattened(node.children, collapsed: collapsed))
    }
  }

  private static func nodes(
    _ filed: [(levels: ArraySlice<String>, entry: ConnectionHistoryEntry)], parent: String?,
    depth: Int
  ) -> [ConnectionGroupNode] {
    var byName: [String: [(levels: ArraySlice<String>, entry: ConnectionHistoryEntry)]] = [:]
    for item in filed {
      guard let name = item.levels.first else { continue }
      byName[name, default: []].append((item.levels.dropFirst(), item.entry))
    }
    return byName.keys.sorted(by: isOrderedBefore).map { name in
      let items = byName[name] ?? []
      let path = parent.map { $0 + pathSeparator + name } ?? name
      return ConnectionGroupNode(
        name: name, path: path, depth: depth,
        entries: items.filter { $0.levels.isEmpty }.map(\.entry),
        children: nodes(items.filter { !$0.levels.isEmpty }, parent: path, depth: depth + 1))
    }
  }

  /// Case-insensitive, localized; names differing only in case keep a stable order
  private static func isOrderedBefore(_ lhs: String, _ rhs: String) -> Bool {
    let order = lhs.localizedCaseInsensitiveCompare(rhs)
    return order == .orderedSame ? lhs < rhs : order == .orderedAscending
  }
}
