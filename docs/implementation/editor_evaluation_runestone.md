# Editor Evaluation: Runestone with Current Autocomplete Implementation

## Problem
Evaluate whether Runestone, a performant iOS/macOS text editor with tree-sitter syntax highlighting, can replace the current custom NSTextView-based editor while preserving the existing SQL autocomplete functionality.

## Runestone Overview

### Core Technology
- **Architecture**: Custom UIScrollView-based text editor (not UITextView subclass)
- **Platform**: iOS/iPadOS primary, macOS Catalyst support (⚠️ "not fully tested, implementation isn't considered done")
- **Syntax Highlighting**: Tree-sitter based incremental parsing
- **License**: MIT
- **Maturity**: Production-ready with 3,000+ stars, 28 releases (v0.5.1 from June 2024)

### Key Features
✅ **Tree-sitter syntax highlighting** - Compiler-grade accuracy, incremental parsing
✅ **Line numbers** - Built-in with current line highlighting
✅ **Character pairs** - Smart bracket/quote insertion
✅ **Invisible characters** - Show tabs, spaces, line breaks
✅ **Customization** - Colors, fonts, themes, line height, kerning
✅ **Performance** - Described as "unbelievably fast and reliable" even with large files
✅ **Search** - Regex search with range highlighting
✅ **Auto-indentation** - Detects spaces vs tabs, line endings (CR/LF/CRLF)

❌ **No built-in autocomplete** - Must be implemented as custom feature
❌ **No minimap** - Not mentioned in features
❌ **No code folding** - Not mentioned in features
❌ **No find/replace UI** - Only search API

## Critical Evaluation

### ❌ Platform Incompatibility - DEALBREAKER

**SQLNotebook is a macOS app using AppKit (NSTextView)**

**Runestone is a UIKit framework (UIScrollView-based)**

