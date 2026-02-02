//
//  SchemaEdgeRouter.swift
//  SQLNotebook
//
//  Orthogonal edge routing algorithm to avoid node intersections
//

import CoreGraphics
import Foundation

/// Routes edges around nodes using orthogonal (90-degree) paths
/// Uses a simplified A* pathfinding approach for edge routing
struct SchemaEdgeRouter {

  /// Margin around nodes for edge routing
  private let nodeMargin: CGFloat = 30

  /// Grid cell size for pathfinding
  private let gridSize: CGFloat = 20

  /// Represents a routed edge path with multiple waypoints
  struct RoutedPath {
    let points: [CGPoint]

    var startPoint: CGPoint { points.first ?? .zero }
    var endPoint: CGPoint { points.last ?? .zero }

    /// Get the second point for ER notation direction calculation
    var secondPoint: CGPoint {
      points.count > 1 ? points[1] : startPoint
    }

    /// Get the second-to-last point for ER notation direction calculation
    var secondToLastPoint: CGPoint {
      points.count > 1 ? points[points.count - 2] : endPoint
    }
  }

  /// Calculate a routed path from source to target, avoiding obstacle nodes
  func routeEdge(
    from sourceRect: CGRect,
    to targetRect: CGRect,
    avoiding obstacleRects: [CGRect],
    edgeId: UUID
  ) -> RoutedPath {
    let sourceCenter = CGPoint(x: sourceRect.midX, y: sourceRect.midY)
    let targetCenter = CGPoint(x: targetRect.midX, y: targetRect.midY)

    let dx = targetCenter.x - sourceCenter.x
    let dy = targetCenter.y - sourceCenter.y

    // Determine connection points on source and target nodes
    let (startPoint, endPoint) = calculateConnectionPoints(
      sourceRect: sourceRect,
      targetRect: targetRect,
      dx: dx,
      dy: dy
    )

    // Check if direct path is clear (no obstacles)
    let directPathClear = isPathClear(
      from: startPoint,
      to: endPoint,
      avoiding: obstacleRects,
      sourceRect: sourceRect,
      targetRect: targetRect
    )

    if directPathClear {
      // Use simple orthogonal path
      return createSimpleOrthogonalPath(
        from: startPoint,
        to: endPoint,
        horizontalFirst: abs(dx) > abs(dy)
      )
    }

    // Need to route around obstacles
    return routeAroundObstacles(
      from: startPoint,
      to: endPoint,
      sourceRect: sourceRect,
      targetRect: targetRect,
      obstacles: obstacleRects
    )
  }

  /// Calculate where edges should connect to source and target nodes
  private func calculateConnectionPoints(
    sourceRect: CGRect,
    targetRect: CGRect,
    dx: CGFloat,
    dy: CGFloat
  ) -> (start: CGPoint, end: CGPoint) {
    var startPoint: CGPoint
    var endPoint: CGPoint

    if abs(dx) > abs(dy) {
      // Horizontal dominant
      if dx > 0 {
        startPoint = CGPoint(x: sourceRect.maxX, y: sourceRect.midY)
        endPoint = CGPoint(x: targetRect.minX, y: targetRect.midY)
      } else {
        startPoint = CGPoint(x: sourceRect.minX, y: sourceRect.midY)
        endPoint = CGPoint(x: targetRect.maxX, y: targetRect.midY)
      }
    } else {
      // Vertical dominant
      if dy > 0 {
        startPoint = CGPoint(x: sourceRect.midX, y: sourceRect.maxY)
        endPoint = CGPoint(x: targetRect.midX, y: targetRect.minY)
      } else {
        startPoint = CGPoint(x: sourceRect.midX, y: sourceRect.minY)
        endPoint = CGPoint(x: targetRect.midX, y: targetRect.maxY)
      }
    }

    return (startPoint, endPoint)
  }

