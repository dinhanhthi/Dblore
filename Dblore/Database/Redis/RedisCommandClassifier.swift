// RedisCommandClassifier.swift
// Classifies one Redis command (its exact argument array) into the SQL classifier's
// `ClassifiedStatement`, so the execution gate applies the same policies to Redis, and finds the
// commands that carry a secret.

import Foundation

/// A Redis command as the gate reads it
nonisolated struct RedisClassification: Sendable, Equatable {
  /// Kind and destructive flag for the gate; `text` is `RedisCommandClassifier.redactedText`,
  /// so a secret never reaches a confirmation
  let statement: ClassifiedStatement
  /// Why the command editor refuses the command, nil when it may go on to the policies. A
  /// refused command is also `.unknown`, so a caller that misses the refusal still fails closed.
  let refusal: String?
}

/// Maps a Redis argument array to a `StatementKind`:
/// - reads → `.read`, only those the plugin's read-only allowlist also allows
///   (`Plugins/Engines/Redis/RedisReadOnly.swift`): `INFO` with exactly the section `keyspace`
///   or `server`, `MEMORY USAGE`, `OBJECT ENCODING / FREQ / IDLETIME / REFCOUNT`, `XINFO STREAM /
///   GROUPS / CONSUMERS`, `XREAD [COUNT n] STREAMS …`, and the `*_RO` scripts (the server refuses
///   a write inside them). Any other read (`EXPIRETIME`, `LCS`, `INFO all`, `MEMORY STATS`, …) is
///   admin.
/// - data writes → `.dml`; admin → `.utility`; destructive (always confirmed) → `.utility` with
///   `isDestructive`: `FLUSHALL`, `KEYS`, every `CONFIG` subcommand, `CLIENT KILL`, `ACL LOAD`,
///   `FUNCTION LOAD … REPLACE`, ….
/// - scripts (`EVAL`, `EVALSHA`, `FCALL`), module and unknown commands → `.unknown` (fail closed;
///   never `.dml`, which schema-only lets through). An unlisted subcommand of a known admin
///   command is admin.
/// - refused in the editor (connection state, push and replication streams, blocking,
///   `SHUTDOWN`, `DEBUG`, `SCRIPT DEBUG`) → `.unknown` with a `refusal`.
/// The command name (and a subcommand) matches case-insensitively only when every byte is
/// printable ASCII; any other name is `.unknown`.
///
/// `.unknown` gets the treatment SQL and MongoDB give it. The gate's shared policy
/// (`DatabaseConnectionManager.evaluate`) blocks it on read-only and schema-only and lets it
/// through at protection level none, where confirming is not the gate's job. For SQL and MongoDB
/// the editor asks first under the Confirm and Password commit styles
/// (`NotebookViewModel.statementsNeedingConfirmation`, whose `mayWrite` lists `.dml`, `.ddl`,
/// `.utility` and `.unknown`); the Redis command runner must apply the same rule.
nonisolated enum RedisCommandClassifier {

  /// Classify one command. Secrets are found first: the text is redacted even when refused.
  static func classify(_ args: [Data]) -> RedisClassification {
    let text = redactedText(args)
    guard let name = args.first.flatMap(word) else {
      return RedisClassification(statement: statement(text, kind: .unknown), refusal: nil)
    }
    if let refusal = refusal(name, args) {
      return RedisClassification(statement: statement(text, kind: .unknown), refusal: refusal)
    }
    return RedisClassification(statement: statement(text, args: args, name: name), refusal: nil)
  }

  /// `args` carry a password or a user name to log in with: `AUTH`, `HELLO … AUTH`, `ACL SETUSER`
  /// with a password rule (`>` `<` `#` `!`), `CONFIG SET` of a password parameter, `MIGRATE …
  /// AUTH / AUTH2`, `SENTINEL SET … auth-pass / auth-user`, `SENTINEL CONFIG SET sentinel-pass /
  /// sentinel-user`. History and logs must skip such a command.
  static func containsSecret(_ args: [Data]) -> Bool { secretPositions(args) != nil }

  /// `RedisTokenizer.render(args)` with every secret argument replaced by the password mask
  static func redactedText(_ args: [Data]) -> String {
    guard let positions = secretPositions(args) else { return RedisTokenizer.render(args) }
    let mask = Data(EnginePluginSession.passwordMask.utf8)
    return RedisTokenizer.render(
      args.enumerated().map { positions.contains($0.offset) ? mask : $0.element })
  }

  // MARK: - Tables

  /// Reads by name alone: the plugin's read-only list, so read-only connections can browse
  static let reads: Set<String> = [
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
    // Sorted sets (`ZRANGE` has no store form; that is `ZRANGESTORE`)
    "ZCARD", "ZCOUNT", "ZLEXCOUNT", "ZSCORE", "ZMSCORE", "ZRANK", "ZREVRANK", "ZRANGE",
    "ZREVRANGE", "ZRANGEBYSCORE", "ZREVRANGEBYSCORE", "ZRANGEBYLEX", "ZREVRANGEBYLEX",
    "ZRANDMEMBER", "ZSCAN",
    // Streams, HyperLogLog, geo
    "XLEN", "XRANGE", "XREVRANGE", "XPENDING", "PFCOUNT", "GEOPOS", "GEODIST", "GEOHASH",
    "GEOSEARCH", "GEORADIUS_RO", "GEORADIUSBYMEMBER_RO",
    // Read-only scripts and sort. The server refuses a write inside a `*_RO` script: on Redis
    // 8.10.3 an `EVAL_RO` calling `PUBLISH`, `SPUBLISH`, `PFCOUNT` or `SET` answered "ERR Write
    // commands are not allowed from read-only scripts" (checked against a `redis:8` container
    // during the phase 5 review). A busy `*_RO` loop is bounded by the statement brake and the
    // plugin's `SCRIPT KILL` (phase 3).
    "EVAL_RO", "EVALSHA_RO", "FCALL_RO", "SORT_RO",
  ]

  /// Reads with one of these subcommands only; other subcommands are admin
  static let subcommandReads: [String: Set<String>] = [
    "MEMORY": ["USAGE"],
    "OBJECT": ["ENCODING", "FREQ", "IDLETIME", "REFCOUNT"],
    "XINFO": ["STREAM", "GROUPS", "CONSUMERS"],
  ]

  /// The `INFO` sections that make a read, one per command
  private static let infoSections: Set<String> = ["KEYSPACE", "SERVER"]

  /// Data writes, store forms included (`SORT … STORE`, `GEORADIUS … STORE`)
  private static let writes: Set<String> = [
    // Keys and strings
    "SET", "SETNX", "SETEX", "PSETEX", "MSET", "MSETNX", "GETSET", "GETDEL", "GETEX", "APPEND",
    "INCR", "INCRBY", "INCRBYFLOAT", "DECR", "DECRBY", "SETRANGE", "SETBIT", "BITOP", "BITFIELD",
    "DEL", "UNLINK", "EXPIRE", "PEXPIRE", "EXPIREAT", "PEXPIREAT", "PERSIST", "RENAME",
    "RENAMENX", "COPY", "MOVE", "RESTORE", "SORT",
    // Hashes
    "HSET", "HSETNX", "HMSET", "HDEL", "HINCRBY", "HINCRBYFLOAT", "HEXPIRE", "HPEXPIRE",
    "HEXPIREAT", "HPEXPIREAT", "HPERSIST", "HGETDEL", "HGETEX", "HSETEX",
    // Lists
    "LPUSH", "RPUSH", "LPUSHX", "RPUSHX", "LINSERT", "LSET", "LREM", "LTRIM", "LPOP", "RPOP",
    "RPOPLPUSH", "LMOVE", "LMPOP",
    // Sets
    "SADD", "SREM", "SPOP", "SMOVE", "SINTERSTORE", "SUNIONSTORE", "SDIFFSTORE",
    // Sorted sets
    "ZADD", "ZINCRBY", "ZREM", "ZREMRANGEBYRANK", "ZREMRANGEBYSCORE", "ZREMRANGEBYLEX",
    "ZPOPMIN", "ZPOPMAX", "ZMPOP", "ZRANGESTORE", "ZUNIONSTORE", "ZINTERSTORE", "ZDIFFSTORE",
    // Streams (`XREADGROUP` writes the pending list)
    "XADD", "XDEL", "XTRIM", "XACK", "XCLAIM", "XAUTOCLAIM", "XGROUP", "XSETID", "XREADGROUP",
    // HyperLogLog and geo
    "PFADD", "PFMERGE", "GEOADD", "GEOSEARCHSTORE", "GEORADIUS", "GEORADIUSBYMEMBER",
  ]

  /// Admin, and reads the plugin's read-only list refuses. Their unlisted subcommands land here.
  private static let admin: Set<String> = [
    "INFO", "MEMORY", "OBJECT", "XINFO", "XREAD", "CLIENT", "SCRIPT", "FUNCTION", "ACL",
    "MODULE", "COMMAND", "LASTSAVE", "LATENCY", "SLOWLOG", "ROLE", "LOLWUT", "DUMP", "TOUCH",
    "EXPIRETIME", "PEXPIRETIME", "LCS", "SUBSTR", "HTTL", "HPTTL", "HEXPIRETIME", "HPEXPIRETIME",
    "ZUNION", "ZINTER", "ZDIFF", "ZINTERCARD", "PUBLISH", "SPUBLISH", "PUBSUB",
  ]

  /// Destructive by name (every `CONFIG` subcommand)
  private static let destructive: Set<String> = [
    "FLUSHALL", "FLUSHDB", "SWAPDB", "MIGRATE", "REPLICAOF", "SLAVEOF", "FAILOVER", "SAVE",
    "BGSAVE", "BGREWRITEAOF", "KEYS", "CONFIG",
  ]

  /// Destructive with one of these subcommands (and `FUNCTION LOAD … REPLACE`, see
  /// `statement`)
  private static let destructiveSubcommands: [String: Set<String>] = [
    "SCRIPT": ["FLUSH"],
    "FUNCTION": ["FLUSH", "DELETE", "RESTORE"],
    "ACL": ["SETUSER", "DELUSER", "LOAD", "SAVE"],
    "MODULE": ["LOAD", "LOADEX", "UNLOAD"],
    "CLIENT": ["KILL", "PAUSE"],
  ]

  /// Change the state of the connection every tab, the sidebar and the key tab share
  private static let connectionState: Set<String> = [
    "SELECT", "AUTH", "HELLO", "RESET", "QUIT", "WATCH", "UNWATCH", "MULTI", "EXEC", "DISCARD",
    "READONLY", "READWRITE", "ASKING", "REPLCONF",
  ]
  private static let clientState: Set<String> = [
    "REPLY", "TRACKING", "CACHING", "NO-EVICT", "NO-TOUCH", "SETNAME", "SETINFO",
  ]
  /// Belong to a stream of pushed messages: Pub/Sub, `MONITOR`, and replication (`SYNC` and
  /// `PSYNC` turn the connection into a replica's stream)
  private static let push: Set<String> = [
    "SUBSCRIBE", "PSUBSCRIBE", "SSUBSCRIBE", "UNSUBSCRIBE", "PUNSUBSCRIBE", "SUNSUBSCRIBE",
    "MONITOR", "SYNC", "PSYNC",
  ]
  /// Can wait on the server and hold the connection
  private static let blocking: Set<String> = [
    "BLPOP", "BRPOP", "BRPOPLPUSH", "BLMOVE", "BLMPOP", "BZPOPMIN", "BZPOPMAX", "BZMPOP", "WAIT",
    "WAITAOF",
  ]

  /// The password parameters of `CONFIG SET` (`PRIMARYAUTH` / `PRIMARYUSER`: the aliases of
  /// `MASTERAUTH` / `MASTERUSER`)
  private static let secretParameters: Set<String> = [
    "REQUIREPASS", "MASTERAUTH", "MASTERUSER", "PRIMARYAUTH", "PRIMARYUSER", "TLS-KEY-FILE-PASS",
    "TLS-CLIENT-KEY-FILE-PASS",
  ]
  /// The options of `SENTINEL SET` that log in to the monitored master
  private static let sentinelSecretOptions: Set<String> = ["AUTH-PASS", "AUTH-USER"]
  /// The parameters of `SENTINEL CONFIG SET` that log in to the other sentinels
  private static let sentinelSecretParameters: Set<String> = ["SENTINEL-PASS", "SENTINEL-USER"]

  /// First bytes of an `ACL SETUSER` rule that names a password or its hash
  private static let passwordRuleStarts: Set<UInt8> = [
    UInt8(ascii: ">"), UInt8(ascii: "<"), UInt8(ascii: "#"), UInt8(ascii: "!"),
  ]

  // MARK: - Editor names

  /// Every command name the tables above know, refused ones included, plus the scripts and the
  /// commands refused by name in `refusal`. The editor's highlighter and completion read it;
  /// classification does not.
  static let commandNames: Set<String> = reads.union(writes).union(admin).union(destructive)
    .union(subcommandReads.keys).union(connectionState).union(push).union(blocking)
    .union(["EVAL", "EVALSHA", "FCALL", "SHUTDOWN", "DEBUG"])

  /// The subcommands of the commands that take one, refused ones included (a superset of the
  /// subcommand tables above). The editor's highlighter and completion read it; classification
  /// does not.
  static let subcommandNames: [String: Set<String>] = [
    "ACL": [
      "CAT", "DELUSER", "DRYRUN", "GENPASS", "GETUSER", "HELP", "LIST", "LOAD", "LOG", "SAVE",
      "SETUSER", "USERS", "WHOAMI",
    ],
    "CLIENT": [
      "CACHING", "GETNAME", "GETREDIR", "HELP", "ID", "INFO", "KILL", "LIST", "NO-EVICT",
      "NO-TOUCH", "PAUSE", "REPLY", "SETINFO", "SETNAME", "TRACKING", "TRACKINGINFO", "UNBLOCK",
      "UNPAUSE",
    ],
    "COMMAND": ["COUNT", "DOCS", "GETKEYS", "GETKEYSANDFLAGS", "HELP", "INFO", "LIST"],
    "CONFIG": ["GET", "HELP", "RESETSTAT", "REWRITE", "SET"],
    "FUNCTION": ["DELETE", "DUMP", "FLUSH", "HELP", "KILL", "LIST", "LOAD", "RESTORE", "STATS"],
    "LATENCY": ["DOCTOR", "GRAPH", "HELP", "HISTOGRAM", "HISTORY", "LATEST", "RESET"],
    "MEMORY": ["DOCTOR", "HELP", "MALLOC-STATS", "PURGE", "STATS", "USAGE"],
    "MODULE": ["HELP", "LIST", "LOAD", "LOADEX", "UNLOAD"],
    "OBJECT": ["ENCODING", "FREQ", "HELP", "IDLETIME", "REFCOUNT"],
    "PUBSUB": ["CHANNELS", "HELP", "NUMPAT", "NUMSUB", "SHARDCHANNELS", "SHARDNUMSUB"],
    "SCRIPT": ["DEBUG", "EXISTS", "FLUSH", "HELP", "KILL", "LOAD"],
    "SLOWLOG": ["GET", "HELP", "LEN", "RESET"],
    "XGROUP": ["CREATE", "CREATECONSUMER", "DELCONSUMER", "DESTROY", "HELP", "SETID"],
    "XINFO": ["CONSUMERS", "GROUPS", "HELP", "STREAM"],
  ]

  // MARK: - Classification

  /// Why the editor refuses `args`, nil when it does not
  private static func refusal(_ name: String, _ args: [Data]) -> String? {
    let subcommand = word(at: 1, args)
    if connectionState.contains(name) {
      return "\(name) changes the connection's state, which every tab shares."
    }
    if name == "CLIENT", let subcommand, clientState.contains(subcommand) {
      return "CLIENT \(subcommand) changes the connection's state, which every tab shares."
    }
    if push.contains(name) {
      return "\(name) belongs to a message or replication stream; it cannot run here."
    }
    if blocking.contains(name) {
      return "\(name) can wait on the server and hold the connection; it cannot run here."
    }
    // `XREAD` in its read form takes no BLOCK; any other form and `XREADGROUP` are refused when
    // any argument is BLOCK (a key named BLOCK too: fail closed)
    let blocks = args.dropFirst().contains { word($0) == "BLOCK" }
    if (name == "XREADGROUP" || (name == "XREAD" && !isRead(name, args))) && blocks {
      return "\(name) with BLOCK can hold the connection; it cannot run here."
    }
    switch name {
    case "SHUTDOWN": return "SHUTDOWN stops the server; it cannot run here."
    case "DEBUG": return "DEBUG can stop or crash the server; it cannot run here."
    case "SCRIPT" where subcommand == "DEBUG":
      return "SCRIPT DEBUG turns the connection into a debugger session; it cannot run here."
    default: return nil
    }
  }

  /// The classified statement of a command the editor does not refuse
  private static func statement(_ text: String, args: [Data], name: String) -> ClassifiedStatement {
    if isRead(name, args) { return statement(text, kind: .read) }
    let subcommand = word(at: 1, args)
    // `FUNCTION LOAD REPLACE` overwrites a library (any later REPLACE: fail closed)
    let replacesLibrary =
      name == "FUNCTION" && subcommand == "LOAD"
      && args.dropFirst(2).contains { word($0) == "REPLACE" }
    if destructive.contains(name) || replacesLibrary
      || subcommand.map { destructiveSubcommands[name]?.contains($0) == true } == true
    {
      return statement(text, kind: .utility, isDestructive: true)
    }
    if writes.contains(name) { return statement(text, kind: .dml) }
    if admin.contains(name) { return statement(text, kind: .utility) }
    // Scripts (`EVAL`, `EVALSHA`, `FCALL`), module and unknown commands
    return statement(text, kind: .unknown)
  }

  /// A read the plugin's read-only allowlist also allows
  private static func isRead(_ name: String, _ args: [Data]) -> Bool {
    if reads.contains(name) { return true }
    if let allowed = subcommandReads[name] {
      return word(at: 1, args).map(allowed.contains) == true
    }
    switch name {
    case "INFO": return args.count == 2 && word(args[1]).map(infoSections.contains) == true
    case "XREAD":
      return word(at: 1, args) == "STREAMS"
        || (word(at: 1, args) == "COUNT" && word(at: 3, args) == "STREAMS")
    default: return false
    }
  }

  private static func statement(
    _ text: String, kind: StatementKind, isDestructive: Bool = false
  ) -> ClassifiedStatement {
    ClassifiedStatement(
      text: text, kind: kind, hasReturning: false, hasTopLevelReturning: false,
      affectsAllRows: false, nonTransactional: false, resetsSessionBrakes: false,
      changesPrivileges: false, createsTable: false, isDestructive: isDestructive)
  }

  // MARK: - Secrets

  /// nil when `args` carry no secret, else the positions of the arguments to mask (possibly
  /// none, as in a bare `AUTH`). Over-matches rather than misses: a key or host named AUTH masks
  /// what follows it.
  private static func secretPositions(_ args: [Data]) -> Set<Int>? {
    guard let name = args.first.flatMap(word) else { return nil }
    var positions = Set<Int>()
    switch name {
    case "AUTH":
      return Set(args.indices.dropFirst())
    case "HELLO":
      // HELLO [protover [AUTH username password] [SETNAME name]]
      guard args.dropFirst().contains(where: { word($0) == "AUTH" }) else { return nil }
      for index in args.indices.dropFirst() where word(args[index]) == "AUTH" {
        positions.formUnion(following(index, count: 2, in: args))
      }
    case "MIGRATE":
      // … [AUTH password | AUTH2 username password] …
      let options = args.indices.dropFirst().filter {
        word(args[$0]).map { ["AUTH", "AUTH2"].contains($0) } == true
      }
      guard !options.isEmpty else { return nil }
      for index in options {
        positions.formUnion(following(index, count: word(args[index]) == "AUTH" ? 1 : 2, in: args))
      }
    case "ACL":
      // ACL SETUSER username [rule …]: `>pw` `<pw` `#hash` `!hash` name a password. Checked
      // from the user name on, so a missing user name still hides the password.
      guard word(at: 1, args) == "SETUSER" else { return nil }
      let rules = args.indices.dropFirst(2).filter {
        args[$0].first.map(passwordRuleStarts.contains) == true
      }
      guard !rules.isEmpty else { return nil }
      positions.formUnion(rules)
    case "CONFIG":
      // CONFIG SET parameter value [parameter value …]: a password parameter at any position,
      // so a missing value earlier still hides the password
      guard word(at: 1, args) == "SET" else { return nil }
      let parameters = args.indices.dropFirst(2).filter {
        word(args[$0]).map(secretParameters.contains) == true
      }
      guard !parameters.isEmpty else { return nil }
      for index in parameters { positions.formUnion(following(index, count: 1, in: args)) }
    case "SENTINEL":
      // SENTINEL SET master option value [option value …] and SENTINEL CONFIG SET parameter
      // value [parameter value …]: a secret option at any position (`MONITOR` carries none)
      let (names, first): (Set<String>, Int)
      switch (word(at: 1, args), word(at: 2, args)) {
      case ("SET", _): (names, first) = (sentinelSecretOptions, 2)
      case ("CONFIG", "SET"): (names, first) = (sentinelSecretParameters, 3)
      default: return nil
      }
      let options = args.indices.dropFirst(first).filter {
        word(args[$0]).map(names.contains) == true
      }
      guard !options.isEmpty else { return nil }
      for index in options { positions.formUnion(following(index, count: 1, in: args)) }
    default:
      return nil
    }
    return positions
  }

  /// The up to `count` positions after `index`
  private static func following(_ index: Int, count: Int, in args: [Data]) -> Range<Int> {
    (index + 1)..<min(index + 1 + count, args.count)
  }

  // MARK: - Words

  private static func word(at index: Int, _ args: [Data]) -> String? {
    index < args.count ? word(args[index]) : nil
  }

  /// `bytes` upper-cased (ASCII only), nil unless every byte is printable ASCII (and not empty)
  private static func word(_ bytes: Data) -> String? {
    guard !bytes.isEmpty, bytes.allSatisfy({ (0x21...0x7E).contains($0) }) else { return nil }
    return String(
      decoding: bytes.map { (0x61...0x7A).contains($0) ? $0 - 0x20 : $0 }, as: UTF8.self)
  }
}
