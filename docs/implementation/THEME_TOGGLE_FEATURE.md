# Theme Toggle Feature Implementation

**Date**: 2026-01-02
**Status**: ✅ FIXED - Theme Persistence Working
**Priority**: Medium

## Overview

Implemented a theme toggle feature to allow users to switch between Light, Dark, and System appearance modes. The feature now works correctly with full persistence across window focus changes and app restarts.

**FIXED**: Theme persistence issues resolved by switching from per-window `NSWindow.appearance` to application-level `NSApp.appearance`.

---

## ✅ What Was Implemented

### 1. **Theme Preference Storage** (`AppSettings.swift`)

Added `ThemePreference` enum and settings storage:

```swift
enum ThemePreference: String, CaseIterable {
  case system = "System"
  case light = "Light"
  case dark = "Dark"

  var colorScheme: ColorScheme? {
    switch self {
    case .system: return nil
    case .light: return .light
    case .dark: return .dark
    }
  }
}
```

- **Stored in**: UserDefaults with key `"app.settings.themePreference"`
- **Default**: `.dark`
- **Persistence**: ✅ Saves and loads correctly from UserDefaults

### 2. **Adaptive Color System** (`DesignSystem.swift`)

Converted all hardcoded colors to adaptive colors that support both light and dark modes:

```swift
static let appBackground = Color(
  light: Color(hex: "ffffff"),  // White
  dark: Color(hex: "09090b")    // Very dark zinc
)
```

Created custom `Color(light:dark:)` initializer using `NSColor` with appearance callback:

```swift
init(light: Color, dark: Color) {
  self.init(nsColor: NSColor(name: nil) { appearance in
    switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
    case .darkAqua: return NSColor(dark)
    default: return NSColor(light)
    }
  })
}
```

**Colors Updated**:
- Backgrounds (app, card, cell, input)
- Foregrounds (text colors)
- Borders
- Accents
- Semantic colors (success, warning, destructive)
- Syntax highlighting

### 3. **Settings UI** (`SettingsContent.swift`)

Added Appearance section with segmented picker:

```swift
Picker("Theme", selection: $appSettings.themePreference) {
  ForEach(ThemePreference.allCases, id: \.self) { theme in
    Text(theme.rawValue).tag(theme)
  }
}
.pickerStyle(.segmented)
```

- **Location**: First section in Settings sidebar
- **UI**: Three-segment picker (System | Light | Dark)
- **Behavior**: ✅ Updates immediately when user clicks

### 4. **Appearance Management System** (`AppearanceModifier.swift`)

Created three-layer system to apply and maintain appearance:

#### **Layer 1: AppearanceManager (Singleton)**
```swift
@MainActor
class AppearanceManager {
  static let shared = AppearanceManager()
  var currentScheme: ColorScheme? = nil

  func setAppearance(_ colorScheme: ColorScheme?) {
    currentScheme = colorScheme
    applyToAllWindows()
  }
}
```

- Centralized state management
- Observes `NSWindow.didBecomeKeyNotification` to reapply appearance when window gains focus
- Applies `NSAppearance` directly to `NSWindow` objects

#### **Layer 2: AppearanceModifier (ViewModifier)**
```swift
struct AppearanceModifier: ViewModifier {
  let colorScheme: ColorScheme?

  func body(content: Content) -> some View {
    content
      .onAppear { AppearanceManager.shared.setAppearance(colorScheme) }
      .onChange(of: colorScheme) { _, new in
        AppearanceManager.shared.setAppearance(new)
      }
  }
}
```

- Bridges SwiftUI and AppKit
- Listens for theme changes and updates manager

#### **Layer 3: WindowAccessor (NSViewRepresentable)**
```swift
private struct WindowAccessor: NSViewRepresentable {
  let colorScheme: ColorScheme?

  func makeNSView(context: Context) -> NSView {
    // Apply appearance when view is added to window
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    // Reapply when view updates
  }
}
```

- Direct access to `NSWindow` via NSView
- Ensures early application of appearance

### 5. **Integration** (`ContentView.swift`)

Applied appearance modifier to main view:

```swift
var body: some View {
  ZStack { /* ... */ }
    .windowAppearance(appSettings.themePreference.colorScheme)
}
```

Removed hardcoded `.preferredColorScheme(.dark)` from `SQLNotebookApp.swift`.

---

## 🎉 SOLUTION APPLIED (2026-01-02)

### What Was Changed

Applied **Solution 2** from the original suggestions: Use `NSApplication.appearance` instead of per-window appearance.

### Changes Made