  /// Check if a direct orthogonal path is clear of obstacles
  private func isPathClear(
    from start: CGPoint,
    to end: CGPoint,
    avoiding obstacles: [CGRect],
    sourceRect: CGRect,
    targetRect: CGRect
  ) -> Bool {
    // Create the simple orthogonal path segments
    let midX = (start.x + end.x) / 2
    let midY = (start.y + end.y) / 2

    let segments: [(CGPoint, CGPoint)]
    if abs(end.x - start.x) > abs(end.y - start.y) {
      // Horizontal first
      let mid1 = CGPoint(x: midX, y: start.y)
      let mid2 = CGPoint(x: midX, y: end.y)
      segments = [(start, mid1), (mid1, mid2), (mid2, end)]
    } else {
      // Vertical first
      let mid1 = CGPoint(x: start.x, y: midY)
      let mid2 = CGPoint(x: end.x, y: midY)
      segments = [(start, mid1), (mid1, mid2), (mid2, end)]
    }

    // Check each segment against obstacles
    for obstacle in obstacles {
      // Skip source and target rects
      if obstacle.intersects(sourceRect) || obstacle.intersects(targetRect) {
        continue
      }

      let expandedObstacle = obstacle.insetBy(dx: -nodeMargin / 2, dy: -nodeMargin / 2)

      for (segStart, segEnd) in segments {
        if lineIntersectsRect(from: segStart, to: segEnd, rect: expandedObstacle) {
          return false
        }
      }
    }

    return true
  }

  /// Create a simple orthogonal path with one bend
  private func createSimpleOrthogonalPath(
    from start: CGPoint,
    to end: CGPoint,
    horizontalFirst: Bool
  ) -> RoutedPath {
    let midX = (start.x + end.x) / 2
    let midY = (start.y + end.y) / 2

    if horizontalFirst {
      let mid1 = CGPoint(x: midX, y: start.y)
      let mid2 = CGPoint(x: midX, y: end.y)
      return RoutedPath(points: [start, mid1, mid2, end])
    } else {
      let mid1 = CGPoint(x: start.x, y: midY)
      let mid2 = CGPoint(x: end.x, y: midY)
      return RoutedPath(points: [start, mid1, mid2, end])
    }
  }

  /// Route edge around obstacles using waypoints
  private func routeAroundObstacles(
    from start: CGPoint,
    to end: CGPoint,
    sourceRect: CGRect,
    targetRect: CGRect,
    obstacles: [CGRect]
  ) -> RoutedPath {
    // Filter obstacles to only those that might be in the way
    let relevantObstacles = obstacles.filter { obstacle in
      !obstacle.intersects(sourceRect) && !obstacle.intersects(targetRect)
    }

    guard !relevantObstacles.isEmpty else {
      return createSimpleOrthogonalPath(
        from: start,
        to: end,
        horizontalFirst: abs(end.x - start.x) > abs(end.y - start.y)
      )
    }

    // Try different routing strategies and pick the best one
    var bestPath: RoutedPath?
    var bestScore = CGFloat.infinity

    // Strategy 1: Route above all obstacles
    if let path = tryRouteAbove(
      from: start, to: end, obstacles: relevantObstacles, sourceRect: sourceRect,
      targetRect: targetRect)
    {
      let score = pathScore(path, obstacles: relevantObstacles)
      if score < bestScore {
        bestScore = score
        bestPath = path
      }
    }

    // Strategy 2: Route below all obstacles
    if let path = tryRouteBelow(
      from: start, to: end, obstacles: relevantObstacles, sourceRect: sourceRect,
      targetRect: targetRect)
    {
      let score = pathScore(path, obstacles: relevantObstacles)
      if score < bestScore {
        bestScore = score
        bestPath = path
      }
    }

    // Strategy 3: Route to the left of obstacles
    if let path = tryRouteLeft(
      from: start, to: end, obstacles: relevantObstacles, sourceRect: sourceRect,
      targetRect: targetRect)
    {
      let score = pathScore(path, obstacles: relevantObstacles)
      if score < bestScore {
        bestScore = score
        bestPath = path
      }
    }

    // Strategy 4: Route to the right of obstacles
    if let path = tryRouteRight(
      from: start, to: end, obstacles: relevantObstacles, sourceRect: sourceRect,
      targetRect: targetRect)
    {
      let score = pathScore(path, obstacles: relevantObstacles)
      if score < bestScore {
        bestScore = score
        bestPath = path
      }
    }

    // Fallback to simple path if no good route found
    return bestPath
      ?? createSimpleOrthogonalPath(
        from: start,
        to: end,
        horizontalFirst: abs(end.x - start.x) > abs(end.y - start.y)
      )
  }

