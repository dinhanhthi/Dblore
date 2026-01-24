# Phase 9: Schema Visualizer

## Overview

Interactive database schema visualization with foreign key relationships displayed as an ER diagram. Tables appear as cards with columns, connected by lines showing relationships.

**Status:** COMPLETED

---

## Features

### Core Features
- **Interactive Graph View**: Pan, zoom, drag nodes
- **Foreign Key Visualization**: Lines connecting tables show FK relationships
- **ER Notation**: Standard crow's foot notation for cardinality (one, many, zero-or-one, zero-or-many)
- **Node Selection**: Click to select, double-click to expand in sidebar
- **Edge Selection**: Click on connection lines to highlight related tables

### Column Attributes (SF Symbols)
| Symbol | SF Symbol | Color | Description |
|--------|-----------|-------|-------------|
| 🔑 | `key.fill` | Yellow | Primary Key |
| # | `number` | Blue | Identity column |
| 👆 | `touchid` | Purple | Unique constraint |
| ◇ | `diamond` | Gray | Nullable |
| ◆ | `diamond.fill` | Gray | Not Null |

### ER Notation (Connection Lines)
| Symbol | Description |
|--------|-------------|
| `|` | One (single vertical line) |
| `<` | Many (crow's foot - 3 lines spreading) |
| `O|` | Zero or One (circle + line) |
| `O<` | Zero or Many (circle + crow's foot) |

### UI Features
- **Footer Legend**: Shows all symbol descriptions at bottom of canvas
- **Hover Effects**: Connection lines glow on hover, highlight connected tables after 300ms delay
- **Expand Button**: Small button on card header to expand table in sidebar (same as double-click)
- **Zoom Controls**: +/- buttons, scroll wheel, pinch gesture (0.25x - 3x)

---

## Architecture

### Data Flow
```
User clicks "Visualize Schema" in LeftSidebar
    ↓
NotebookViewModel.showSchemaVisualizer()
    ↓
SchemaVisualizerContent (replaces main body)
    ├── Header (back, zoom controls, refresh)
    ├── SchemaGraphView (NSViewRepresentable + Core Graphics)
    └── Footer Legend (symbol descriptions)
```

### Key Files
| File | Purpose |
|------|---------|
| `Models/ForeignKey.swift` | FK model with source/target tables and columns |
| `Models/SchemaGraph.swift` | Graph model (nodes = tables, edges = FKs) |
| `Database/DatabaseConnectionManager+ForeignKeys.swift` | Fetch FKs from PostgreSQL |
| `Utilities/SchemaLayoutEngine.swift` | Force-directed layout algorithm |
| `Views/Components/SchemaGraphView.swift` | Core Graphics rendering (NSView) |
| `Views/Sidebars/SchemaVisualizerContent.swift` | SwiftUI wrapper with header/footer |
| `ViewModels/NotebookViewModel+SchemaVisualizer.swift` | State management |

### Column Detection (Database Query)
```sql
-- Identity detection
SELECT is_identity FROM information_schema.columns

-- Unique constraint detection
SELECT a.attname FROM pg_index i
JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
WHERE i.indisunique AND NOT i.indisprimary AND array_length(i.indkey, 1) = 1
```

---

## Implementation Notes

### Hover Delay for Table Highlighting
When hovering over a connection line, there's a 300ms delay before highlighting connected tables. This prevents visual noise when moving mouse around the canvas.

```swift
// Timer-based hover delay
edgeHoverTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
    self.highlightedEdgeId = edge.id
    self.needsDisplay = true
}
```

### Drawing SF Symbols in Core Graphics
```swift
private func drawSFSymbol(_ name: String, at point: CGPoint, color: NSColor, font: NSFont) {
    if let symbolImage = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
        let config = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .medium)
        let configuredImage = symbolImage.withSymbolConfiguration(config)
        // Apply color tint using lockFocus/fill
        ...
    }
}
```

### Edge Hit Testing
Uses distance-to-segment calculation for orthogonal paths:
```swift
private func distanceToSegment(point: CGPoint, segmentStart: CGPoint, segmentEnd: CGPoint) -> CGFloat
```

### Force-Directed Layout
Parameters:
- Repulsion strength: 5000
- Attraction strength: 0.01
- Damping: 0.85
- Iterations: 150

---

## Visual Design

### Node Card
```
┌─────────────────────────┐
│  users              [↗] │  ← Table name + expand button
├─────────────────────────┤
│ 🔑◆ id          INTEGER │  ← Icons + name + type
│   ◇ email       VARCHAR │
│   ◇ created_at  TIMESTAMP│
└─────────────────────────┘
```

### Connection Line
```
[Table A] ──O<────────|O── [Table B]
           ↑              ↑
      zero-or-many       zero-or-one
      (FK side)          (PK side)
```

### Colors
- Line normal: `foregroundMuted` (opacity 0.5)
- Line highlighted: `accent` with glow shadow
- Node border normal: `border`
- Node border selected/highlighted: `accent`

---

## Tips & Gotchas

1. **NSView vs SwiftUI Canvas**: Use `NSViewRepresentable` with Core Graphics for better performance with many nodes

2. **Mouse Tracking**: Setup `NSTrackingArea` with `.mouseMoved` option to detect hover

3. **Coordinate Transform**: Remember to convert screen → canvas coordinates for hit testing:
   ```swift
   let canvasPoint = CGPoint(
       x: (screenPoint.x - offset.x) / scale,
       y: (screenPoint.y - offset.y) / scale
   )
   ```

4. **isFlipped**: Set `override var isFlipped: Bool { true }` for consistent coordinate system

5. **Timer invalidation**: Always invalidate timers on mouse exit to prevent memory leaks
