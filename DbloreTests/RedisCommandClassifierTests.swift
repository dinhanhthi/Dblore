// RedisCommandClassifierTests.swift
// The Redis language core: command text to exact argument bytes and back (tokenizer), key
// identity on bytes, and log text without arguments

import Foundation
import Testing

@testable import Dblore

@Suite("Redis command language")
struct RedisCommandClassifierTests {

  private static func text(_ value: String) -> Data { Data(value.utf8) }

  /// "café" precomposed (U+00E9) and decomposed (e + U+0301): equal as Swift strings, not as bytes
  private static let cafeNFC = Data([0x63, 0x61, 0x66, 0xC3, 0xA9])
  private static let cafeNFD = Data([0x63, 0x61, 0x66, 0x65, 0xCC, 0x81])

  // MARK: - Tokenizer

  @Suite("Tokenizer")
  struct Tokenizer {

    @Test("A quoted CR LF and quoted hex bytes stay one argument each, with those exact bytes")
    func quotedEscapesStayOneArgument() throws {
      let commands = try RedisTokenizer.tokenize(#"SET k "\r\n" "\xff\x00""#)
      #expect(
        commands == [[text("SET"), text("k"), Data([0x0D, 0x0A]), Data([0xFF, 0x00])]])
    }

    @Test("Single quotes take only \\' as an escape")
    func singleQuoteEscape() throws {
      let commands = try RedisTokenizer.tokenize(#"SET k 'it\'s' 'a\nb'"#)
      #expect(commands == [[text("SET"), text("k"), text("it's"), text(#"a\nb"#)]])
    }

    @Test("Blank and # lines are skipped and each line is one command")
    func linesAndComments() throws {
      let commands = try RedisTokenizer.tokenize("PING\n\n   # FLUSHALL\r\nGET  k\r\n\t\n")
      #expect(commands == [[text("PING")], [text("GET"), text("k")]])
    }

    @Test(
      "Bad quoting throws with its line number and never returns a partial command",
      arguments: [
        ("PING\nSET k \"abc", RedisTokenizer.TokenizeError.unterminatedQuote(line: 2)),
        ("SET k 'abc\nPING", .unterminatedQuote(line: 1)),
        ("SET k \"a\"b", .quoteNotFollowedBySpace(line: 1)),
        (#"SET k "\xZZ""#, .invalidHexEscape(line: 1)),
      ])
    func badQuotingThrows(input: String, expected: RedisTokenizer.TokenizeError) {
      #expect(throws: expected) { try RedisTokenizer.tokenize(input) }
    }

    @Test(
      "render then tokenize gives back the same bytes",
      arguments: [
        Data(),
        text(" a  b "),
        text("\""),
        text("'"),
        text("\\"),
        text("\r\n"),
        Data([0xFF, 0x00]),
        text("#not-a-comment"),
        cafeNFC,
        cafeNFD,
        text("v\r\nFLUSHALL"),
      ])
    func renderRoundTrip(argument: Data) throws {
      // First position covers the leading `#` (a comment line) and the command name
      let args = [argument, text("k"), argument]
      #expect(try RedisTokenizer.tokenize(RedisTokenizer.render(args)) == [args])
    }
  }

  // MARK: - Key identity and log text

  @Suite("Key identity and log text")
  struct KeyIdentity {

    @Test("Keys that differ only in Unicode normalization are different keys")
    func normalizationTwinsStayDistinct() {
      let nfc = RedisKeyRef(db: 0, bytes: cafeNFC)
      let nfd = RedisKeyRef(db: 0, bytes: cafeNFD)
      #expect(nfc != nfd)
      #expect(Set([nfc, nfd]).count == 2)
    }

    @Test("Log text shows the command name and the argument count, never an argument")
    func logTextHasNoArguments() {
      let command = RedisCommand(args: [text("auth"), text("qa_user"), text("s3cret")], db: 0)
      let expected = "RedisCommand(command: AUTH, argCount: 3)"
      #expect(command.logDescription == expected)
      #expect(String(describing: command) == expected)
      #expect(String(reflecting: command) == expected)
    }
  }

  // MARK: - Classifier and secret check

  @Suite("Classifier")
  struct Classifier {

    /// Arguments split at single spaces (no quoting needed in these rows)
    private static func argv(_ line: String) -> [Data] {
      line.split(separator: " ").map { Data($0.utf8) }
    }

    private static func classify(_ line: String) -> RedisClassification {
      RedisCommandClassifier.classify(argv(line))
    }

    @Test(
      "Unknown, module and script commands are unknown (fail closed), never a write",
      arguments: [
        "FOOBAR k", "JSON.SET k $ {}", "FT.SEARCH idx hello", "EVAL return 0", "EVALSHA abc 0",
        "FCALL f 0", "CLUSTER RESET",
      ])
    func failClosed(line: String) {
      let result = Self.classify(line)
      #expect(result.statement.kind == .unknown)
      #expect(result.refusal == nil)
    }

    @Test(
      "A command name that is not printable ASCII is unknown",
      arguments: [
        [Data("G\u{00C9}T".utf8), Data("k".utf8)],  // "GÉT"
        [Data([0x47, 0x45, 0x54, 0x00]), Data("k".utf8)],  // "GET" + NUL
        [Data([0xFF]), Data("k".utf8)],
        [Data(), Data("k".utf8)],
        [],
      ])
    func nonASCIINameIsUnknown(args: [Data]) {
      #expect(RedisCommandClassifier.classify(args).statement.kind == .unknown)
    }

    @Test(
      "Reads, the app's own included, are reads and may run",
      arguments: [
        "INFO keyspace", "info Server", "DBSIZE", "TYPE k", "PTTL k", "STRLEN k", "MEMORY USAGE k",
        "GETRANGE k 0 9", "SCAN 0 COUNT 500", "HSCAN k 0", "SSCAN k 0", "ZSCAN k 0",
        "LRANGE k 0 -1", "ZRANGE k 0 -1", "XRANGE s - +", "PING", "get k", "EVAL_RO return 0",
        "FCALL_RO f 0", "SORT_RO k", "XREAD STREAMS s 0", "XREAD COUNT 10 STREAMS s 0",
        "OBJECT ENCODING k", "XINFO STREAM s",
      ])
    func reads(line: String) {
      let result = Self.classify(line)
      #expect(result.statement.kind == .read)
      #expect(result.refusal == nil)
      #expect(!result.statement.isDestructive)
    }

    @Test(
      "Reads the plugin's read-only list refuses are admin, not reads",
      arguments: [
        "INFO", "INFO all", "INFO keyspace server", "INFO commandstats", "MEMORY STATS",
        "OBJECT HELP", "XINFO HELP", "XREAD COUNT 1 COUNT 2 STREAMS s 0", "EXPIRETIME k",
        "LCS a b", "COMMAND",
      ])
    func notPluginReads(line: String) {
      let result = Self.classify(line)
      #expect(result.statement.kind == .utility)
      #expect(result.refusal == nil)
    }

    @Test(
      "Connection state, push, replication, blocking and debugging commands are refused",
      arguments: [
        "SELECT 1", "AUTH pw", "MULTI", "CLIENT SETNAME x", "client tracking on", "SUBSCRIBE ch",
        "MONITOR", "BLPOP k 0", "WAIT 1 0", "XREAD BLOCK 0 STREAMS s $",
        "XREAD COUNT 1 BLOCK 0 STREAMS s $", "XREADGROUP GROUP g c BLOCK 0 STREAMS s >",
        // A consumer named STREAMS: the BLOCK option still follows
        "XREADGROUP GROUP g STREAMS BLOCK 0 STREAMS s >", "SHUTDOWN NOSAVE", "DEBUG SLEEP 10",
        "READONLY", "readwrite", "ASKING", "REPLCONF listening-port 6380", "SYNC",
        "PSYNC ? -1", "UNSUBSCRIBE ch", "PUNSUBSCRIBE p*", "SUNSUBSCRIBE ch",
        "SCRIPT DEBUG YES", "script debug sync",
      ])
    func refused(line: String) {
      let result = Self.classify(line)
      #expect(result.refusal != nil)
      #expect(result.statement.kind == .unknown)
    }

    @Test(
      "Destructive commands are admin, always confirmed",
      arguments: [
        "FLUSHALL", "FLUSHDB ASYNC", "KEYS *", "SWAPDB 0 1", "CONFIG GET maxmemory",
        "CONFIG SET maxmemory 1mb", "SCRIPT FLUSH", "FUNCTION DELETE lib", "ACL DELUSER u",
        "MODULE UNLOAD m", "CLIENT KILL ID 7", "CLIENT PAUSE 1000", "MIGRATE h 6379 k 0 5000",
        "ACL LOAD", "acl save", "FUNCTION LOAD REPLACE code", "function load replace code",
      ])
    func destructive(line: String) {
      let result = Self.classify(line)
      #expect(result.statement.kind == .utility)
      #expect(result.statement.isDestructive)
      #expect(result.refusal == nil)
      #expect(DestructiveStatementRule.evaluate(result.statement, dialect: .redis) != .none)
    }

    @Test(
      "Data writes are DML and not destructive",
      arguments: [
        "SET k v", "HSET k f v", "DEL k", "LPUSH k v", "ZADD k 1 m", "XADD s * f v",
        "XREADGROUP GROUP g c STREAMS s >", "SORT k STORE d", "GEORADIUS k 0 0 1 km",
      ])
    func writes(line: String) {
      let result = Self.classify(line)
      #expect(result.statement.kind == .dml)
      #expect(!result.statement.isDestructive)
      #expect(result.refusal == nil)
      #expect(DestructiveStatementRule.evaluate(result.statement, dialect: .redis) == .none)
    }

    @Test(
      "Admin commands with harmless subcommands are admin and not destructive",
      arguments: [
        "CLIENT LIST", "SCRIPT LOAD x", "ACL WHOAMI", "SLOWLOG GET", "FUNCTION LOAD code",
      ])
    func admin(line: String) {
      let result = Self.classify(line)
      #expect(result.statement.kind == .utility)
      #expect(!result.statement.isDestructive)
      #expect(result.refusal == nil)
    }

    @Test(
      "Secrets are found before any refusal and masked in the text",
      arguments: [
        ("AUTH s3cret", "AUTH ••••"),
        ("auth qa_user s3cret", "auth •••• ••••"),
        ("HELLO 3 AUTH qa_user s3cret SETNAME n", "HELLO 3 AUTH •••• •••• SETNAME n"),
        ("ACL SETUSER u on >s3cret ~* +@all", "ACL SETUSER u on •••• ~* +@all"),
        ("ACL SETUSER u #s3cret <old !s3cret", "ACL SETUSER u •••• •••• ••••"),
        (
          "CONFIG SET maxmemory 1mb requirepass s3cret",
          "CONFIG SET maxmemory 1mb requirepass ••••"
        ),
        (
          "config set MasterAuth s3cret masteruser s3cret",
          "config set MasterAuth •••• masteruser ••••"
        ),
        (
          "CONFIG SET primaryauth s3cret PrimaryUser s3cret",
          "CONFIG SET primaryauth •••• PrimaryUser ••••"
        ),
        // Mistyped forms: a missing value or user name still hides the password
        ("CONFIG SET maxmemory requirepass s3cret", "CONFIG SET maxmemory requirepass ••••"),
        ("ACL SETUSER >s3cret", "ACL SETUSER ••••"),
        ("MIGRATE h 6379 k 0 5000 AUTH s3cret", "MIGRATE h 6379 k 0 5000 AUTH ••••"),
        (
          "MIGRATE h 6379 k 0 5000 COPY AUTH2 s3cret s3cret KEYS a",
          "MIGRATE h 6379 k 0 5000 COPY AUTH2 •••• •••• KEYS a"
        ),
        ("SENTINEL SET m auth-pass s3cret", "SENTINEL SET m auth-pass ••••"),
        (
          "sentinel set m quorum 2 AUTH-USER s3cret auth-pass s3cret",
          "sentinel set m quorum 2 AUTH-USER •••• auth-pass ••••"
        ),
        ("SENTINEL CONFIG SET sentinel-pass s3cret", "SENTINEL CONFIG SET sentinel-pass ••••"),
        (
          "SENTINEL CONFIG SET sentinel-user s3cret sentinel-pass s3cret",
          "SENTINEL CONFIG SET sentinel-user •••• sentinel-pass ••••"
        ),
      ])
    func secrets(line: String, redacted: String) {
      let args = Self.argv(line)
      #expect(RedisCommandClassifier.containsSecret(args))
      #expect(RedisCommandClassifier.redactedText(args) == redacted)
      // The classified text, shown in confirmations, is the redacted one
      #expect(RedisCommandClassifier.classify(args).statement.text == redacted)
      #expect(!redacted.contains("s3cret"))
    }

    @Test(
      "Commands without a secret render unchanged",
      arguments: [
        "ACL SETUSER u on ~* +@all", "CONFIG SET maxmemory 1mb", "SET auth s3cret",
        "SENTINEL MONITOR m 127.0.0.1 6379 2", "SENTINEL SET m quorum 2",
      ])
    func noSecret(line: String) {
      let args = Self.argv(line)
      #expect(!RedisCommandClassifier.containsSecret(args))
      #expect(RedisCommandClassifier.redactedText(args) == line)
    }

    // MARK: Plugin allowlist

    /// Copy of the plugin's read-only allowlist, `Plugins/Engines/Redis/RedisReadOnly.swift`
    /// (`reads`, `subcommandReads`, `infoSections` and the `XREAD` rule). Keep in step with it.
    private static let pluginReads: Set<String> = [
      "PING", "ECHO", "TIME", "DBSIZE", "RANDOMKEY", "EXISTS", "TYPE", "TTL", "PTTL", "SCAN",
      "GET", "MGET", "STRLEN", "GETRANGE", "GETBIT", "BITCOUNT", "BITPOS", "BITFIELD_RO",
      "HGET", "HMGET", "HGETALL", "HLEN", "HKEYS", "HVALS", "HEXISTS", "HSTRLEN", "HRANDFIELD",
      "HSCAN", "LLEN", "LINDEX", "LPOS", "LRANGE", "SCARD", "SISMEMBER", "SMISMEMBER",
      "SMEMBERS", "SRANDMEMBER", "SINTER", "SUNION", "SDIFF", "SINTERCARD", "SSCAN", "ZCARD",
      "ZCOUNT", "ZLEXCOUNT", "ZSCORE", "ZMSCORE", "ZRANK", "ZREVRANK", "ZRANGE", "ZREVRANGE",
      "ZRANGEBYSCORE", "ZREVRANGEBYSCORE", "ZRANGEBYLEX", "ZREVRANGEBYLEX", "ZRANDMEMBER",
      "ZSCAN", "XLEN", "XRANGE", "XREVRANGE", "XPENDING", "PFCOUNT", "GEOPOS", "GEODIST",
      "GEOHASH", "GEOSEARCH", "GEORADIUS_RO", "GEORADIUSBYMEMBER_RO", "EVAL_RO", "EVALSHA_RO",
      "FCALL_RO", "SORT_RO",
    ]
    private static let pluginSubcommandReads: [String: Set<String>] = [
      "MEMORY": ["USAGE"],
      "OBJECT": ["ENCODING", "FREQ", "IDLETIME", "REFCOUNT"],
      "XINFO": ["STREAM", "GROUPS", "CONSUMERS"],
    ]

    /// The plugin's rule (ASCII upper-casing is enough for these probes)
    private static func pluginAllows(_ args: [String]) -> Bool {
      let words = args.map { $0.uppercased() }
      let name = words[0]
      if pluginReads.contains(name) { return true }
      if let allowed = pluginSubcommandReads[name] {
        return words.count >= 2 && allowed.contains(words[1])
      }
      switch name {
      case "INFO": return words.count == 2 && ["KEYSPACE", "SERVER"].contains(words[1])
      case "XREAD":
        return words.count > 1 && words[1] == "STREAMS"
          || (words.count > 3 && words[1] == "COUNT" && words[3] == "STREAMS")
      default: return false
      }
    }

    @Test("Every command the classifier calls a read is on the plugin's read-only list")
    func readsAreSubsetOfPluginAllowlist() {
      var probes: [[String]] = []
      let names =
        RedisCommandClassifier.reads.union(RedisCommandClassifier.subcommandReads.keys)
        .union(["INFO", "XREAD", "MEMORY", "OBJECT", "XINFO", "CONFIG", "CLIENT", "SORT"])
      for name in names {
        probes += [[name], [name, "k"], [name, "HELP"], [name, "STATS"]]
      }
      for (name, subcommands) in RedisCommandClassifier.subcommandReads {
        probes += subcommands.map { [name, $0, "k"] }
      }
      probes += [
        ["INFO"], ["INFO", "all"], ["INFO", "keyspace", "server"], ["info", "KeySpace"],
        ["XREAD", "STREAMS", "s", "0"], ["XREAD", "COUNT", "1", "STREAMS", "s", "0"],
        ["XREAD", "COUNT", "1", "COUNT", "2", "STREAMS", "s", "0"],
      ]
      for probe in probes {
        let kind = RedisCommandClassifier.classify(probe.map { Data($0.utf8) }).statement.kind
        if kind == .read {
          #expect(Self.pluginAllows(probe), "\(probe) is a read the plugin refuses")
        }
      }
    }
  }
}
