# SQL Autocomplete Feature

**Status:** ✅ Completed
**Date:** 2025-01-06
**Phase:** 5.4 (Advanced Features)

## Overview

SQL autocomplete system that provides intelligent suggestions for keywords, table names, and column names while typing queries. Features context-aware filtering, keyboard navigation, and accurate popup positioning.

## Key Features

### 1. **Smart Suggestions**
- **95+ SQL keywords**: DML (SELECT, JOIN), DDL (CREATE, ALTER), PostgreSQL-specific (RETURNING, LATERAL)
- **Database schema**: Table names and column names from connected database
- **Context-aware filtering**:
  - After `FROM`/`JOIN` → suggest tables
  - After `SELECT`/`WHERE` → suggest **only columns from tables in FROM clause**
  - **Table alias support**: `FROM customers c` → recognizes `c` as `customers`

### 2. **Keyboard Navigation**
- Up/Down arrows with circular wrapping
- Tab/Enter to accept, Escape to dismiss
- No conflicts with cell navigation shortcuts

### 3. **Accurate Positioning**
- NSPopover-based popup positioned below cursor
- Stable position while typing
- Auto-dismisses when clicking outside

## Architecture

### Core Components
- `SQLAutocompleteProvider.swift` - Autocomplete logic, schema parsing, suggestion filtering
- `AutocompletePopupView.swift` - SwiftUI popup UI with color-coded icons
- `SQLTextView.swift` - NSTextView integration with NSPopover positioning

### Key Implementation Details

#### Table Reference Parsing (NEW - 2025-01-06)
```swift
// Extract tables and aliases from FROM/JOIN clauses
func extractTableReferences(from text: String) -> [String: String]
// Example: "FROM customers c JOIN orders o"
// Returns: ["customers": "public.customers", "c": "public.customers",
//           "orders": "public.orders", "o": "public.orders"]

// Filter columns to only show from referenced tables
if !tableRefs.isEmpty {
  // Only suggest columns from tables in FROM clause
} else {
  // Fallback: show all columns if no FROM clause yet
}
```

**Supported patterns:**
- Simple: `FROM customers WHERE e` → only `customers` columns
- Aliases: `FROM customers c WHERE c.e` → recognizes `c` alias
- JOINs: `FROM customers c JOIN orders o` → columns from both tables
- Multiple JOINs: LEFT/RIGHT/FULL/CROSS JOIN variants

#### NSPopover Positioning
```swift
// Force layout update before calculating position
layoutManager.ensureLayout(for: textContainer)

// Get glyph rect and position at END (maxX) to place popup after typed text
let glyphIndex = layoutManager.glyphIndexForCharacter(at: max(0, cursorPosition - 1))
let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textContainer)

// Convert to local coordinates and show popover
popover.show(relativeTo: localRect, of: self, preferredEdge: .maxY)
```

## Major Issues & Solutions

### Issue 1: Popup Position Unstable While Typing
**Root cause:** Layout manager not updated before calculating glyph rect → stale positions
**Solution:** Call `layoutManager.ensureLayout(for: textContainer)` before position calculation

### Issue 2: Popup Not Repositioning on Text Change
**Root cause:** Only updated popup content, not position
**Solution:** Reposition existing popover on every keystroke: `if popover.isShown { popover.show(...) }`

### Issue 3: Ghost Popup When Text Deleted
**Root cause:** No early exit when text becomes empty
**Solution:** Check `string.isEmpty` before showing suggestions

### Issue 4: SwiftUI-AppKit Coordinate Conversion Unreliable
**Root cause:** `.frame(in: .global)` didn't work reliably across SwiftUI/AppKit boundary
**Solution:** Use pure AppKit NSPopover with `firstRect(forCharacterRange:)` for screen coordinates, then convert to local

### Issue 5: Column Suggestions Show All Tables (NEW - Fixed 2025-01-06)
**Root cause:** No parsing of FROM clause to determine table scope
**Solution:** Added `extractTableReferences()` to parse FROM/JOIN clauses and filter columns by referenced tables

## Known Limitations

1. **No subquery support**: Doesn't parse nested SELECT statements
2. **No CTE awareness**: WITH clauses not detected
3. **Schema cache**: Only refreshes on connect/disconnect (limit 50 tables)
4. **Simple keyword matching**: No SQL syntax tree parsing

## Testing Checklist

- [ ] `SELECT * FROM customers WHERE e` → only shows `email` from `customers`
- [ ] `FROM customers c WHERE c.e` → alias `c` works
- [ ] `FROM analytics_events ae WHERE ae.e` → shows `event_type`, `event_timestamp` (not `customers` columns)
- [ ] `FROM customers JOIN orders ON` → shows columns from both tables
- [ ] No FROM clause → shows all columns (fallback)
- [ ] Popup stable while typing
- [ ] Up/Down navigation works, wraps circularly
- [ ] Tab/Enter accepts suggestion
- [ ] Escape dismisses popup

## References

**Inspiration:**
- [NCRAutocompleteTextView](https://github.com/danjonweb/NCRAutocompleteTextView) - NSPopover positioning approach
- [Swift port by martinpi](https://gist.github.com/martinpi/5e5ca6f0df035145402bf2f288055dfd) - Coordinate conversion

**Related files:**
- `DatabaseConnectionManager+Schema.swift` - Schema introspection
- `NotebookViewModel+Connection.swift` - Schema refresh on connect

---

**Contributors:** Claude Sonnet 4.5 (AI Assistant), User feedback and testing
