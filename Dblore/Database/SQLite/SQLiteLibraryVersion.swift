// SQLiteLibraryVersion.swift
// The linked SQLite library version. The structure editor gates RENAME COLUMN (3.25.0) and
// DROP COLUMN (3.35.0) on it; `StructureDDLBuilder` takes the number as input so tests inject it.

import Foundation
import SQLite3

nonisolated enum SQLiteLibraryVersion {
  /// `sqlite3_libversion_number()`: major * 1_000_000 + minor * 1_000 + patch (3.45.1 is 3045001)
  static var current: Int { Int(sqlite3_libversion_number()) }
}
