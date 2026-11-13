// RedisCommand.swift
// One Redis command as the exact argument bytes sent to the server, and a key's identity

import Foundation

/// One Redis command: the argument array sent as is (`args[0]` is the command name) and the
/// database index it runs in. Arguments are bytes, never `String`, so binary values and keys that
/// differ only in Unicode normalization reach the server unchanged.
nonisolated struct RedisCommand: Hashable, Sendable {
  var args: [Data]
  var db: Int

  /// Command text for the editor and history: `RedisTokenizer.render(args)`, which tokenizes
  /// back to the same bytes
  var displayText: String { RedisTokenizer.render(args) }

  /// What logs and descriptions print: the upper-cased command name and the argument count
  /// (command name included), never another argument (keys, values and passwords stay out)
  var logDescription: String {
    let name = args.first.map { name in
      // ASCII upper case only, so escapes such as \xff keep their form; capped for log lines
      let upper = Data(name.map { (0x61...0x7A).contains($0) ? $0 - 0x20 : $0 })
      return String(RedisTokenizer.label(upper).prefix(64))
    }
    return "RedisCommand(command: \(name ?? "<none>"), argCount: \(args.count))"
  }
}

/// Shows the command name and the argument count only, as `logDescription`
nonisolated extension RedisCommand: CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  var description: String { logDescription }

  var debugDescription: String { logDescription }

  var customMirror: Mirror {
    Mirror(self, children: ["logDescription": logDescription], displayStyle: .struct)
  }
}

/// A key's identity: its database index and exact bytes. Two keys that look the same (an NFC
/// and an NFD "café") are different keys.
nonisolated struct RedisKeyRef: Hashable, Sendable {
  var db: Int
  var bytes: Data

  /// The key name for the UI, with control and non-UTF-8 bytes escaped (`RedisTokenizer.label`)
  var displayLabel: String { RedisTokenizer.label(bytes) }
}
