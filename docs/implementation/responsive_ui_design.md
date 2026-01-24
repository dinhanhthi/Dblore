# Responsive UI Design in SQLNotebook

## Problem

The "Run with Query" bar and metadata bar in SQLNotebook display poorly when the window is resized to smaller widths. UI elements become cramped, text gets truncated, and the overall user experience degrades significantly. The app needs responsive design patterns that adapt the UI based on available space.

## Solution

Implement responsive UI patterns using SwiftUI's built-in tools to create adaptive layouts that respond to window width changes. Use a combination of `ViewThatFits` for automatic layout selection and `GeometryReader` for precise width-based control.

### Recommended Approaches

#### 1. ViewThatFits (Simplest, Automatic)

Best for simple toolbars and bars where you have 2-3 distinct layout variations.

**Example: Run with Query Bar**
```swift
struct RunWithQueryBar: View {
    var body: some View {
        ViewThatFits {
            // Full layout (tries this first)
            fullLayout

            // Compact layout (fallback)
            compactLayout
        }
    }

    private var fullLayout: some View {
        HStack(spacing: 12) {
            Button("Run") { }
            Button("Run with Query") { }
            Spacer()
            Text("Cell 1 of 10")
            Button("Settings") { }
        }
        .padding()
    }

    private var compactLayout: some View {
        HStack(spacing: 8) {
            Button("Run") { }
            Menu {
                Button("Run with Query") { }
                Button("Settings") { }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            Spacer()
            Text("1/10")
        }
        .padding(.horizontal, 8)
    }
}
```

**Pros:**
- Automatic layout selection
- Clean, declarative code
- No manual width calculations

**Cons:**
- Less control over exact breakpoints
- Limited to trying layouts in order

#### 2. GeometryReader (More Control)

Best for complex layouts where you need precise control over what shows at specific widths.

**Example: Metadata Bar with Progressive Disclosure**
```swift
struct MetadataBar: View {
    let metadata: [String: String]

    var body: some View {
        GeometryReader { geometry in
            let isCompact = geometry.size.width < 500
            let isMedium = geometry.size.width >= 500 && geometry.size.width < 700

            HStack(spacing: isCompact ? 4 : 8) {
                ForEach(visibleMetadata(for: geometry.size.width), id: \.key) { key, value in
                    Label(
                        isCompact ? value : "\(key): \(value)",
                        systemImage: "tag"
                    )
                    .font(.caption)
                }

                if hasHiddenMetadata(for: geometry.size.width) {
                    Menu {
                        ForEach(hiddenMetadata(for: geometry.size.width), id: \.key) { key, value in
                            Text("\(key): \(value)")
                        }
                    } label: {
                        Text("+\(hiddenCount(for: geometry.size.width)) more")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .frame(height: 30)
    }

    private func visibleMetadata(for width: CGFloat) -> [(key: String, value: String)] {
        let maxItems = width > 700 ? metadata.count :
                      width > 500 ? min(3, metadata.count) :
                      min(2, metadata.count)
        return Array(metadata.sorted(by: { $0.key < $1.key }).prefix(maxItems))
    }

    private func hiddenMetadata(for width: CGFloat) -> [(key: String, value: String)] {
        let visibleCount = visibleMetadata(for: width).count
        return Array(metadata.sorted(by: { $0.key < $1.key }).dropFirst(visibleCount))
    }

    private func hasHiddenMetadata(for width: CGFloat) -> Bool {
        !hiddenMetadata(for: width).isEmpty
    }

    private func hiddenCount(for width: CGFloat) -> Int {
        hiddenMetadata(for: width).count
    }
}
```

**Pros:**
- Precise control over breakpoints
- Can calculate exactly what to show
- Progressive disclosure of content

**Cons:**
- More code
- Manual width calculations
- Need to manage breakpoints

#### 3. Custom Preference Key (Advanced)

For passing width information up the view hierarchy.

```swift
struct WidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ResponsiveBar: View {
    @State private var width: CGFloat = 0

    var body: some View {
        HStack {
            if width > 600 {
                fullUI
            } else {
                compactUI
            }
        }
        .background(
            GeometryReader { geometry in
                Color.clear
                    .preference(key: WidthPreferenceKey.self, value: geometry.size.width)
            }
        )
        .onPreferenceChange(WidthPreferenceKey.self) { newWidth in
            width = newWidth
        }
    }
}
```

**Use when:**
- Parent view needs to know child's width
- Multiple views need to coordinate based on shared width
- Complex layout hierarchies

