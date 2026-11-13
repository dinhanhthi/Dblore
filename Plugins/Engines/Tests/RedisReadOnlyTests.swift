// RedisReadOnlyTests.swift
// The read-only allowlist of a Redis connection, without a server: which argument arrays may be
// sent on a read-only connection and how a refusal reads.

import Foundation
import Testing

private func argv(_ words: String...) -> [Data] {
  words.map { Data($0.utf8) }
}

struct RedisReadOnlyTests {
  @Test(
    "Reads, the app's own reads and *_RO commands are allowed, in any case",
    arguments: [
      ["GET", "k"], ["get", "k"], ["HGETALL", "h"], ["SCAN", "0", "MATCH", "a*", "COUNT", "500"],
      ["hScan", "h", "0"], ["INFO", "keyspace"], ["info", "SERVER"], ["MEMORY", "USAGE", "k"],
      ["memory", "usage", "k"], ["OBJECT", "encoding", "k"], ["XINFO", "STREAM", "s"],
      ["EVAL_RO", "return 1", "0"], ["sort_ro", "l"], ["GEORADIUS_RO", "g", "0", "0", "1", "km"],
      ["XREAD", "STREAMS", "s", "0"], ["XREAD", "COUNT", "10", "STREAMS", "s", "0"], ["PING"],
      ["DBSIZE"], ["ZRANGE", "z", "0", "-1", "WITHSCORES"], ["XRANGE", "s", "-", "+"],
    ])
  func allowsReads(_ words: [String]) {
    #expect(RedisReadOnly.refusal(words.map { Data($0.utf8) }) == nil)
  }

  @Test(
    "Writes, writing or blocking variants, state, admin and unknown commands are refused",
    arguments: [
      ["SET", "k", "v"], ["set", "k", "v"], ["DEL", "k"], ["EVAL", "return 1", "0"], ["SORT", "l"],
      ["GEORADIUS", "g", "0", "0", "1", "km"], ["GEOSEARCHSTORE", "d", "g"], ["ZRANGESTORE", "d"],
      ["MEMORY", "PURGE"], ["MEMORY"], ["OBJECT", "HELP"], ["CONFIG", "GET", "*"],
      ["CLIENT", "LIST"], ["SCRIPT", "FLUSH"], ["INFO"], ["INFO", "all"],
      ["INFO", "keyspace", "commandstats"], ["BLPOP", "l", "0"], ["WAIT", "1", "0"],
      ["SUBSCRIBE", "c"], ["XREAD", "BLOCK", "0", "STREAMS", "s", "$"],
      ["XREAD", "COUNT", "1", "BLOCK", "0", "STREAMS", "s", "$"], ["XREADGROUP", "GROUP", "g"],
      ["MULTI"], ["SELECT", "1"], ["RESET"], ["KEYS", "*"], ["DUMP", "k"], ["GETDEL", "k"],
      ["GET ", "k"], ["NOSUCHCOMMAND"],
    ])
  func refusesEverythingElse(_ words: [String]) {
    let failure = RedisReadOnly.refusal(words.map { Data($0.utf8) })
    #expect(failure?.code == .query)
  }

  @Test func refusalNamesOnlyTheCommand() {
    #expect(
      RedisReadOnly.refusal(argv("config", "SET", "requirepass", "hunter2"))?.message
        == "This connection is read-only: CONFIG is not allowed.")
    // A command name that is not a plain ASCII word is never echoed
    let odd = RedisReadOnly.refusal([Data([0x47, 0x45, 0xFF]), Data("k".utf8)])
    #expect(odd?.code == .query)
    #expect(odd?.message == "This connection is read-only: the command is not allowed.")
    // Nor one that does not look like a command name
    #expect(
      RedisReadOnly.refusal(argv("s3cr3t-pa$$"))?.message
        == "This connection is read-only: the command is not allowed.")
  }

  @Test func nonASCIIBytesNeverMatch() {
    // "GET" with a non-UTF-8 byte, and a subcommand with one
    #expect(RedisReadOnly.refusal([Data([0x47, 0x45, 0x54, 0xC0])]) != nil)
    #expect(RedisReadOnly.refusal([Data("MEMORY".utf8), Data([0x55, 0x53, 0xFF])]) != nil)
  }

  @Test func emptyCommandIsInvalid() {
    #expect(RedisReadOnly.refusal([])?.code == .invalid)
    #expect(RedisReadOnly.refusal([Data()]) != nil)
  }
}
