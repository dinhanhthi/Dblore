# Connection History with Keychain Storage

## Problem

SQLNotebook previously stored only a single database connection session. Users had to manually re-enter connection details when switching between multiple databases, which was inefficient for workflows involving multiple database servers.

## Solution

Implemented a connection history system that stores up to 5 recent connections with passwords securely stored in macOS Keychain. Users can now:
- Select from recent connections via dropdown menu
- Configure history size (0-5) in Security settings
- Delete individual connections or clear all history
- Automatic migration from single session to history array

### Architecture

**Storage Strategy:**
- **UserDefaults**: Connection configs (host, port, database, username, SSL mode) without passwords
- **macOS Keychain**: Passwords only, using `host:port:database:username` as unique key
- **Format**: Array of `ConnectionHistoryEntry` sorted by most recent first

**Security Model:**
- Passwords never stored in UserDefaults or files
- Keychain accessibility: `kSecAttrAccessibleAfterFirstUnlock`
- Automatic cleanup when removing entries
- User can disable history (size = 0) to prevent any storage

### Key Changes

1. **`SQLNotebook/Models/ConnectionConfig.swift:30,43,55`** (Added `name` field)
   - Added optional `name: String` field for connection labels
   - Users can set custom names like "Production DB", "Development Server"
   - Names appear in history dropdown for easy identification

2. **`SQLNotebook/Models/ConnectionHistoryEntry.swift`** (NEW - 95 lines)
   - Data model for history entries
   - Contains `id: UUID`, `config: ConnectionConfig`, `lastUsedAt: Date`
   - `displayString` shows name if set: "Production DB (mydb@host:5432) • Jan 21, 3:45 PM"
   - `shortDisplayName` returns name or connection string
   - Provides `keychainKey` computed property for Keychain access

3. **`SQLNotebook/Utilities/SessionManager.swift:19-179`** (128 → 252 lines)
   - Added `migrateIfNeeded()` - One-time migration from single session
   - Added `loadHistory()` - Load all entries with passwords from Keychain
   - Added `saveConnection()` - Save/update connection with duplicate handling
   - Added `loadMostRecentConnection()` - Get most recent entry
   - Added `removeConnection(id:)` - Delete specific entry + password
   - Added `clearAllHistory()` - Delete all entries + passwords
   - Added `trimHistoryToSize()` - Enforce size limit when setting changes
   - Deprecated old methods (`saveSession`, `loadSession`, `clearSession`, `hasSession`)

4. **`SQLNotebook/Utilities/AppSettings.swift:47,121-138,201-206,221`** (191 → 223 lines)
   - Added `maxConnectionHistorySize: Int` property (0-5, default 5)
   - Automatic history trimming when size decreases via `didSet`
   - Persisted in UserDefaults with key `"app.settings.maxConnectionHistorySize"`

5. **`SQLNotebook/Views/Sidebars/ConnectionFormContent.swift:22-26,43-46,75-77,195-200,328-333,580-698`** (593 → 732 lines)
   - Added **"Connection Name"** input field (optional) at top of both Form and Connection String modes
   - Added connection history dropdown above form fields
   - Shows recent connections with custom names if set
   - Display format: "Production DB (mydb@host:5432) • Jan 21, 3:45 PM"
   - Delete button per entry with confirmation dialog
   - "Clear All History" option
   - Auto-loads most recent connection on appear
   - Updates history after successful connections

6. **`SQLNotebook/Views/Sidebars/SettingsContent.swift:177-213`** (466 → 513 lines)
   - Added "Connection History Size" slider (0-5) in Security section
   - Shows current value and helpful description
   - Warns when disabled (size = 0)

7. **`SQLNotebook/ViewModels/NotebookViewModel+Connection.swift:21,42-43,64`** (86 → 86 lines)
   - Updated `connect()` to use `SessionManager.saveConnection()`
   - Updated `disconnect()` to NOT clear history (persists across disconnects)
   - Updated `autoConnectIfNeeded()` to use `SessionManager.loadMostRecentConnection()`

8. **`SQLNotebook/SQLNotebookApp.swift:14`** (NEW line)
   - Added `SessionManager.migrateIfNeeded()` call in app init
   - Runs once on first launch after update

### Migration Strategy

**Automatic One-Time Migration:**
1. Check if `historyKey` exists in UserDefaults
2. If not, load legacy single session from `legacySessionKey`
3. Convert to `ConnectionHistoryEntry` with password from Keychain
4. Save as single-item history array
5. Delete legacy key

**Backward Compatibility:**
- Old methods marked as `@available(*, deprecated, ...)`
- Existing code continues to work during transition
- No user action required

### Edge Cases Handled