### Recommended Breakpoints for macOS

```swift
enum WindowSize {
    /// Very small window (< 400pt)
    static let compact: CGFloat = 400

    /// Normal window (400-600pt)
    static let medium: CGFloat = 600

    /// Wide window (> 600pt)
    static let large: CGFloat = 900

    static func category(for width: CGFloat) -> Category {
        switch width {
        case ..<compact: return .compact
        case ..<medium: return .medium
        default: return .large
        }
    }

    enum Category {
        case compact
        case medium
        case large
    }
}
```

### Key Changes

To implement responsive UI in SQLNotebook:

1. **Create responsive components** in `SQLNotebook/Views/Components/Responsive/`
   - `ResponsiveRunBar.swift` - Run with Query bar
   - `ResponsiveMetadataBar.swift` - Metadata bar
   - `WindowSize.swift` - Breakpoint definitions

2. **Update existing views** to use responsive components:
   - `NotebookContentView.swift` - Replace static Run bar
   - `EditorContentView.swift` - Replace static metadata bar

3. **Add tests** in `SQLNotebookTests/UI/ResponsiveTests.swift`:
   - Test layout selection at different widths
   - Verify content visibility
   - Test progressive disclosure

## Implementation Recommendations

### For "Run with Query" Bar

**Use `ViewThatFits`** - The bar has a clear full/compact dichotomy:
- **Full (>600pt)**: All buttons visible, full text labels
- **Compact (<600pt)**: Essential buttons + overflow menu

```swift
ViewThatFits {
    // Full: Run | Run with Query | [space] | Cell 1 of 10 | Settings
    fullLayout

    // Compact: Run | ••• | [space] | 1/10
    compactLayout
}
```

### For Metadata Bar

**Use `GeometryReader`** - Needs progressive disclosure:
- **Large (>700pt)**: Show all metadata tags
- **Medium (500-700pt)**: Show 3 tags + "+N more" menu
- **Compact (<500pt)**: Show 2 tags + "+N more" menu

This requires precise control over what's visible.

## Comparison Table

| Approach | Complexity | Control | Use Case |
|----------|-----------|---------|----------|
| **ViewThatFits** | Low | Medium | Simple toolbars, 2-3 layouts |
| **GeometryReader** | Medium | High | Complex layouts, progressive disclosure |
| **Size Classes** | Low | Low | iOS patterns (limited on macOS) |
| **Preference Key** | High | High | Advanced coordination, shared state |

## Testing

When implementing responsive UI:

```swift
@Test("Run bar adapts to compact width")
func testRunBarCompact() {
    let view = ResponsiveRunBar()
        .frame(width: 400) // Force compact

    // Verify compact layout is used
    #expect(view.usesCompactLayout == true)
}

@Test("Metadata bar shows overflow menu")
func testMetadataOverflow() {
    let metadata = [
        "database": "test_db",
        "table": "users",
        "rows": "1000",
        "size": "15MB"
    ]
    let view = ResponsiveMetadataBar(metadata: metadata)
        .frame(width: 500) // Medium width

    // Should show 3 items + overflow
    #expect(view.visibleItems.count == 3)
    #expect(view.hasOverflow == true)
}
```

## Notes

### Why Not `horizontalSizeClass`?

`horizontalSizeClass` is primarily an iOS/iPadOS pattern. On macOS:
- Size classes don't change as reliably with window resizing
- Most macOS windows stay in `.regular` size class
- Direct width measurement is more predictable

### Performance Considerations

- `GeometryReader` triggers layout recalculations on every width change
- For frequently updated views, consider debouncing width changes
- `ViewThatFits` is optimized by SwiftUI and generally more performant

### Accessibility

Ensure responsive layouts maintain accessibility:
- Don't hide critical actions in overflow menus without keyboard shortcuts
- Maintain sufficient tap/click targets (min 44x44pt)
- Test with VoiceOver to ensure menu items are accessible

## Related Documentation

- [Apple's Layout fundamentals](https://developer.apple.com/documentation/swiftui/layout-fundamentals)
- [ViewThatFits documentation](https://developer.apple.com/documentation/swiftui/viewthatfits)
- [GeometryReader best practices](https://developer.apple.com/documentation/swiftui/geometryreader)

## Future Enhancements

- [ ] Add animation transitions between layouts
- [ ] Create reusable `ResponsiveContainer` wrapper
- [ ] Implement saved user preferences for compact mode threshold
- [ ] Add debug overlay showing current breakpoint category