#### 1. **Simplified AppearanceManager** ([AppearanceModifier.swift](../SQLNotebook/Utilities/AppearanceModifier.swift))

**Before:**
```swift
// Complex system with window observers and per-window appearance
private func applyToWindow(_ window: NSWindow) {
  window.appearance = NSAppearance(named: .aqua/.darkAqua)
}
```

**After:**
```swift
// Simple application-level appearance
private func applyAppearance() {
  NSApp.appearance = NSAppearance(named: .aqua/.darkAqua)
}
```

**Benefits:**
- ✅ No need for window observers (`NSWindow.didBecomeKeyNotification`)
- ✅ No need for `WindowAccessor` NSViewRepresentable
- ✅ Appearance persists automatically when windows gain/lose focus
- ✅ Simpler, more maintainable code (removed ~40 lines)

#### 2. **Theme Application on View Appear** ([ContentView.swift](../SQLNotebook/ContentView.swift))

Theme is applied when ContentView appears (not in app init to avoid NSApp timing issues):

```swift
var body: some View {
  ZStack { /* ... */ }
    .windowAppearance(appSettings.themePreference.colorScheme)
}
```

The `AppearanceModifier.onAppear` handler calls:
```swift
.onAppear {
  AppearanceManager.shared.setAppearance(colorScheme)
}
```

**Benefits:**
- ✅ Theme applies when NSApp is fully initialized
- ✅ No crash from accessing NSApp too early
- ✅ UserDefaults preference loads and applies correctly
- ✅ Works reliably across app lifecycle

### Why This Works

**Root Cause of Previous Issues:**
1. Setting `window.appearance` is overridden by macOS window system when windows become key
2. Per-window appearance doesn't persist across focus changes
3. Calling `NSApp.appearance` in `App.init()` crashes because NSApp isn't ready yet

**Why This Solution Works:**
1. **NSApp.appearance** (not window.appearance):
   - Application-level appearance is the source of truth for all windows
   - macOS doesn't override `NSApp.appearance` automatically
   - All windows inherit from `NSApp.appearance` unless explicitly overridden

2. **Applied in ContentView.onAppear** (not App.init):
   - NSApp is fully initialized when ContentView appears
   - No timing issues or crashes
   - Theme preference loads from UserDefaults and applies reliably

### Testing Results (Verified Working)

✅ **Test 1: Theme Toggle**
- Set theme to Light → UI changes immediately
- Set theme to Dark → UI changes immediately
- Set theme to System → Follows system preference
- **Status**: PASSED ✅

✅ **Test 2: Window Focus**
- Set theme to Light
- Cmd+Tab to another app
- Cmd+Tab back to SQLNotebook
- **Result**: Theme stays Light ✅
- **Status**: PASSED ✅

✅ **Test 3: App Restart**
- Set theme to Light
- Quit app
- Reopen app
- **Result**: Theme is Light from launch ✅
- **Status**: PASSED ✅

✅ **Test 4: No Crashes**
- App launches without NSApp-related crashes
- Theme applies smoothly on ContentView.onAppear
- **Status**: PASSED ✅

---

## ❌ Previous Problems (NOW FIXED)

### Issue 1: Theme Resets When Window Loses/Gains Focus

**Symptoms**:
- Set theme to "Light" in Settings → UI becomes light ✅
- Switch to another app → Switch back to SQLNotebook
- **Result**: Theme reverts to Dark ❌
- Settings still shows "Light" selected

**Observed Behavior**:
```
User: Set theme to Light
App: UI changes to light immediately ✅
User: Cmd+Tab to Safari
User: Cmd+Tab back to SQLNotebook
App: UI is now dark again ❌ (but picker still shows "Light")
```

**Root Cause Analysis**:

1. **Window Appearance Override**: macOS may be overriding `NSAppearance` when window becomes key
2. **Observer Not Firing**: `NSWindow.didBecomeKeyNotification` might not fire as expected
3. **State Desync**: `AppearanceManager.currentScheme` is set correctly, but `applyToWindow()` might not be called or might be ineffective
4. **SwiftUI Color Resolution**: SwiftUI's adaptive colors resolve appearance from window, creating a race condition

### Issue 2: Theme Resets on App Relaunch

**Symptoms**:
- Set theme to "Light" → Quit app
- Reopen app
- **Result**: Brief flash of light theme, then immediately switches to dark
- Settings shows "Light" selected

**Observed Behavior**:
```
User: Set theme to Light, quit app
User: Reopen app
App: Shows light theme for ~100ms
App: Immediately switches to dark theme
Settings: Still shows "Light" (correct from UserDefaults)
```

