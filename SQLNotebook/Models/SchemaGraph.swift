//
//  SchemaGraph.swift
//  SQLNotebook
//
//  Models for schema visualization graph
//

import CoreGraphics
import Foundation

/// Represents a node in the schema graph (a database table)
struct SchemaNode: Identifiable, Sendable, Equatable {
  let id: UUID
  let table: DatabaseTable
  var position: CGPoint
  var isSelected: Bool
  var width: CGFloat?  // Custom width set by user, nil means auto-calculated

  nonisolated init(
    id: UUID = UUID(),
    table: DatabaseTable,
    position: CGPoint = .zero,
    isSelected: Bool = false,
    width: CGFloat? = nil
  ) {
    self.id = id
    self.table = table
    self.position = position
    self.isSelected = isSelected
    self.width = width
  }

  /// Table qualified name for lookups
  var qualifiedName: String {
    table.qualifiedName
  }

  static func == (lhs: SchemaNode, rhs: SchemaNode) -> Bool {
    lhs.id == rhs.id
      && lhs.position == rhs.position
      && lhs.isSelected == rhs.isSelected
      && lhs.width == rhs.width
  }
}

/// Represents an edge in the schema graph (a foreign key relationship)
struct SchemaEdge: Identifiable, Sendable, Equatable {
  let id: UUID
  let foreignKey: ForeignKey
  let sourceNodeId: UUID
  let targetNodeId: UUID

  nonisolated init(
    id: UUID = UUID(),
    foreignKey: ForeignKey,
    sourceNodeId: UUID,
    targetNodeId: UUID
  ) {
    self.id = id
    self.foreignKey = foreignKey
    self.sourceNodeId = sourceNodeId
    self.targetNodeId = targetNodeId
  }

  /// Check if this edge connects to a given node
  func connectsTo(_ nodeId: UUID) -> Bool {
    sourceNodeId == nodeId || targetNodeId == nodeId
  }

  /// Check if this is a self-referencing edge
  var isSelfReferencing: Bool {
    sourceNodeId == targetNodeId
  }

  static func == (lhs: SchemaEdge, rhs: SchemaEdge) -> Bool {
    lhs.id == rhs.id
  }
}

/// Saved position for a schema node, keyed by table qualified name
struct SavedNodePosition: Codable, Sendable, Equatable {
  let tableQualifiedName: String
  let x: CGFloat
  let y: CGFloat
  let width: CGFloat?  // Custom width set by user

  var position: CGPoint {
    CGPoint(x: x, y: y)
  }

  nonisolated init(tableQualifiedName: String, position: CGPoint, width: CGFloat? = nil) {
    self.tableQualifiedName = tableQualifiedName
    self.x = position.x
    self.y = position.y
    self.width = width
  }
}

/// Represents the complete schema graph with nodes and edges
struct SchemaGraph: Sendable, Equatable {
  var nodes: [SchemaNode]
  var edges: [SchemaEdge]

  nonisolated init(nodes: [SchemaNode] = [], edges: [SchemaEdge] = []) {
    self.nodes = nodes
    self.edges = edges
  }

  /// Export current node positions for persistence
  func exportPositions() -> [SavedNodePosition] {
    nodes.map { node in
      SavedNodePosition(
        tableQualifiedName: node.qualifiedName,
        position: node.position,
        width: node.width
      )
    }
  }

  /// Apply saved positions to nodes
  mutating func applyPositions(_ savedPositions: [SavedNodePosition]) {
    let savedByName = Dictionary(
      savedPositions.map { ($0.tableQualifiedName, $0) },
      uniquingKeysWith: { first, _ in first }
    )

    for index in nodes.indices {
      if let saved = savedByName[nodes[index].qualifiedName] {
        nodes[index].position = saved.position
        nodes[index].width = saved.width
      }
    }
  }

  /// Find a node by its ID
  func node(withId id: UUID) -> SchemaNode? {
    nodes.first { $0.id == id }
  }

  /// Find a node by table qualified name
  func node(forTable qualifiedName: String) -> SchemaNode? {
    nodes.first { $0.qualifiedName == qualifiedName }
  }

  /// Get all edges connected to a node
  func edges(connectedTo nodeId: UUID) -> [SchemaEdge] {
    edges.filter { $0.connectsTo(nodeId) }
  }

  /// Get nodes that are connected to a given node via edges
  func connectedNodes(to nodeId: UUID) -> [SchemaNode] {
    let connectedEdges = edges(connectedTo: nodeId)
    var connectedIds = Set<UUID>()

    for edge in connectedEdges {
      if edge.sourceNodeId != nodeId {
        connectedIds.insert(edge.sourceNodeId)
      }
      if edge.targetNodeId != nodeId {
        connectedIds.insert(edge.targetNodeId)
      }
    }

    return nodes.filter { connectedIds.contains($0.id) }
  }

  /// Check if the graph is empty
  var isEmpty: Bool {
    nodes.isEmpty
  }

  /// Check if the graph has any relationships
  var hasRelationships: Bool {
    !edges.isEmpty
  }

  /// Get tables that have no foreign key relationships
  var isolatedNodes: [SchemaNode] {
    let connectedNodeIds = Set(edges.flatMap { [$0.sourceNodeId, $0.targetNodeId] })
    return nodes.filter { !connectedNodeIds.contains($0.id) }
  }

  /// Get tables that reference the given table (incoming edges)
  func referencingNodes(of nodeId: UUID) -> [SchemaNode] {
    let sourceIds = edges.filter { $0.targetNodeId == nodeId }.map { $0.sourceNodeId }
    return nodes.filter { sourceIds.contains($0.id) }
  }

  /// Get tables that are referenced by the given table (outgoing edges)
  func referencedNodes(by nodeId: UUID) -> [SchemaNode] {
    let targetIds = edges.filter { $0.sourceNodeId == nodeId }.map { $0.targetNodeId }
    return nodes.filter { targetIds.contains($0.id) }
  }

  static func == (lhs: SchemaGraph, rhs: SchemaGraph) -> Bool {
    lhs.nodes == rhs.nodes && lhs.edges == rhs.edges
  }
}

// MARK: - Graph Builder

extension SchemaGraph {
  /// Build a schema graph from tables and foreign keys
  static func build(
    from tables: [DatabaseTable],
    foreignKeys: [ForeignKey]
  ) -> SchemaGraph {
    // Create nodes from tables
    var nodes: [SchemaNode] = []
    var nodeByQualifiedName: [String: UUID] = [:]

    for table in tables {
      let node = SchemaNode(table: table)
      nodes.append(node)
      nodeByQualifiedName[table.qualifiedName] = node.id
    }

    // Create edges from foreign keys
    var edges: [SchemaEdge] = []

    for fk in foreignKeys {
      guard
        let sourceNodeId = nodeByQualifiedName[fk.sourceQualifiedName],
        let targetNodeId = nodeByQualifiedName[fk.targetQualifiedName]
      else {
        // Skip if tables not found (might be filtered out)
        continue
      }

      let edge = SchemaEdge(
        foreignKey: fk,
        sourceNodeId: sourceNodeId,
        targetNodeId: targetNodeId
      )
      edges.append(edge)
    }

    return SchemaGraph(nodes: nodes, edges: edges)
  }
}