**Catalyst Limitations:**
- README explicitly states: "should mostly work with Catalyst on the Mac, however, it isn't fully tested and the implementation isn't considered done"
- Focus is "currently on iPhone and iPad"
- [Catalyst support incomplete](https://github.com/simonbs/Runestone) according to maintainer

**Architecture Mismatch:**
```
Current SQLNotebook:
  NSTextView (AppKit) → Native macOS → SwiftUI wrapper

Runestone:
  UIScrollView (UIKit) → Catalyst translation layer → macOS → SwiftUI wrapper
```

**Implications:**
1. ⚠️ **Extra abstraction layer** - Catalyst adds overhead and potential bugs
2. ⚠️ **UI/UX inconsistencies** - iOS text selection, context menus may feel wrong on macOS
3. ⚠️ **Keyboard shortcuts** - iOS keyboard handling differs from macOS
4. ⚠️ **Performance uncertainty** - Catalyst translation overhead unknown
5. ⚠️ **Maintenance risk** - Catalyst bugs hard to debug, depend on Apple's Catalyst stability

### ✅ Autocomplete Integration - TECHNICALLY FEASIBLE

**Runestone API for Custom Autocomplete:**

Based on [TextView.swift source code](https://github.com/simonbs/Runestone/blob/main/Sources/Runestone/TextView/Core/TextView.swift):

```swift
// Runestone TextView API
class TextView: UIScrollView {
    // Delegate for text changes
    var editorDelegate: TextViewDelegate?

    // Text access
    var text: String { get set }
    var selectedRange: NSRange { get set }

    // Context extraction
    func text(in range: NSRange) -> String?
    func syntaxNode(at location: Int) -> SyntaxNode?

    // Delegate callbacks
    protocol TextViewDelegate {
        func textViewDidChange(_ textView: TextView)
        func textViewDidChangeSelection(_ textView: TextView)
    }
}
```

**Integration Strategy:**

1. **Monitor text changes** via `textViewDidChange(_:)`
2. **Track cursor position** via `selectedRange`
3. **Extract context** using `text(in:)` or `syntaxNode(at:)`
4. **Show popup** by adding UIView overlay as subview
5. **Reuse SQLAutocompleteProvider** - No changes needed to autocomplete logic!

**Current Autocomplete System (100% Reusable):**
- `SQLAutocompleteProvider.swift:190` - Context-aware suggestion engine
- `SQLAutocompleteProvider+Keywords.swift:75` - 74 SQL keywords
- `SQLAutocompleteProvider+ContextParsing.swift:178` - Table reference extraction
- Works with any text view that provides: `text`, `cursor position`, `text change notifications`

**Implementation Effort:**
- ✅ **Low** - Autocomplete logic is decoupled from NSTextView
- ✅ **Popup UI** - Need to rebuild for UIKit (instead of NSPopover), ~100-150 lines
- ✅ **Keyboard navigation** - Need to handle UIResponder instead of NSResponder

### Feature Comparison with Current Editor

| Feature | Current Editor | Runestone | Impact |
|---------|---------------|-----------|---------|
| **Platform** | ✅ Native macOS (AppKit) | ⚠️ iOS via Catalyst | **Major risk** |
| **Syntax Highlighting** | ⚠️ Regex (every keystroke) | ✅ Tree-sitter (incremental) | Better performance |
| **Autocomplete** | ✅ Context-aware SQL | ❌ Must implement | **Reusable code** |
| **Line Numbers** | ✅ Custom implementation | ✅ Built-in | Same quality |
| **Current Line Highlight** | ✅ Custom | ✅ Built-in | Same quality |
| **Smart Copy/Paste** | ✅ Line-aware | ❌ Standard UIKit | **Feature loss** |
| **Keyboard Shortcuts** | ✅ Custom (Ctrl+Enter, Cmd+/) | ❌ Must reimplement | **Major work** |
| **Minimap** | ❌ No | ❌ No | No gain |
| **Code Folding** | ❌ No | ❌ No | No gain |
| **Bracket Matching** | ❌ No | ✅ Yes | Small gain |
| **Dependencies** | ✅ Zero | ⚠️ Tree-sitter (bundled) | Minor |

## Decision Matrix

### ❌ Do NOT Replace with Runestone

**Critical Blockers:**

1. **Platform Mismatch (DEALBREAKER)**
   - SQLNotebook is a **native macOS app** using AppKit/NSTextView
   - Runestone is a **UIKit framework** designed for iOS/iPadOS
   - Catalyst support is **incomplete and untested** per maintainer
   - Introducing Catalyst for a macOS-first app is architectural anti-pattern

2. **No Compelling Advantage**
   - Tree-sitter performance gain: Solvable with debouncing (see editor_evaluation_codeedit.md)
   - No minimap, code folding, or find/replace UI (same limitations as current)
   - Only bracket matching is a net-new feature (not worth platform switch)

3. **Significant Integration Work**
   - Rebuild popup UI for UIKit (NSPopover → UIView overlay)
   - Reimplement keyboard shortcuts (NSResponder → UIResponder)
   - Reimplement smart copy/paste (NSPasteboard → UIPasteboard)
   - Test and debug Catalyst edge cases
   - **Effort: 2-3 weeks** with high uncertainty

4. **User Experience Risk**
   - iOS text selection behavior on macOS feels wrong
   - Catalyst keyboard handling differs from native AppKit
   - Context menu UX inconsistencies
   - Potential performance degradation from Catalyst layer

### ✅ What Runestone Teaches Us

**Key Insight**: Runestone proves that **tree-sitter + custom text view** can be very performant.

**Applicable Lessons:**
1. Tree-sitter incremental parsing solves regex performance issues
2. Custom UIScrollView can be faster than UITextView/NSTextView
3. [Performance reviews](https://www.macstories.net/reviews/runestone-a-streamlined-text-and-code-editor-for-iphone-and-ipad/) confirm tree-sitter is "unbelievably fast" with large files

**Better Approach for SQLNotebook:**
- Keep NSTextView-based architecture (native macOS)
- Add **optional tree-sitter syntax highlighting** as enhancement
- Evaluate [STTextView](https://github.com/krzyzanowskim/STTextView) - Native macOS alternative (NSTextView replacement with TextKit 2)

## Alternative: STTextView (Native macOS)

During research, discovered **STTextView** - a potential better fit:
- ✅ **Native macOS** (AppKit/NSTextView replacement)
- ✅ **TextKit 2** based (modern text system)
- ✅ **Line numbers built-in**
- ✅ **Performant** (specifically designed for macOS)
- ⚠️ Requires separate evaluation (out of scope for this doc)

## Comparison Summary

| Approach | Platform | Effort | Risk | Autocomplete | Result |
|----------|----------|--------|------|--------------|--------|
| **Runestone** | iOS/Catalyst | 2-3 weeks | High | Must reimplement UI | ❌ Not recommended |
| **CodeEditSourceEditor** | macOS native | 3-4 weeks | High | Must reimplement all | ❌ Not recommended |
| **Optimize Current** | macOS native | 1-2 weeks | Low | Keep existing | ✅ Best ROI |
| **STTextView** | macOS native | 2 weeks | Medium | May work with current | 🔍 Worth investigating |

## Autocomplete Integration Pattern (If Pursued)

For reference, here's how to integrate SQL autocomplete with any text editor:

### Requirements from Text Editor API:
1. ✅ Text change notifications (`textViewDidChange`)
2. ✅ Cursor position access (`selectedRange`)
3. ✅ Text extraction for context (`text(in: NSRange)`)
4. ✅ Ability to add overlay views (for popup)
5. ✅ Keyboard event handling (for navigation)

### Reusable Components (Zero Changes Needed):
- `SQLAutocompleteProvider.swift` - Main suggestion engine
- `SQLAutocompleteProvider+Keywords.swift` - SQL keywords
- `SQLAutocompleteProvider+ContextParsing.swift` - Context detection

### Platform-Specific Glue Code (~150 lines):
- **AppKit version** (current): NSPopover, NSResponder
- **UIKit version** (Runestone): UIView overlay, UIResponder
- **SwiftUI version** (future): Custom overlay, FocusState

**Key Insight**: SQLAutocompleteProvider is **framework-agnostic** because it only operates on:
- Plain text (`String`)
- Cursor position (`Int`)
- Database schema (`[DatabaseTable]`, `[DatabaseColumn]`)

## Final Verdict

### ❌ Do NOT use Runestone for SQLNotebook because:
1. **Platform mismatch** - UIKit/Catalyst for a native macOS app is anti-pattern
2. **Incomplete Catalyst support** - Maintainer explicitly says "not fully tested, not done"
3. **No compelling features** - Same limitations as current editor (no minimap, folding, find/replace)
4. **High integration cost** - 2-3 weeks to rebuild UIKit-specific code
5. **UX risk** - iOS paradigms don't translate well to macOS

### ✅ What to do instead:
1. **Short-term**: Optimize current NSTextView editor (debouncing, visible-range highlighting)
2. **Medium-term**: Evaluate **STTextView** (native macOS, TextKit 2, better fit)
3. **Long-term**: Consider adding tree-sitter as optional highlighting engine (keep NSTextView)

### 💡 Key Takeaway
**Runestone's value is proof that tree-sitter works great for editors.**
Use this insight to improve current editor, but **don't adopt Runestone directly** due to platform incompatibility.

## Testing

**Evaluation tested:**
- ✅ Reviewed Runestone GitHub repository and source code
- ✅ Analyzed TextView API for autocomplete integration points
- ✅ Verified platform compatibility (UIKit vs AppKit)
- ✅ Assessed Catalyst maturity and risks
- ✅ Confirmed SQLAutocompleteProvider is reusable

**Not tested (requires implementation):**
- ⏭️ Actual Catalyst build with Runestone
- ⏭️ Performance on macOS via Catalyst
- ⏭️ UX testing of iOS text selection on macOS
- ⏭️ Keyboard shortcut compatibility

## References

Research sources:
- [Runestone GitHub](https://github.com/simonbs/Runestone) - Source code and README
- [Runestone TextView API](https://github.com/simonbs/Runestone/blob/main/Sources/Runestone/TextView/Core/TextView.swift)
- [TextViewDelegate Documentation](https://docs.runestone.app/documentation/runestone/textviewdelegate/)
- [MacStories Review](https://www.macstories.net/reviews/runestone-a-streamlined-text-and-code-editor-for-iphone-and-ipad/) - Performance validation
- [Swift Package Index](https://swiftpackageindex.com/simonbs/Runestone) - Package details

## Notes

- **Production app exists**: Runestone is also a [standalone app on App Store](https://apps.apple.com/us/app/runestone-text-editor/id1548193893) (iOS), proving maturity
- **Recent update**: v1.6.1 updated January 8, 2026 - actively maintained
- **Single maintainer risk**: Primary maintainer is simonbs with 16 contributors
- **Tree-sitter bundled**: Uses git submodule, no separate dependency management needed
- **Autocomplete pattern**: The integration pattern documented here applies to any future editor evaluation
- **STTextView alternative**: Worth researching as native macOS option (TextKit 2 + NSView)