  /// Try to route above all obstacles
  private func tryRouteAbove(
    from start: CGPoint,
    to end: CGPoint,
    obstacles: [CGRect],
    sourceRect: CGRect,
    targetRect: CGRect
  ) -> RoutedPath? {
    // Find the minimum Y of all obstacles
    let minY = obstacles.map { $0.minY }.min() ?? start.y
    let routeY = minY - nodeMargin

    // Don't route too far from the direct path
    let directMidY = (start.y + end.y) / 2
    guard abs(routeY - directMidY) < 500 else { return nil }

    // Create path: start -> up to routeY -> across -> down to end
    let point1 = CGPoint(x: start.x, y: routeY)
    let point2 = CGPoint(x: end.x, y: routeY)

    let path = RoutedPath(points: [start, point1, point2, end])

    // Verify path doesn't intersect obstacles
    if isRoutedPathClear(path, obstacles: obstacles, sourceRect: sourceRect, targetRect: targetRect)
    {
      return path
    }
    return nil
  }

  /// Try to route below all obstacles
  private func tryRouteBelow(
    from start: CGPoint,
    to end: CGPoint,
    obstacles: [CGRect],
    sourceRect: CGRect,
    targetRect: CGRect
  ) -> RoutedPath? {
    let maxY = obstacles.map { $0.maxY }.max() ?? start.y
    let routeY = maxY + nodeMargin

    let directMidY = (start.y + end.y) / 2
    guard abs(routeY - directMidY) < 500 else { return nil }

    let point1 = CGPoint(x: start.x, y: routeY)
    let point2 = CGPoint(x: end.x, y: routeY)

    let path = RoutedPath(points: [start, point1, point2, end])

    if isRoutedPathClear(path, obstacles: obstacles, sourceRect: sourceRect, targetRect: targetRect)
    {
      return path
    }
    return nil
  }

  /// Try to route to the left of all obstacles
  private func tryRouteLeft(
    from start: CGPoint,
    to end: CGPoint,
    obstacles: [CGRect],
    sourceRect: CGRect,
    targetRect: CGRect
  ) -> RoutedPath? {
    let minX = obstacles.map { $0.minX }.min() ?? start.x
    let routeX = minX - nodeMargin

    let directMidX = (start.x + end.x) / 2
    guard abs(routeX - directMidX) < 500 else { return nil }

    let point1 = CGPoint(x: routeX, y: start.y)
    let point2 = CGPoint(x: routeX, y: end.y)

    let path = RoutedPath(points: [start, point1, point2, end])

    if isRoutedPathClear(path, obstacles: obstacles, sourceRect: sourceRect, targetRect: targetRect)
    {
      return path
    }
    return nil
  }

  /// Try to route to the right of all obstacles
  private func tryRouteRight(
    from start: CGPoint,
    to end: CGPoint,
    obstacles: [CGRect],
    sourceRect: CGRect,
    targetRect: CGRect
  ) -> RoutedPath? {
    let maxX = obstacles.map { $0.maxX }.max() ?? start.x
    let routeX = maxX + nodeMargin

    let directMidX = (start.x + end.x) / 2
    guard abs(routeX - directMidX) < 500 else { return nil }

    let point1 = CGPoint(x: routeX, y: start.y)
    let point2 = CGPoint(x: routeX, y: end.y)

    let path = RoutedPath(points: [start, point1, point2, end])

    if isRoutedPathClear(path, obstacles: obstacles, sourceRect: sourceRect, targetRect: targetRect)
    {
      return path
    }
    return nil
  }

  /// Check if a routed path is clear of obstacles
  private func isRoutedPathClear(
    _ path: RoutedPath,
    obstacles: [CGRect],
    sourceRect: CGRect,
    targetRect: CGRect
  ) -> Bool {
    guard path.points.count >= 2 else { return false }

    for i in 0..<(path.points.count - 1) {
      let segStart = path.points[i]
      let segEnd = path.points[i + 1]

      for obstacle in obstacles {
        if obstacle.intersects(sourceRect) || obstacle.intersects(targetRect) {
          continue
        }

        let expandedObstacle = obstacle.insetBy(dx: -5, dy: -5)
        if lineIntersectsRect(from: segStart, to: segEnd, rect: expandedObstacle) {
          return false
        }
      }
    }
    return true
  }

