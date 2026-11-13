// RedisReadOnly.swift
// What a read-only Redis connection may send: a fail-closed allowlist of read commands, checked
// by RedisConnection.swift on the exact argument array before anything is sent (its own `SELECT
// <db>` included). The app's gate classifies commands first; this is the plugin's backstop.
//
// - A command name matches only when every byte is printable ASCII, compared case-insensitively;
//   any other name (non-UTF-8, spaces, empty) is refused.
// - Plain reads match on the name alone. `MEMORY`, `OBJECT` and `XINFO` match on (command,
//   subcommand): `MEMORY USAGE`, `OBJECT ENCODING / FREQ / IDLETIME / REFCOUNT`, `XINFO STREAM /
//   GROUPS / CONSUMERS`.
// - `INFO` takes exactly one section, `keyspace` or `server` (what the app sends); a bare `INFO`
//   or any other section is refused.
// - `XREAD` only as `XREAD [COUNT n] STREAMS ...` (the server stops reading options at
//   `STREAMS`): `BLOCK` would hold the shared connection.
// - Never allowed: writes and their `STORE` forms (`SORT`, `GEORADIUS`, `GEOSEARCHSTORE`,
//   `ZRANGESTORE`, ...), `EVAL` / `EVALSHA` / `FCALL` (only the `_RO` forms, which the server
//   runs without writes), blocking and push commands, `XREADGROUP` (it writes the pending list),
//   connection state (`SELECT`, `RESET`, `MULTI`, ...), admin (`CONFIG`, `CLIENT`, `DEBUG`,
//   `SCRIPT`, `FUNCTION`, `MODULE`, `ACL`, `CLUSTER`), `KEYS` (it can stall a large server; the
//   app lists keys with `SCAN`) and `DUMP`.
//
// A refusal names the command only when it is a short word of letters, digits and `_`, never an
// argument (which may be a secret).

import Foundation

enum RedisReadOnly {
  /// Read commands allowed by name alone
  private static let reads: Set<String> = [
    // Server and keyspace
    "PING", "ECHO", "TIME", "DBSIZE", "RANDOMKEY", "EXISTS", "TYPE", "TTL", "PTTL", "SCAN",
    // Strings and bitmaps
    "GET", "MGET", "STRLEN", "GETRANGE", "GETBIT", "BITCOUNT", "BITPOS", "BITFIELD_RO",
    // Hashes
    "HGET", "HMGET", "HGETALL", "HLEN", "HKEYS", "HVALS", "HEXISTS", "HSTRLEN", "HRANDFIELD",
    "HSCAN",
    // Lists
    "LLEN", "LINDEX", "LPOS", "LRANGE",
    // Sets
    "SCARD", "SISMEMBER", "SMISMEMBER", "SMEMBERS", "SRANDMEMBER", "SINTER", "SUNION", "SDIFF",
    "SINTERCARD", "SSCAN",
    // Sorted sets
    "ZCARD", "ZCOUNT", "ZLEXCOUNT", "ZSCORE", "ZMSCORE", "ZRANK", "ZREVRANK", "ZRANGE",
    "ZREVRANGE", "ZRANGEBYSCORE", "ZREVRANGEBYSCORE", "ZRANGEBYLEX", "ZREVRANGEBYLEX",
    "ZRANDMEMBER", "ZSCAN",
    // Streams, HyperLogLog, geo
    "XLEN", "XRANGE", "XREVRANGE", "XPENDING", "PFCOUNT", "GEOPOS", "GEODIST", "GEOHASH",
    "GEOSEARCH", "GEORADIUS_RO", "GEORADIUSBYMEMBER_RO",
    // Read-only scripts and sort: the server refuses a write inside them
    "EVAL_RO", "EVALSHA_RO", "FCALL_RO", "SORT_RO",
  ]

  /// Commands allowed with one of these subcommands only
  private static let subcommandReads: [String: Set<String>] = [
    "MEMORY": ["USAGE"],
    "OBJECT": ["ENCODING", "FREQ", "IDLETIME", "REFCOUNT"],
    "XINFO": ["STREAM", "GROUPS", "CONSUMERS"],
  ]

  /// The `INFO` sections allowed, one per command
  private static let infoSections: Set<String> = ["KEYSPACE", "SERVER"]

  /// Nil when `args` may be sent on a read-only connection, else the failure to answer
  static func refusal(_ args: [Data]) -> EngineFailure? {
    guard let first = args.first else {
      return EngineFailure(code: .invalid, message: "The command is empty.")
    }
    let name = word(first)
    if let name, allows(name, args) { return nil }
    return EngineFailure(
      code: .query, message: "This connection is read-only: \(shown(name)) is not allowed.")
  }

  /// `name` when it is a short word of letters, digits and `_`, else "the command"
  private static func shown(_ name: String?) -> String {
    guard let name, name.utf8.count <= 32,
      name.utf8.allSatisfy({
        $0 == 0x5F || (0x30...0x39).contains($0) || (0x41...0x5A).contains($0)
      })
    else { return "the command" }
    return name
  }

  private static func allows(_ name: String, _ args: [Data]) -> Bool {
    if reads.contains(name) { return true }
    if let allowed = subcommandReads[name] {
      return args.count >= 2 && word(args[1]).map(allowed.contains) == true
    }
    switch name {
    case "INFO": return args.count == 2 && word(args[1]).map(infoSections.contains) == true
    case "XREAD":
      // `STREAMS` right away, or after one `COUNT n`; anything else (`BLOCK`) is refused
      return word(at: 1, args) == "STREAMS"
        || (word(at: 1, args) == "COUNT" && word(at: 3, args) == "STREAMS")
    default: return false
    }
  }

  private static func word(at index: Int, _ args: [Data]) -> String? {
    index < args.count ? word(args[index]) : nil
  }

  /// `bytes` upper-cased, nil unless it is all printable ASCII (and not empty)
  private static func word(_ bytes: Data) -> String? {
    guard !bytes.isEmpty, bytes.allSatisfy({ (0x21...0x7E).contains($0) }) else { return nil }
    return String(
      decoding: bytes.map { (0x61...0x7A).contains($0) ? $0 - 0x20 : $0 }, as: UTF8.self)
  }
}