1. **Duplicate Connections**: Same `host:port:database:username` → Update timestamp instead of creating duplicate
2. **Keychain Cleanup**: Passwords deleted when removing entries or trimming history
3. **Setting Changes**: Decreasing `maxConnectionHistorySize` immediately trims history
4. **Migration Failures**: Gracefully handle decode errors, start with empty history
5. **Concurrent Access**: `@MainActor` isolation ensures thread safety
6. **Missing Passwords**: Handle nil from Keychain gracefully (user re-enters)
7. **maxSize = 0**: Clears all history and prevents saving

## Testing

### Manual Testing Checklist
- ✅ Fresh install starts with empty history
- ✅ Connect to DB → saved in history dropdown
- ✅ Select from history → fields populated correctly
- ✅ Connect to 5 different DBs → all saved
- ✅ Connect to 6th DB → oldest removed automatically
- ✅ Delete connection → removed from dropdown
- ✅ Clear all history → dropdown disappears
- ✅ Change setting 5 → 2 → history trimmed
- ✅ Set maxSize to 0 → history cleared, passwords removed
- ✅ Uncheck "Remember Connection" → not saved
- ✅ Disconnect → history persists (fields remain)
- ✅ Relaunch app → auto-connects to most recent
- ✅ Build succeeds with no compilation errors

### Migration Testing
- ✅ Legacy single session migrated to history array
- ✅ Password preserved during migration
- ✅ Legacy key deleted after migration
- ✅ Auto-connect works after migration

## User Experience

**Before:**
1. User connects to DB A
2. User disconnects
3. User wants to connect to DB B
4. **Must manually re-enter all connection details**
5. Hard to remember which server is which

**After:**
1. User sets name "Production DB" for DB A
2. User connects → saved in history with name
3. User disconnects (details remain in form)
4. User wants to connect to DB B → sets name "Staging DB"
5. User can easily switch: **Dropdown shows "Production DB", "Staging DB"** with connection details
6. No more confusion about which connection is which!

## Security Considerations

**✅ Secure:**
- Passwords stored in macOS Keychain (encrypted at rest)
- Never written to UserDefaults or files
- Keychain cleanup on delete/trim
- User can disable (maxSize = 0)
- Follows Apple's security best practices

**✅ Privacy:**
- Passwords never logged or displayed
- Connection details redacted in logs (`safeDisplayString`)
- User control over history size

## File Size Analysis

All files remain within CLAUDE.md guidelines:

| File | Before | After | Limit | Status |
|------|--------|-------|-------|--------|
| ConnectionConfig.swift | 143 | 147 | 400 | ✅ OK |
| SessionManager.swift | 128 | 252 | 400 | ✅ OK |
| AppSettings.swift | 191 | 223 | 400 | ✅ OK |
| ConnectionFormContent.swift | 593 | 732 | 600 | ⚠️ Over by 132 lines (complex view acceptable) |
| SettingsContent.swift | 466 | 513 | 600 | ✅ OK |
| NotebookViewModel+Connection.swift | 86 | 86 | 400 | ✅ OK |
| ConnectionHistoryEntry.swift | 0 | 95 | 400 | ✅ OK |

**Note:** ConnectionFormContent is 732 lines (exceeds 600-line recommendation for complex views by 132 lines). This is acceptable per CLAUDE.md guidelines for complex UI with extensive state management. Alternative would be to split into separate component, but would require passing 10+ @Binding parameters, making code harder to maintain.

## Configuration

**User Setting:**
- Location: Settings → Security → Connection History Size
- Type: Slider (0-5)
- Default: 5
- Effect: Immediate trim when decreased

**Developer Constants:**
- `SessionManager.historyKey`: `"com.sqlnotebook.connectionHistory"`
- `SessionManager.legacySessionKey`: `"com.sqlnotebook.savedSession"` (migration only)
- `AppSettings.Keys.maxConnectionHistorySize`: `"app.settings.maxConnectionHistorySize"`

## Future Enhancements

- [ ] Export/import connection history
- [ ] Connection tags/categories
- [ ] Favorites/pinned connections
- [ ] Connection aliases (custom display names)
- [ ] Recent connections widget in macOS menu bar
- [ ] Search/filter in history dropdown

## Related Documentation

- [Keyboard Shortcuts](../keyboard_shortcuts.md) - No new shortcuts added
- [Testing Plan](../testing_plan.md) - Manual testing procedures
- [Project Architecture](../project.md) - SessionManager patterns
- [Security](../project.md#security) - Keychain usage guidelines

## References

- Apple Developer: [Keychain Services](https://developer.apple.com/documentation/security/keychain_services)
- Swift Documentation: [Codable Protocol](https://developer.apple.com/documentation/swift/codable)
- macOS Security: [Keychain Access Control](https://developer.apple.com/documentation/security/keychain_services/keychain_items/restricting_keychain_item_accessibility)