  /// Calculate a score for a path (lower is better)
  private func pathScore(_ path: RoutedPath, obstacles: [CGRect]) -> CGFloat {
    var totalLength: CGFloat = 0
    var bendCount: CGFloat = 0

    for i in 0..<(path.points.count - 1) {
      let p1 = path.points[i]
      let p2 = path.points[i + 1]
      totalLength += sqrt(pow(p2.x - p1.x, 2) + pow(p2.y - p1.y, 2))
    }

    // Count direction changes (bends)
    for i in 1..<(path.points.count - 1) {
      let p0 = path.points[i - 1]
      let p1 = path.points[i]
      let p2 = path.points[i + 1]

      let dir1 = CGPoint(x: p1.x - p0.x, y: p1.y - p0.y)
      let dir2 = CGPoint(x: p2.x - p1.x, y: p2.y - p1.y)

      // Check if direction changed
      if (dir1.x != 0 && dir2.x == 0) || (dir1.y != 0 && dir2.y == 0) {
        bendCount += 1
      }
    }

    // Penalize longer paths and more bends
    return totalLength + bendCount * 50
  }

  /// Check if a line segment intersects a rectangle
  private func lineIntersectsRect(from p1: CGPoint, to p2: CGPoint, rect: CGRect) -> Bool {
    // Quick bounding box check
    let lineMinX = min(p1.x, p2.x)
    let lineMaxX = max(p1.x, p2.x)
    let lineMinY = min(p1.y, p2.y)
    let lineMaxY = max(p1.y, p2.y)

    if lineMaxX < rect.minX || lineMinX > rect.maxX
      || lineMaxY < rect.minY || lineMinY > rect.maxY
    {
      return false
    }

    // Check if either endpoint is inside the rect
    if rect.contains(p1) || rect.contains(p2) {
      return true
    }

    // Check intersection with each edge of the rectangle
    let topLeft = CGPoint(x: rect.minX, y: rect.minY)
    let topRight = CGPoint(x: rect.maxX, y: rect.minY)
    let bottomLeft = CGPoint(x: rect.minX, y: rect.maxY)
    let bottomRight = CGPoint(x: rect.maxX, y: rect.maxY)

    return lineSegmentsIntersect(p1, p2, topLeft, topRight)
      || lineSegmentsIntersect(p1, p2, topRight, bottomRight)
      || lineSegmentsIntersect(p1, p2, bottomRight, bottomLeft)
      || lineSegmentsIntersect(p1, p2, bottomLeft, topLeft)
  }

  /// Check if two line segments intersect
  private func lineSegmentsIntersect(
    _ p1: CGPoint, _ p2: CGPoint,
    _ p3: CGPoint, _ p4: CGPoint
  ) -> Bool {
    let d1 = direction(p3, p4, p1)
    let d2 = direction(p3, p4, p2)
    let d3 = direction(p1, p2, p3)
    let d4 = direction(p1, p2, p4)

    if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0))
      && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
    {
      return true
    }

    if d1 == 0 && onSegment(p3, p4, p1) { return true }
    if d2 == 0 && onSegment(p3, p4, p2) { return true }
    if d3 == 0 && onSegment(p1, p2, p3) { return true }
    if d4 == 0 && onSegment(p1, p2, p4) { return true }

    return false
  }

  private func direction(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint) -> CGFloat {
    (p3.x - p1.x) * (p2.y - p1.y) - (p2.x - p1.x) * (p3.y - p1.y)
  }

  private func onSegment(_ p1: CGPoint, _ p2: CGPoint, _ p: CGPoint) -> Bool {
    p.x >= min(p1.x, p2.x) && p.x <= max(p1.x, p2.x)
      && p.y >= min(p1.y, p2.y) && p.y <= max(p1.y, p2.y)
  }
}
