// AISlashCommandTests.swift
// Slash commands of the AI composer: parsing, validation and limits, local expansion, what each
// connection offers, the saved list, and the draft fill through the gate

import AppKit
import Foundation
import Testing

@testable import Dblore

nonisolated private final class FakeSlashClient: AIChatClient, @unchecked Sendable {
  func stream(_ request: AIChatRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
    AsyncThrowingStream { continuation in
      continuation.yield(.text("ok"))
      continuation.finish()
    }
  }

  func listModels() async throws -> [String] { [] }
}

@Suite("AI slash commands")
@MainActor
struct AISlashCommandTests {
  private typealias Command = AISlashCommand
  private static let sql = "SELECT id FROM orders"

  private func command(_ name: String, _ template: String = "Do it") -> AICustomCommand {
    AICustomCommand(name: name, template: template)
  }

  // MARK: - Parsing

  @Test("a draft starting with /name parses into the name and the text after it")
  func parsesCommand() {
    #expect(Command.parse("/explain") == .init(name: "explain", argument: ""))
    #expect(
      Command.parse("  /my-cmd2  focus on joins ")
        == .init(name: "my-cmd2", argument: "focus on joins"))
    #expect(Command.parse("/fix\nwhy this") == .init(name: "fix", argument: "why this"))
  }

  @Test("other drafts are no commands")
  func rejectsNonCommands() {
    for draft in [
      "explain", "/", "//x", "/ x", "/usr/bin", "/Explain", "/a_b", "ask /explain",
      "/" + String(repeating: "a", count: 33),
    ] {
      #expect(Command.parse(draft) == nil, "\(draft)")
    }
  }

  // MARK: - Validation and limits

  @Test("names are 1 to 32 of a-z, 0-9 and hyphen")
  func nameRule() {
    #expect(Command.isValidName("a"))
    #expect(Command.isValidName("sum-by-day-2"))
    #expect(Command.isValidName(String(repeating: "x", count: 32)))
    #expect(!Command.isValidName(""))
    #expect(!Command.isValidName(String(repeating: "x", count: 33)))
    #expect(!Command.isValidName("Upper"))
    #expect(!Command.isValidName("with space"))
    #expect(!Command.isValidName("é"))
  }

  @Test("built-in names, duplicates and empty templates are refused; editing keeps the name")
  func validation() {
    let saved = command("daily")
    #expect(Command.validate(command("explain"), among: []) == .reservedName)
    #expect(Command.validate(command("Bad"), among: []) == .invalidName)
    #expect(Command.validate(command("daily"), among: [saved]) == .duplicateName)
    #expect(Command.validate(command("new", " \n"), among: []) == .emptyTemplate)
    var edited = saved
    edited.template = "Changed"
    #expect(Command.validate(edited, among: [saved]) == nil)
  }

  @Test("a template holds at most 4,000 characters")
  func templateCap() {
    let atCap = command("a", String(repeating: "t", count: 4_000))
    let over = command("a", String(repeating: "t", count: 4_001))
    #expect(Command.validate(atCap, among: []) == nil)
    #expect(Command.validate(over, among: []) == .templateTooLong)
  }

  @Test("at most 50 commands: a 51st is refused, editing one of 50 is not")
  func commandCap() {
    let fifty = (0..<50).map { command("c\($0)") }
    #expect(Command.validate(command("extra"), among: fifty) == .tooManyCommands)
    var edited = fifty[3]
    edited.template = "Changed"
    #expect(Command.validate(edited, among: fifty) == nil)
    #expect(Command.validate(command("extra"), among: Array(fifty.prefix(49))) == nil)
  }

  // MARK: - Expansion

  @Test("known placeholders expand, unknown ones stay literal, nil expands to empty")
  func expansion() {
    let values = Command.Values(query: "SELECT 1", selection: nil, schema: "t(id)", error: "boom")
    let text = Command.expand(
      template: "Q={{query}} S={{selection}} D={{schema}} E={{error}} X={{rows}} {{ query }}",
      values: values)
    #expect(text == "Q=SELECT 1 S= D=t(id) E=boom X={{rows}} {{ query }}")
    #expect(Command.expand(template: "{{{query}}}", values: values) == "{SELECT 1}")
    #expect(Command.expand(template: "{{query}}", values: .init()) == "")
  }

  @Test("a placeholder inside a value is not expanded again")
  func noRecursiveExpansion() {
    let values = Command.Values(query: "x {{schema}} {{error}} y", schema: "SECRET", error: "E")
    #expect(
      Command.expand(template: "{{query}} / {{schema}}", values: values)
        == "x {{schema}} {{error}} y / SECRET")
  }

  @Test("each value and the whole expansion are cut")
  func expansionCaps() {
    let long = String(repeating: "q", count: Command.maxValueChars + 10)
    let one = Command.expand(template: "{{query}}", values: .init(query: long))
    #expect(one == String(long.prefix(Command.maxValueChars)) + "\n" + Command.truncationMarker)

    let all = Command.expand(
      template: "{{query}}{{query}}{{query}}", values: .init(query: long))
    #expect(all.count == Command.maxExpandedChars + 1 + Command.truncationMarker.count)
    #expect(all.hasSuffix(Command.truncationMarker))
  }

  // MARK: - Availability

  @Test("SQL connections list every built-in then custom commands by name")
  func availableOnSQL() {
    let names = Command.available(
      custom: [command("zeta"), command("alpha")], dialect: .postgresql
    ).map(\.name)
    #expect(names == ["explain", "fix", "review", "optimize", "alpha", "zeta"])
  }

  @Test("MongoDB connections offer no /review or /optimize")
  func availableOnMongo() {
    let names = Command.available(custom: [command("alpha")], dialect: .mongodb).map(\.name)
    #expect(names == ["explain", "fix", "alpha"])
  }

  @Test("a built-in name resolves to the built-in")
  func resolve() {
    #expect(Command.resolve("fix", custom: []) == .builtIn(.fix))
    let alpha = command("alpha")
    #expect(Command.resolve("alpha", custom: [alpha]) == .custom(alpha))
    #expect(Command.resolve("nope", custom: []) == nil)
  }

  // MARK: - Saved list

  @Test("a configuration saved before slash commands decodes with none; commands round-trip")
  func configDecode() throws {
    let old = #"{"activeProvider":"ollama","configs":{"ollama":{"baseURL":"u","model":"m"}}}"#
    let legacy = try JSONDecoder().decode(AIConfiguration.self, from: Data(old.utf8))
    #expect(legacy.customCommands.isEmpty)
    #expect(legacy.configs[.ollama]?.model == "m")

    let config = AIConfiguration(
      activeProvider: nil, configs: [:], customCommands: [command("daily", "Sum {{query}}")])
    let data = try JSONEncoder().encode(config)
    #expect(try JSONDecoder().decode(AIConfiguration.self, from: data) == config)
  }

  @Test("the saved list is cut to 50 valid commands; a bad entry or list drops only commands")
  func configSanitized() throws {
    let many = (0..<51).map { command("c\($0)") }
    let config = AIConfiguration(activeProvider: nil, configs: [:], customCommands: many)
    let decoded = try JSONDecoder().decode(
      AIConfiguration.self, from: JSONEncoder().encode(config))
    #expect(decoded.customCommands == Array(many.prefix(50)))

    let id = UUID().uuidString
    let mixed = """
      {"configs":{},"customCommands":[{"id":"\(id)","name":"ok","template":"T"},\
      {"name":"no-id","template":"T"},{"id":"\(UUID().uuidString)","name":"BAD","template":"T"},\
      {"id":"\(UUID().uuidString)","name":"explain","template":"T"},\
      {"id":"\(UUID().uuidString)","name":"ok","template":"dup"},\
      {"id":"\(UUID().uuidString)","name":"long","template":"\(String(repeating: "x", count: 4_001))"}]}
      """
    let kept = try JSONDecoder().decode(AIConfiguration.self, from: Data(mixed.utf8))
    #expect(kept.customCommands.map(\.name) == ["ok"])

    let notArray = #"{"configs":{"ollama":{"baseURL":"u","model":"m"}},"customCommands":7}"#
    let survived = try JSONDecoder().decode(AIConfiguration.self, from: Data(notArray.utf8))
    #expect(survived.customCommands.isEmpty)
    #expect(survived.configs[.ollama]?.model == "m")
  }

  // MARK: - Draft fill

  private func config(
    _ type: DatabaseType = .postgresql, policy: AIAccessPolicy = .always
  )
    -> ConnectionConfig
  {
    var config = ConnectionConfig(
      databaseType: type, host: "db.example", port: 5432, database: "shop", username: "ana",
      name: "Prod")
    config.aiAccess = policy
    return config
  }

  private func makeVM(
    policy: AIAccessPolicy = .always, type: DatabaseType = .postgresql,
    commands: [AICustomCommand] = [], tables: [DatabaseTable] = []
  ) -> AIAssistantViewModel {
    let defaults = UserDefaults(suiteName: "AISlashCommandTests-\(UUID().uuidString)")!
    let settings = AISettings(defaults: defaults, keyStore: InMemoryAIKeyStore())
    settings.configuration = AIConfiguration(
      activeProvider: .ollama,
      configs: [.ollama: AIProviderConfig(baseURL: "http://127.0.0.1:11434/v1", model: "m1")],
      customCommands: commands)
    let vm = AIAssistantViewModel(settings: settings, makeClient: { _, _, _ in FakeSlashClient() })
    vm.schemaSource = {
      AISchemaSnapshot(tables: tables, foreignKeys: [], databaseName: "shop", dialect: type.dialect)
    }
    let access = AIAccessContext(
      config: config(type, policy: policy), savedPolicies: [], gate: AIAccessGate())
    vm.aiAccessSource = { access }
    return vm
  }

  private func editorTab(
    _ text: String = sql, type: DatabaseType = .postgresql, error: String? = nil
  ) -> NotebookViewModel {
    let tab = NotebookViewModel(notebook: DbloreNotebook(connectionConfig: config(type)))
    tab.viewMode = .editor
    tab.editorContent = text
    if let error { tab.editorResult = CellResult(error: error, aiSessionKey: tab.aiSessionKey) }
    return tab
  }

  private static let probe = "Q={{query}} S={{selection}} E={{error}} X={{rows}}"

  @Test("a custom command expands the tab's query and error into the draft")
  func customFillsDraft() {
    let vm = makeVM(commands: [command("probe", Self.probe)])
    vm.draft = "/probe also this"
    #expect(vm.runSlashCommand(in: editorTab(error: "boom")) == .filled(withheld: false))
    #expect(vm.draft == "Q=\(Self.sql) S= E=boom X={{rows}}\n\nalso this")
  }

  @Test("{{selection}} is the editor selection only")
  func selectionValue() {
    let vm = makeVM(commands: [command("sel", "S={{selection}} Q={{query}}")])
    let tab = editorTab("SELECT 1; SELECT 2")
    let textView = SQLTextView(frame: .zero)
    textView.string = "SELECT 1; SELECT 2"
    textView.setSelectedRange(NSRange(location: 10, length: 8))
    tab.editorTextView = textView
    vm.draft = "/sel"
    vm.runSlashCommand(in: tab)
    #expect(vm.draft == "S=SELECT 2 Q=SELECT 2")
  }

  @Test("a read-only source tab gives an empty query and selection")
  func readOnlySourceIsEmpty() {
    let vm = makeVM(commands: [command("probe", Self.probe)])
    let tab = editorTab("CREATE VIEW v AS SELECT secret FROM t")
    tab.objectSourceLoad = .loaded
    vm.draft = "/probe"
    #expect(vm.runSlashCommand(in: tab) == .filled(withheld: false))
    #expect(vm.draft == "Q= S= E= X={{rows}}")
    #expect(!vm.draft.contains("secret"))
  }

  @Test("a connection set to Never gets no values, and the template alone is sent as is")
  func deniedWithholdsValues() {
    let vm = makeVM(policy: .never, commands: [command("probe", Self.probe)])
    vm.draft = "/probe"
    #expect(vm.runSlashCommand(in: editorTab(error: "boom")) == .filled(withheld: true))
    #expect(vm.draft == "Q= S= E= X={{rows}}")
    // No connection text in the draft: it is not held
    vm.send()
    #expect(vm.privateNote == .messageOnly)
    #expect(vm.messages.first?.text == "Q= S= E= X={{rows}}")
    vm.stop()
  }

  @Test("a connection not yet allowed this session asks first and reads no values")
  func needsApprovalWithholdsValues() {
    let vm = makeVM(policy: .askOncePerSession, commands: [command("probe", Self.probe)])
    vm.draft = "/probe"
    #expect(vm.runSlashCommand(in: editorTab(error: "boom")) == .awaitingApproval)
    #expect(vm.pendingApproval?.connectionName == "Prod")
    #expect(vm.draft == "/probe")
    vm.dismissPendingTurn()
    #expect(vm.draft == "/probe")

    // A template without placeholders reads nothing, so it does not ask
    let plain = makeVM(policy: .askOncePerSession, commands: [command("hi", "Say hi")])
    plain.draft = "/hi"
    #expect(plain.runSlashCommand(in: editorTab()) == .filled(withheld: false))
    #expect(plain.pendingApproval == nil)
    #expect(plain.draft == "Say hi")
  }

  @Test("a draft holding expanded query text is held at send once the connection is Never")
  func expandedDraftIsConnectionText() {
    var policy = AIAccessPolicy.always
    let vm = makeVM(commands: [command("q", "Explain {{query}}")])
    let base = config()
    vm.aiAccessSource = {
      var live = base
      live.aiAccess = policy
      return AIAccessContext(config: live, savedPolicies: [], gate: AIAccessGate())
    }
    vm.draft = "/q"
    vm.runSlashCommand(in: editorTab())
    #expect(vm.draft == "Explain \(Self.sql)")
    policy = .never
    vm.send()
    #expect(vm.privateNote == .draftHeld)
    #expect(vm.messages.isEmpty)
  }

  @Test("on MongoDB {{query}} is the mongosh text and {{schema}} the sampled fields")
  func mongoValues() {
    let orders = DatabaseTable(
      schema: "shop", name: "orders",
      columns: [
        DatabaseColumn(name: "_id", type: "objectId"),
        DatabaseColumn(name: "total", type: "double"),
      ])
    let vm = makeVM(
      type: .mongodb, commands: [command("m", "{{query}}\n{{schema}}")], tables: [orders])
    let mongosh = "db.orders.find({ total: { $gt: 100 } })"
    vm.draft = "/m"
    vm.runSlashCommand(in: editorTab(mongosh, type: .mongodb))
    #expect(vm.draft.hasPrefix(mongosh + "\n"))
    #expect(vm.draft.contains("shop.orders(_id objectId, total double)"))
  }

  @Test("/explain and /fix fill the draft like the quick actions; text after them is kept")
  func explainAndFix() {
    let vm = makeVM()
    vm.draft = "/explain focus on the join"
    #expect(vm.runSlashCommand(in: editorTab()) == .filled(withheld: false))
    #expect(vm.draft == AIPrompts.explain(sql: Self.sql) + "\n\nfocus on the join")

    vm.draft = "/fix"
    #expect(vm.runSlashCommand(in: editorTab(error: "boom")) == .filled(withheld: false))
    #expect(vm.draft == AIPrompts.fixError(sql: Self.sql, error: "boom"))
  }

  @Test("/fix without an error and /explain without SQL change nothing")
  func builtInsUnavailable() {
    let vm = makeVM()
    vm.draft = "/fix"
    #expect(vm.runSlashCommand(in: editorTab()) == .unavailable(.fix))
    #expect(vm.draft == "/fix")
    vm.draft = "/explain"
    #expect(vm.runSlashCommand(in: editorTab("  ")) == .unavailable(.explain))
    #expect(vm.runSlashCommand(in: nil) == .unavailable(.explain))
  }

  @Test("/review fills a review request on SQL and is unavailable on MongoDB")
  func reviewByDialect() {
    let vm = makeVM()
    let tab = editorTab()
    vm.draft = "/review"
    #expect(vm.runSlashCommand(in: tab) == .filled(withheld: false))
    #expect(vm.draft == AIPrompts.review(sql: Self.sql))
    #expect(vm.pendingReview?.request.kind == .review)

    let mongo = makeVM(type: .mongodb)
    mongo.draft = "/optimize"
    #expect(
      mongo.runSlashCommand(in: editorTab("db.orders.find({})", type: .mongodb))
        == .unavailable(.optimize))
  }

  @Test("an unknown name or plain text changes nothing")
  func unknownAndPlain() {
    let vm = makeVM()
    vm.draft = "/nope"
    #expect(vm.runSlashCommand(in: editorTab()) == .unknown("nope"))
    #expect(vm.draft == "/nope")
    vm.draft = "just a question"
    #expect(vm.runSlashCommand(in: editorTab()) == .notACommand)
  }
}