**Root Cause Analysis**:

1. **Timing Issue**: `AppearanceManager.setAppearance()` is called too early, before window is fully initialized
2. **Default Appearance**: `NSWindow` might have a default appearance that overrides our setting during initialization
3. **Async Loading**: Theme loads from UserDefaults asynchronously, but default appearance is applied synchronously

### Issue 3: Inconsistent State

**Current State Flow**:
```
AppSettings.themePreference (UserDefaults) ✅ Persists correctly
    ↓
ContentView.appSettings.themePreference ✅ Binds correctly
    ↓
.windowAppearance(colorScheme) ✅ Called with correct value
    ↓
AppearanceManager.setAppearance(colorScheme) ✅ Sets currentScheme
    ↓
applyToAllWindows() → applyToWindow(window) ✅ Called
    ↓
window.appearance = NSAppearance(named: .aqua/.darkAqua) ⚠️ Set but not persisting
    ↓
[Something resets window.appearance to system default] ❌ PROBLEM HERE
```

---

## 🔍 Investigation Attempts

### Attempt 1: SwiftUI's `.preferredColorScheme()` Modifier
**Result**: ❌ Does not work in production macOS apps (only works in Previews)

### Attempt 2: Closure-Based Observer
**Result**: ❌ Captured old `colorScheme` value, didn't update when theme changed

### Attempt 3: Singleton with Dynamic State
**Result**: ⚠️ Partially works - theme applies initially but doesn't persist

### Attempt 4: Selector-Based Observer
**Result**: ⚠️ Current implementation - still has persistence issues

---

## 🧪 Debugging Suggestions

### Things to Verify:

1. **Check if observer fires**:
   ```swift
   @objc private func windowDidBecomeKey(_ notification: Notification) {
     print("🔔 Window became key")
     print("📊 Current scheme: \(currentScheme)")
     if let window = notification.object as? NSWindow {
       print("🪟 Window appearance before: \(window.appearance)")
       applyToWindow(window)
       print("🪟 Window appearance after: \(window.appearance)")
     }
   }
   ```

2. **Check window appearance at different lifecycle points**:
   ```swift
   // In WindowAccessor.makeNSView
   DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
     print("🔍 Window appearance after 500ms: \(view.window?.appearance)")
   }
   ```

3. **Monitor appearance changes**:
   ```swift
   // Add observer for appearance changes
   NSApp.observe(\.effectiveAppearance) { app, _ in
     print("🎨 App appearance changed to: \(app.effectiveAppearance.name)")
   }
   ```

---

## 💡 Potential Solutions to Try

### Solution 1: Override Window's `effectiveAppearance`
Instead of setting `window.appearance`, try overriding in a custom `NSWindow` subclass:

```swift
class ThemedWindow: NSWindow {
  var forcedAppearance: NSAppearance?

  override var effectiveAppearance: NSAppearance {
    get { forcedAppearance ?? super.effectiveAppearance }
    set { super.effectiveAppearance = newValue }
  }
}
```

### Solution 2: Use `NSApplication.appearance`
Set appearance at app level instead of window level:

```swift
func setAppearance(_ colorScheme: ColorScheme?) {
  if let scheme = colorScheme {
    switch scheme {
    case .light:
      NSApp.appearance = NSAppearance(named: .aqua)
    case .dark:
      NSApp.appearance = NSAppearance(named: .darkAqua)
    }
  } else {
    NSApp.appearance = nil // System default
  }
}
```

### Solution 3: Persistent Window Delegate
Create a window delegate that enforces appearance:

```swift
class AppearanceWindowDelegate: NSObject, NSWindowDelegate {
  var targetAppearance: NSAppearance?

  func windowDidBecomeKey(_ notification: Notification) {
    if let window = notification.object as? NSWindow,
       let appearance = targetAppearance {
      window.appearance = appearance
    }
  }

  func windowDidUpdate(_ notification: Notification) {
    // Continuously enforce appearance
    if let window = notification.object as? NSWindow,
       let appearance = targetAppearance {
      window.appearance = appearance
    }
  }
}
```

### Solution 4: SwiftUI Environment Override
Force environment at app level:

```swift
WindowGroup {
  ContentView()
    .environment(\.colorScheme, appSettings.themePreference.colorScheme ?? .dark)
}
```

---

## 📊 Final Architecture (Simplified)

```
┌─────────────────────────────────────────────────────────┐
│ AppSettings (Observable, @MainActor)                    │
│ - themePreference: ThemePreference                      │
│ - Persisted in UserDefaults                             │
└─────────────────┬───────────────────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────────────────┐
│ ContentView                                             │
│ @Bindable var appSettings = AppSettings.shared         │
│ .windowAppearance(appSettings.themePreference...)      │
└─────────────────┬───────────────────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────────────────┐
│ AppearanceModifier (ViewModifier)                       │
│ - onAppear: sets appearance (when NSApp is ready)       │
│ - onChange: updates appearance on user change           │
└─────────────────┬───────────────────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────────────────┐
│ AppearanceManager (Singleton, @MainActor)               │
│ - currentScheme: ColorScheme?                           │
│ - applyAppearance() sets NSApp.appearance               │
│ (NO window observers, NO WindowAccessor)                │
└─────────────────────────────────────────────────────────┘
```

**Key Simplifications:**
- ❌ Removed: WindowAccessor NSViewRepresentable
- ❌ Removed: Window observers (didBecomeKeyNotification)
- ❌ Removed: Per-window appearance logic
- ✅ Simple: Single `NSApp.appearance` setter
- ✅ Reliable: Applied when view appears (NSApp ready)

---

## 📝 Files Modified

1. **`SQLNotebook/Utilities/AppSettings.swift`** - Added theme preference enum and UserDefaults storage
2. **`SQLNotebook/Utilities/DesignSystem.swift`** - Converted to adaptive colors supporting light/dark modes
3. **`SQLNotebook/Utilities/AppearanceModifier.swift`** - New file: AppearanceManager + ViewModifier (simplified, NSApp-level)
4. **`SQLNotebook/Views/Sidebars/SettingsContent.swift`** - Theme picker UI (System | Light | Dark)
5. **`SQLNotebook/ContentView.swift`** - Applied `.windowAppearance()` modifier
6. **`SQLNotebook/SQLNotebookApp.swift`** - Removed hardcoded `.preferredColorScheme(.dark)`

---

## 🎯 Next Steps

~~1. **Add Debug Logging**: Instrument the appearance system to understand when/why it resets~~
~~2. **Try Solution 2**: Set appearance at `NSApplication` level instead of per-window~~
~~3. **Research**: Check if DocumentGroup architecture has special appearance handling~~
~~4. **Test Alternative**: Try custom `NSWindow` subclass with overridden `effectiveAppearance`~~
~~5. **Consider Workaround**: If NSAppearance approach fails, explore pure SwiftUI environment approach~~

✅ **ALL ISSUES RESOLVED** - Solution 2 (NSApp.appearance) successfully fixed all persistence problems.

---

## 🔗 Related Code

- Color adaptive system: [DesignSystem.swift:12-139](../SQLNotebook/Utilities/DesignSystem.swift#L12-L139)
- Theme preference enum: [AppSettings.swift:9-25](../SQLNotebook/Utilities/AppSettings.swift#L9-L25)
- Appearance manager: [AppearanceModifier.swift:9-40](../SQLNotebook/Utilities/AppearanceModifier.swift#L9-L40) (simplified, ~60 lines total)
- Appearance modifier: [AppearanceModifier.swift:42-54](../SQLNotebook/Utilities/AppearanceModifier.swift#L42-L54)
- Settings UI: [SettingsContent.swift:14-36](../SQLNotebook/Views/Sidebars/SettingsContent.swift#L14-L36)
- Integration: [ContentView.swift](../SQLNotebook/ContentView.swift) (`.windowAppearance()` call)

---

## 📚 References

- [NSAppearance Documentation](https://developer.apple.com/documentation/appkit/nsappearance)
- [Supporting Dark Mode in Your Interface](https://developer.apple.com/documentation/appkit/supporting_dark_mode_in_your_interface)
- [SwiftUI ColorScheme](https://developer.apple.com/documentation/swiftui/colorscheme)

---

## 📋 Summary

**Problem**: Theme toggle feature wasn't persisting across window focus changes and app restarts.

**Root Causes**:
1. Per-window `NSWindow.appearance` was being overridden by macOS
2. Attempting to set `NSApp.appearance` in `App.init()` caused crashes (NSApp not ready)

**Solution**:
1. Use `NSApp.appearance` instead of per-window appearance (app-level persistence)
2. Apply theme in `ContentView.onAppear` instead of `App.init()` (NSApp timing)
3. Remove complex window observers and WindowAccessor code

**Result**: ✅ Simple, robust theme system that persists correctly.

**Code Changes**: ~60 lines total in `AppearanceModifier.swift` (down from ~100 lines with observers)
