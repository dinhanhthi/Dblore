// SQLDumpDDLTests.swift
// SQLDumpDDL: exact pre-data and post-data statements per engine from fixed structure fixtures
// (serial, bigserial, identity, generated, enum, domain, non-public schema, partitions, views),
// the INSERT column lists, MySQL text kept verbatim with DEFINER removed, and SQLite's
// sqlite_master filtering.

import Foundation
import Testing

@testable import Dblore

@Suite("SQLDumpDDLTests")
struct SQLDumpDDLTests {
  private typealias Column = TableStructure.Column
  private typealias Constraint = TableStructure.Constraint
  private typealias Index = TableStructure.Index
  private typealias Name = SQLDumpDDL.ObjectName

  // MARK: - Fixtures

  private static func column(
    _ ordinal: Int, _ name: String, _ type: String, nullable: Bool = true,
    default defaultExpression: String? = nil
  ) -> Column {
    Column(
      ordinal: ordinal, name: name, dataType: type, isNullable: nullable,
      defaultExpression: defaultExpression, identity: nil, generated: nil, comment: nil,
      columnType: nil, extra: nil, characterSet: nil, collation: nil)
  }

  private static func index(
    _ name: String, _ keys: [Index.Key], unique: Bool = false, primary: Bool = false,
    predicate: String? = nil
  ) -> Index {
    Index(
      name: name, keys: keys, isUnique: unique, isPrimary: primary, method: "btree",
      isPartial: predicate != nil, predicate: predicate)
  }

  private static func structure(
    _ schema: String, _ name: String, _ columns: [Column], indexes: [Index] = [],
    constraints: [Constraint] = [], id: TableRef = .postgresql(oid: 1)
  ) -> TableStructure {
    TableStructure(
      tableID: id, schema: schema, name: name, columns: columns, indexes: indexes,
      constraints: constraints)
  }

  private static func sequence(
    _ schema: String, _ name: String, type: String = "integer", max: Int64 = 2_147_483_647,
    owner: (String, String, String)?, last: Int64?, identity: Bool = false
  ) -> SQLDumpDDL.PostgresSequence {
    SQLDumpDDL.PostgresSequence(
      schema: schema, name: name, dataType: type, start: 1, increment: 1, minValue: 1,
      maxValue: max, cycle: false,
      ownedBy: owner.map {
        SQLDumpDDL.ColumnRef(table: Name(schema: $0.0, name: $0.1), column: $0.2)
      },
      lastValue: last, isIdentity: identity)
  }

  /// app.orders (serial, bigserial, enum, domain, generated), public.events (identity ALWAYS),
  /// public.tags (identity BY DEFAULT, FK to app.orders)
  private static let postgresInput: SQLDumpDDL.PostgresInput = {
    var total = column(6, "total", "numeric")
    total.generated = TableStructure.Generated(expression: "(price * 2)", isStored: true)
    let orders = structure(
      "app", "orders",
      [
        column(
          1, "id", "integer", nullable: false, default: "nextval('app.orders_id_seq'::regclass)"),
        column(
          2, "big", "bigint", nullable: false, default: "nextval('app.orders_big_seq'::regclass)"),
        column(3, "status", "app.mood", nullable: false, default: "'ok'::app.mood"),
        column(4, "qty", "app.positive"),
        column(5, "price", "numeric"),
        total,
      ],
      indexes: [
        index("orders_big_key", [.column("big")], unique: true),
        index(
          "orders_lower_idx", [.expression("lower((status)::text)")], unique: true,
          predicate: "(price > (0)::numeric)"),
        index("orders_pkey", [.column("id")], unique: true, primary: true),
        index("orders_status_idx", [.column("status")]),
      ],
      constraints: [
        Constraint(name: "orders_big_key", kind: .unique, columns: ["big"]),
        Constraint(name: "orders_pkey", kind: .primaryKey, columns: ["id"]),
        Constraint(name: "orders_price_check", kind: .check("(price > (0)::numeric)"), columns: []),
      ])
    var eventID = column(1, "id", "integer", nullable: false)
    eventID.identity = .always
    let events = structure("public", "events", [eventID, column(2, "note", "text")])
    var tagID = column(1, "id", "bigint", nullable: false)
    tagID.identity = .byDefault
    let tags = structure(
      "public", "tags", [tagID, column(2, "order_id", "integer")],
      constraints: [
        Constraint(
          name: "tags_order_id_fkey",
          kind: .foreignKey(
            TableStructure.ForeignKeyReference(
              schema: "app", table: "orders", columns: ["id"], onUpdate: .noAction,
              onDelete: .cascade)),
          columns: ["order_id"])
      ])
    return SQLDumpDDL.PostgresInput(
      tables: [
        SQLDumpDDL.PostgresTable(
          structure: orders,
          indexDefinitions: [
            "orders_status_idx":
              "CREATE INDEX orders_status_idx ON app.orders USING btree (status DESC)"
          ]),
        SQLDumpDDL.PostgresTable(structure: events),
        SQLDumpDDL.PostgresTable(structure: tags),
      ],
      sequences: [
        sequence("app", "orders_id_seq", owner: ("app", "orders", "id"), last: 42),
        sequence(
          "app", "orders_big_seq", type: "bigint", max: Int64.max,
          owner: ("app", "orders", "big"), last: nil),
        sequence(
          "public", "events_id_seq", owner: ("public", "events", "id"), last: 7, identity: true),
      ],
      enums: [SQLDumpDDL.PostgresEnum(schema: "app", name: "mood", labels: ["ok", "it's bad"])],
      domains: [
        SQLDumpDDL.PostgresDomain(
          schema: "app", name: "positive", baseType: "integer", defaultExpression: "1",
          notNull: true,
          constraints: [
            SQLDumpDDL.DomainConstraint(name: "positive_check", definition: "CHECK ((VALUE > 0))")
          ])
      ],
      views: [])
  }()

  // MARK: - PostgreSQL

  @Test func postgresPreDataCreatesSchemasTypesSequencesThenTables() throws {
    let script = try SQLDumpDDL.postgres(Self.postgresInput)
    #expect(
      script.preData == [
        "CREATE SCHEMA IF NOT EXISTS \"app\";",
        "CREATE TYPE \"app\".\"mood\" AS ENUM ('ok', 'it''s bad');",
        "CREATE DOMAIN \"app\".\"positive\" AS integer DEFAULT 1 NOT NULL"
          + " CONSTRAINT \"positive_check\" CHECK ((VALUE > 0));",
        "CREATE SEQUENCE \"app\".\"orders_id_seq\" AS integer START WITH 1 INCREMENT BY 1"
          + " MINVALUE 1 MAXVALUE 2147483647 NO CYCLE;",
        "CREATE SEQUENCE \"app\".\"orders_big_seq\" AS bigint START WITH 1 INCREMENT BY 1"
          + " MINVALUE 1 MAXVALUE 9223372036854775807 NO CYCLE;",
        """
        CREATE TABLE "app"."orders" (
          "id" integer DEFAULT nextval('app.orders_id_seq'::regclass) NOT NULL,
          "big" bigint DEFAULT nextval('app.orders_big_seq'::regclass) NOT NULL,
          "status" app.mood DEFAULT 'ok'::app.mood NOT NULL,
          "qty" app.positive,
          "price" numeric,
          "total" numeric GENERATED ALWAYS AS ((price * 2)) STORED,
          CONSTRAINT "orders_big_key" UNIQUE ("big"),
          CONSTRAINT "orders_pkey" PRIMARY KEY ("id"),
          CONSTRAINT "orders_price_check" CHECK ((price > (0)::numeric))
        );
        """,
        """
        CREATE TABLE "public"."events" (
          "id" integer GENERATED ALWAYS AS IDENTITY (SEQUENCE NAME "public"."events_id_seq" \
        START WITH 1 INCREMENT BY 1 MINVALUE 1 MAXVALUE 2147483647 NO CYCLE) NOT NULL,
          "note" text
        );
        """,
        """
        CREATE TABLE "public"."tags" (
          "id" bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL,
          "order_id" integer
        );
        """,
      ])
  }

  @Test func postgresPostDataIndexesForeignKeysOwnershipAndSetval() throws {
    let script = try SQLDumpDDL.postgres(Self.postgresInput)
    #expect(
      script.postData == [
        "CREATE UNIQUE INDEX \"orders_lower_idx\" ON \"app\".\"orders\" USING btree"
          + " ((lower((status)::text))) WHERE (price > (0)::numeric);",
        "CREATE INDEX orders_status_idx ON app.orders USING btree (status DESC);",
        "ALTER TABLE \"public\".\"tags\" ADD CONSTRAINT \"tags_order_id_fkey\" FOREIGN KEY"
          + " (\"order_id\") REFERENCES \"app\".\"orders\" (\"id\") ON DELETE CASCADE;",
        "ALTER SEQUENCE \"app\".\"orders_id_seq\" OWNED BY \"app\".\"orders\".\"id\";",
        "ALTER SEQUENCE \"app\".\"orders_big_seq\" OWNED BY \"app\".\"orders\".\"big\";",
        "SELECT pg_catalog.setval('\"app\".\"orders_id_seq\"', 42, true);",
        "SELECT pg_catalog.setval('\"public\".\"events_id_seq\"', 7, true);",
      ])
  }

  @Test func postgresInsertListsSkipGeneratedAndFlagIdentityAlways() throws {
    let tables = try SQLDumpDDL.postgres(Self.postgresInput).tables
    #expect(
      tables.map(\.target) == [
        "\"app\".\"orders\"", "\"public\".\"events\"", "\"public\".\"tags\"",
      ])
    #expect(
      tables.map { $0.columns.map(\.name) } == [
        ["id", "big", "status", "qty", "price"], ["id", "note"], ["id", "order_id"],
      ])
    #expect(tables.map(\.overridingSystemValue) == [false, true, false])
    #expect(tables.allSatisfy { $0.hasData })
  }

  @Test func postgresCommentListsObjectsOutOfScope() throws {
    let comment = try SQLDumpDDL.postgres(Self.postgresInput).comment.joined(separator: "\n")
    #expect(comment.hasPrefix("-- "))
    for word in ["functions", "procedures", "extensions", "roles", "ownership", "grants"] {
      #expect(comment.contains(word))
    }
  }

  @Test func postgresPartitionChildSkipsInheritedConstraintsAndIndexes() throws {
    let parent = Self.structure(
      "public", "measurements",
      [
        Self.column(1, "id", "integer", nullable: false),
        Self.column(2, "logdate", "date", nullable: false),
      ],
      indexes: [
        Self.index("measurements_logdate_idx", [.column("logdate")]),
        Self.index(
          "measurements_pkey", [.column("id"), .column("logdate")], unique: true, primary: true),
      ],
      constraints: [
        Constraint(name: "measurements_id_check", kind: .check("(id > 0)"), columns: ["id"]),
        Constraint(name: "measurements_pkey", kind: .primaryKey, columns: ["id", "logdate"]),
      ])
    let child = Self.structure(
      "public", "measurements_2024",
      [
        Self.column(1, "id", "integer", nullable: false),
        Self.column(2, "logdate", "date", nullable: false),
      ],
      indexes: [
        Self.index("measurements_2024_logdate_idx", [.column("logdate")]),
        Self.index(
          "measurements_2024_pkey", [.column("id"), .column("logdate")], unique: true, primary: true
        ),
        Self.index("measurements_2024_id_idx", [.column("id")]),
      ],
      constraints: [
        Constraint(name: "measurements_id_check", kind: .check("(id > 0)"), columns: ["id"])
      ])
    let input = SQLDumpDDL.PostgresInput(
      tables: [
        SQLDumpDDL.PostgresTable(
          structure: child,
          partitionOf: SQLDumpDDL.Partition(
            parent: Name(schema: "public", name: "measurements"),
            bound: "FOR VALUES FROM ('2024-01-01') TO ('2025-01-01')"),
          inheritedConstraintNames: ["measurements_id_check"],
          inheritedIndexNames: ["measurements_2024_logdate_idx", "measurements_2024_pkey"]),
        SQLDumpDDL.PostgresTable(
          structure: parent, partitionKey: "RANGE (logdate)",
          indexDefinitions: [
            "measurements_logdate_idx":
              "CREATE INDEX measurements_logdate_idx ON ONLY public.measurements USING btree (logdate)"
          ]),
      ],
      sequences: [], enums: [], domains: [], views: [])
    let script = try SQLDumpDDL.postgres(input)
    #expect(
      script.preData == [
        """
        CREATE TABLE "public"."measurements" (
          "id" integer NOT NULL,
          "logdate" date NOT NULL,
          CONSTRAINT "measurements_id_check" CHECK ((id > 0)),
          CONSTRAINT "measurements_pkey" PRIMARY KEY ("id", "logdate")
        ) PARTITION BY RANGE (logdate);
        """,
        "CREATE TABLE \"public\".\"measurements_2024\" PARTITION OF \"public\".\"measurements\""
          + " FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');",
      ])
    #expect(
      script.postData == [
        "CREATE INDEX measurements_logdate_idx ON public.measurements USING btree (logdate);",
        "CREATE INDEX \"measurements_2024_id_idx\" ON \"public\".\"measurements_2024\" USING btree"
          + " (\"id\");",
      ])
    #expect(script.tables.map(\.name) == ["measurements", "measurements_2024"])
    #expect(script.tables.map(\.hasData) == [false, true])
  }

  @Test func viewsFollowDependenciesThenNameOrder() throws {
    let views = [
      SQLDumpDDL.View(
        schema: "public", name: "a_summary", sql: " SELECT count(*) AS count\n   FROM z_base;",
        dependsOn: [Name(schema: "public", name: "z_base")]),
      SQLDumpDDL.View(
        schema: "public", name: "z_base", sql: " SELECT id\n   FROM t;",
        dependsOn: [Name(schema: "public", name: "t")]),
      SQLDumpDDL.View(schema: "public", name: "c_other", sql: " SELECT 1;", dependsOn: []),
    ]
    let ordered = try SQLDumpDDL.postgres(
      SQLDumpDDL.PostgresInput(tables: [], sequences: [], enums: [], domains: [], views: views))
    #expect(
      ordered.postData == [
        "CREATE VIEW \"public\".\"c_other\" AS\nSELECT 1;",
        "CREATE VIEW \"public\".\"z_base\" AS\nSELECT id\n   FROM t;",
        "CREATE VIEW \"public\".\"a_summary\" AS\nSELECT count(*) AS count\n   FROM z_base;",
      ])
    // Without dependency information the views fall back to name order
    let unknown = views.map { view -> SQLDumpDDL.View in
      var copy = view
      copy.dependsOn = []
      return copy
    }
    let fallback = try SQLDumpDDL.postgres(
      SQLDumpDDL.PostgresInput(tables: [], sequences: [], enums: [], domains: [], views: unknown))
    #expect(
      fallback.postData.map { $0.components(separatedBy: " AS\n")[0] } == [
        "CREATE VIEW \"public\".\"a_summary\"", "CREATE VIEW \"public\".\"c_other\"",
        "CREATE VIEW \"public\".\"z_base\"",
      ])
  }

  // MARK: - MySQL

  @Test func mysqlKeepsShowCreateTableTextAndRemovesViewDefiner() throws {
    let createOrders = """
      CREATE TABLE `orders` (
        `id` int NOT NULL AUTO_INCREMENT,
        `secret` varchar(10) DEFAULT NULL /*!80023 INVISIBLE */,
        `total` int GENERATED ALWAYS AS ((`id` * 2)) STORED,
        PRIMARY KEY (`id`)
      ) ENGINE=InnoDB AUTO_INCREMENT=5 DEFAULT CHARSET=utf8mb4
      /*!50100 PARTITION BY RANGE (`id`)
      (PARTITION p0 VALUES LESS THAN (100) ENGINE = InnoDB) */
      """
    var id = Self.column(1, "id", "int", nullable: false)
    id.identity = .autoIncrement
    var total = Self.column(3, "total", "int")
    total.generated = TableStructure.Generated(expression: "(`id` * 2)", isStored: true)
    let orders = Self.structure(
      "shop", "orders", [id, Self.column(2, "secret", "varchar"), total],
      id: .mysql(database: "shop", table: "orders"))
    let views = [
      SQLDumpDDL.View(
        schema: "shop", name: "a_top",
        sql: "CREATE ALGORITHM=UNDEFINED DEFINER=`we``ird`@`local host` SQL SECURITY DEFINER"
          + " VIEW `a_top` AS select `z_all`.`id` AS `id` from `z_all`",
        dependsOn: [Name(schema: "shop", name: "z_all")]),
      SQLDumpDDL.View(
        schema: "shop", name: "z_all",
        sql: "CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`%` SQL SECURITY DEFINER VIEW `z_all` AS"
          + " select `orders`.`id` AS `id`,'DEFINER=`x`@`y`' AS `t` from `orders`",
        dependsOn: [Name(schema: "shop", name: "orders")]),
    ]
    let script = try SQLDumpDDL.mysql(
      SQLDumpDDL.MySQLInput(
        tables: [SQLDumpDDL.MySQLTable(structure: orders, createStatement: createOrders)],
        views: views))
    #expect(script.preData == [createOrders + ";"])
    #expect(
      script.postData == [
        "CREATE ALGORITHM=UNDEFINED SQL SECURITY DEFINER VIEW `z_all` AS select `orders`.`id` AS"
          + " `id`,'DEFINER=`x`@`y`' AS `t` from `orders`;",
        "CREATE ALGORITHM=UNDEFINED SQL SECURITY DEFINER VIEW `a_top` AS select `z_all`.`id` AS"
          + " `id` from `z_all`;",
      ])
    #expect(script.tables.map(\.target) == ["`orders`"])
    #expect(script.tables.map { $0.columns.map(\.name) } == [["id", "secret"]])
    #expect(script.tables.map(\.overridingSystemValue) == [false])
  }

  @Test func mysqlDefinerRemovalHandlesQuotedAndBareUsers() {
    #expect(
      SQLDumpDDL.removingDefiner("CREATE DEFINER='app'@'10.0.0.%' VIEW `v` AS select 1")
        == "CREATE VIEW `v` AS select 1")
    #expect(
      SQLDumpDDL.removingDefiner("CREATE DEFINER=CURRENT_USER VIEW `v` AS select 1")
        == "CREATE VIEW `v` AS select 1")
    #expect(
      SQLDumpDDL.removingDefiner("CREATE VIEW `v` AS select 'DEFINER=`a`@`b`' AS x")
        == "CREATE VIEW `v` AS select 'DEFINER=`a`@`b`' AS x")
  }

  // MARK: - SQLite

  private static let sqliteRows: [SQLDumpDDL.SQLiteMasterRow] = [
    .init(
      type: "table", name: "users", tableName: "users",
      sql: "CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, email TEXT UNIQUE,"
        + " email_lower TEXT GENERATED ALWAYS AS (lower(email)) VIRTUAL)"),
    .init(type: "index", name: "sqlite_autoindex_users_1", tableName: "users", sql: nil),
    .init(
      type: "table", name: "sqlite_sequence", tableName: "sqlite_sequence",
      sql: "CREATE TABLE sqlite_sequence(name,seq)"),
    .init(
      type: "table", name: "posts", tableName: "posts",
      sql: "CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER REFERENCES users(id))"),
    .init(
      type: "trigger", name: "trg_posts", tableName: "posts",
      sql: "CREATE TRIGGER trg_posts AFTER INSERT ON posts BEGIN SELECT 1; END"),
    .init(
      type: "view", name: "v_posts", tableName: "v_posts",
      sql: "CREATE VIEW v_posts AS SELECT * FROM posts"),
    .init(
      type: "index", name: "idx_posts_user", tableName: "posts",
      sql: "CREATE INDEX idx_posts_user ON posts(user_id)"),
    .init(
      type: "table", name: "sqlite_stat1", tableName: "sqlite_stat1",
      sql: "CREATE TABLE sqlite_stat1(tbl,idx,stat)"),
  ]

  @Test func sqliteDefersForeignKeysSkipsInternalTablesAndPutsIndexesAfterData() throws {
    #expect(SQLDumpDDL.sqliteDumpedTableNames(Self.sqliteRows) == ["users", "posts"])
    var lower = Self.column(3, "email_lower", "TEXT")
    lower.generated = TableStructure.Generated(expression: nil, isStored: false)
    let users = Self.structure(
      "main", "users",
      [Self.column(1, "id", "INTEGER"), Self.column(2, "email", "TEXT"), lower],
      id: .sqlite(schema: "main", table: "users"))
    let posts = Self.structure(
      "main", "posts", [Self.column(1, "id", "INTEGER"), Self.column(2, "user_id", "INTEGER")],
      id: .sqlite(schema: "main", table: "posts"))
    let script = try SQLDumpDDL.sqlite(
      SQLDumpDDL.SQLiteInput(masterRows: Self.sqliteRows, structures: [posts, users]))
    #expect(
      script.preData == [
        "PRAGMA defer_foreign_keys = ON;",
        "CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, email TEXT UNIQUE,"
          + " email_lower TEXT GENERATED ALWAYS AS (lower(email)) VIRTUAL);",
        "CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER REFERENCES users(id));",
      ])
    #expect(
      script.postData == [
        "CREATE INDEX idx_posts_user ON posts(user_id);",
        "CREATE VIEW v_posts AS SELECT * FROM posts;",
        "CREATE TRIGGER trg_posts AFTER INSERT ON posts BEGIN SELECT 1; END;",
      ])
    #expect(script.tables.map(\.target) == ["\"users\"", "\"posts\""])
    #expect(script.tables.map { $0.columns.map(\.name) } == [["id", "email"], ["id", "user_id"]])
  }

  @Test func sqliteRefusesDefinitionsThatAreNotOneStatementOfTheirKind() throws {
    // `sqlite_master.sql` is file data (`writable_schema` can store any text)
    let users = Self.structure(
      "main", "users", [Self.column(1, "id", "INTEGER")],
      id: .sqlite(schema: "main", table: "users"))
    func script(_ row: SQLDumpDDL.SQLiteMasterRow) throws -> SQLDumpDDL.Script {
      let table = SQLDumpDDL.SQLiteMasterRow(
        type: "table", name: "users", tableName: "users", sql: "CREATE TABLE users (id INTEGER)")
      return try SQLDumpDDL.sqlite(
        SQLDumpDDL.SQLiteInput(
          masterRows: row.name == "users" ? [row] : [table, row], structures: [users]))
    }
    let crafted: [SQLDumpDDL.SQLiteMasterRow] = [
      .init(
        type: "table", name: "users", tableName: "users",
        sql: "CREATE TABLE users (id INTEGER); DROP TABLE victim"),
      .init(
        type: "index", name: "i", tableName: "users",
        sql: "CREATE INDEX i ON users (id);\nATTACH DATABASE '/tmp/evil' AS e"),
      // Opens a comment (or string) that a later statement of the dump would close
      .init(type: "view", name: "v", tableName: "v", sql: "CREATE VIEW v AS SELECT 1 /*"),
      .init(type: "view", name: "v", tableName: "v", sql: "CREATE VIEW v AS SELECT 'a"),
      .init(type: "view", name: "v", tableName: "v", sql: "CREATE VIEW v AS SELECT 1 --"),
      // A statement of another kind than its row
      .init(type: "trigger", name: "t", tableName: "users", sql: "DROP TABLE victim"),
      .init(type: "view", name: "v", tableName: "v", sql: "CREATE TABLE v (a)"),
      .init(
        type: "trigger", name: "t", tableName: "users",
        sql: "CREATE TRIGGER t AFTER INSERT ON users BEGIN SELECT 1; END; DELETE FROM users"),
    ]
    for row in crafted {
      #expect(throws: SQLDumpDDLError.unsafeDefinition(row.name), "\(row.sql ?? "")") {
        try script(row)
      }
    }
    // A trigger body holds several statements (and a `;` in a string) between BEGIN and END
    let trigger =
      "CREATE TRIGGER audit AFTER INSERT ON users BEGIN\n"
      + "  INSERT INTO log VALUES ('a;b');\n  UPDATE counts SET n = n + 1;\nEND"
    let kept = try script(
      .init(type: "trigger", name: "audit", tableName: "users", sql: trigger))
    #expect(kept.postData == [trigger + ";"])
    #expect(
      SQLDumpDDLError.unsafeDefinition("v").errorDescription
        == "The definition of \"v\" is not a single CREATE statement of its kind.")
  }

  @Test func sqliteRefusesTableWithoutStructure() {
    #expect(throws: SQLDumpDDLError.missingStructure("users")) {
      try SQLDumpDDL.sqlite(SQLDumpDDL.SQLiteInput(masterRows: Self.sqliteRows, structures: []))
    }
  }

  // MARK: - Fidelity: catalog definitions

  @Test func postgresForeignKeysAndExclusionConstraintsUseCatalogDefinitions() throws {
    let rooms = Self.structure(
      "public", "bookings",
      [
        Self.column(1, "id", "integer", nullable: false),
        Self.column(2, "room", "integer"),
        Self.column(3, "guest_id", "integer"),
      ],
      indexes: [
        Self.index("bookings_room_excl", [.column("room")]),
        Self.index("bookings_pkey", [.column("id")], unique: true, primary: true),
      ],
      constraints: [
        Constraint(name: "bookings_pkey", kind: .primaryKey, columns: ["id"]),
        Constraint(
          name: "bookings_guest_fkey",
          kind: .foreignKey(
            TableStructure.ForeignKeyReference(
              schema: "public", table: "guests", columns: ["id"], onUpdate: .noAction,
              onDelete: .noAction)),
          columns: ["guest_id"]),
        Constraint(
          name: "bookings_plain_fkey",
          kind: .foreignKey(
            TableStructure.ForeignKeyReference(
              schema: "public", table: "guests", columns: ["id"], onUpdate: .noAction,
              onDelete: .noAction)),
          columns: ["room"]),
      ])
    let input = SQLDumpDDL.PostgresInput(
      tables: [
        SQLDumpDDL.PostgresTable(
          structure: rooms,
          foreignKeyDefinitions: [
            "bookings_guest_fkey":
              "FOREIGN KEY (guest_id) REFERENCES public.guests(id) MATCH FULL"
              + " DEFERRABLE INITIALLY DEFERRED NOT VALID"
          ],
          exclusionConstraints: [
            "bookings_room_excl": "EXCLUDE USING btree (room WITH =)"
          ])
      ],
      sequences: [], enums: [], domains: [], views: [])
    let script = try SQLDumpDDL.postgres(input)
    #expect(
      script.postData == [
        "ALTER TABLE \"public\".\"bookings\" ADD CONSTRAINT \"bookings_room_excl\""
          + " EXCLUDE USING btree (room WITH =);",
        "ALTER TABLE \"public\".\"bookings\" ADD CONSTRAINT \"bookings_guest_fkey\""
          + " FOREIGN KEY (guest_id) REFERENCES public.guests(id) MATCH FULL"
          + " DEFERRABLE INITIALLY DEFERRED NOT VALID;",
        "ALTER TABLE \"public\".\"bookings\" ADD CONSTRAINT \"bookings_plain_fkey\" FOREIGN KEY"
          + " (\"room\") REFERENCES \"public\".\"guests\" (\"id\");",
      ])
  }

  @Test func postgresNotValidChecksAreAddedAfterTheData() throws {
    let checks = Self.structure(
      "public", "checks", [Self.column(1, "id", "integer"), Self.column(2, "qty", "public.small")],
      constraints: [
        Constraint(name: "checks_id_check", kind: .check("(id > 0)"), columns: []),
        Constraint(name: "checks_id_small", kind: .check("(id < 3)"), columns: []),
      ])
    let parent = Self.structure(
      "public", "events", [Self.column(1, "id", "integer"), Self.column(2, "logdate", "date")],
      constraints: [Constraint(name: "events_id_big", kind: .check("(id > 5)"), columns: [])])
    let partition = Self.structure(
      "public", "events_2026",
      [Self.column(1, "id", "integer"), Self.column(2, "logdate", "date")],
      constraints: [
        Constraint(name: "events_id_big", kind: .check("(id > 5)"), columns: []),
        Constraint(name: "events_2026_local", kind: .check("(id > 1)"), columns: []),
      ])
    let input = SQLDumpDDL.PostgresInput(
      tables: [
        SQLDumpDDL.PostgresTable(
          structure: checks,
          notValidCheckDefinitions: ["checks_id_small": "CHECK ((id < 3)) NOT VALID"]),
        SQLDumpDDL.PostgresTable(
          structure: parent, partitionKey: "RANGE (logdate)",
          notValidCheckDefinitions: ["events_id_big": "CHECK ((id > 5)) NOT VALID"]),
        SQLDumpDDL.PostgresTable(
          structure: partition,
          partitionOf: SQLDumpDDL.Partition(
            parent: Name(schema: "public", name: "events"),
            bound: "FOR VALUES FROM ('2026-01-01') TO ('2027-01-01')"),
          inheritedConstraintNames: ["events_id_big"],
          notValidCheckDefinitions: [
            "events_id_big": "CHECK ((id > 5)) NOT VALID",
            "events_2026_local": "CHECK ((id > 1)) NOT VALID",
          ]),
      ],
      sequences: [], enums: [],
      domains: [
        SQLDumpDDL.PostgresDomain(
          schema: "public", name: "small", baseType: "integer", defaultExpression: nil,
          notNull: false,
          constraints: [
            SQLDumpDDL.DomainConstraint(name: "small_check", definition: "CHECK ((VALUE > 0))"),
            SQLDumpDDL.DomainConstraint(
              name: "small_max", definition: "CHECK ((VALUE < 3)) NOT VALID", notValid: true),
          ])
      ], views: [])
    let script = try SQLDumpDDL.postgres(input)
    #expect(
      script.preData == [
        "CREATE DOMAIN \"public\".\"small\" AS integer CONSTRAINT \"small_check\""
          + " CHECK ((VALUE > 0));",
        "CREATE TABLE \"public\".\"checks\" (\n  \"id\" integer,\n  \"qty\" public.small,\n"
          + "  CONSTRAINT \"checks_id_check\" CHECK ((id > 0))\n);",
        "CREATE TABLE \"public\".\"events\" (\n  \"id\" integer,\n  \"logdate\" date\n)"
          + " PARTITION BY RANGE (logdate);",
        "CREATE TABLE \"public\".\"events_2026\" PARTITION OF \"public\".\"events\""
          + " FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');",
      ])
    #expect(
      script.postData == [
        "ALTER DOMAIN \"public\".\"small\" ADD CONSTRAINT \"small_max\""
          + " CHECK ((VALUE < 3)) NOT VALID;",
        "ALTER TABLE \"public\".\"checks\" ADD CONSTRAINT \"checks_id_small\""
          + " CHECK ((id < 3)) NOT VALID;",
        "ALTER TABLE \"public\".\"events\" ADD CONSTRAINT \"events_id_big\""
          + " CHECK ((id > 5)) NOT VALID;",
        "ALTER TABLE \"public\".\"events_2026\" ADD CONSTRAINT \"events_2026_local\""
          + " CHECK ((id > 1)) NOT VALID;",
      ])
  }

  // MARK: - Fidelity: SQLite virtual tables and AUTOINCREMENT

  private static let virtualRows: [SQLDumpDDL.SQLiteMasterRow] = [
    .init(
      type: "table", name: "notes", tableName: "notes",
      sql: "CREATE TABLE notes (id INTEGER PRIMARY KEY AUTOINCREMENT, body TEXT)"),
    .init(
      type: "table", name: "sqlite_sequence", tableName: "sqlite_sequence",
      sql: "CREATE TABLE sqlite_sequence(name,seq)"),
    .init(
      type: "table", name: "notes_fts", tableName: "notes_fts",
      sql: "CREATE VIRTUAL TABLE notes_fts USING fts5(body)"),
    .init(
      type: "table", name: "notes_fts_data", tableName: "notes_fts_data",
      sql: "CREATE TABLE 'notes_fts_data'(id INTEGER PRIMARY KEY, block BLOB)"),
    .init(
      type: "table", name: "notes_fts_config", tableName: "notes_fts_config",
      sql: "CREATE TABLE 'notes_fts_config'(k PRIMARY KEY, v) WITHOUT ROWID"),
    .init(
      type: "table", name: "notes_fts_archive", tableName: "notes_fts_archive",
      sql: "CREATE TABLE notes_fts_archive (id INTEGER)"),
    .init(
      type: "index", name: "idx_notes_body", tableName: "notes",
      sql: "CREATE INDEX idx_notes_body ON notes(body)"),
  ]

  private static let notesStructure = structure(
    "main", "notes", [column(1, "id", "INTEGER"), column(2, "body", "TEXT")],
    id: .sqlite(schema: "main", table: "notes"))

  @Test func sqliteVirtualTableKeepsCreateOnlyAndShadowTablesAreSkipped() throws {
    let shadow: Set<String> = ["notes_fts_data", "notes_fts_config"]
    #expect(
      SQLDumpDDL.sqliteDumpedTableNames(Self.virtualRows, shadowTableNames: shadow)
        == ["notes", "notes_fts_archive"])
    let archive = Self.structure(
      "main", "notes_fts_archive", [Self.column(1, "id", "INTEGER")],
      id: .sqlite(schema: "main", table: "notes_fts_archive"))
    let script = try SQLDumpDDL.sqlite(
      SQLDumpDDL.SQLiteInput(
        masterRows: Self.virtualRows, structures: [Self.notesStructure, archive],
        shadowTableNames: shadow))
    #expect(
      script.preData == [
        "PRAGMA defer_foreign_keys = ON;",
        "CREATE TABLE notes (id INTEGER PRIMARY KEY AUTOINCREMENT, body TEXT);",
        "CREATE VIRTUAL TABLE notes_fts USING fts5(body);",
        "CREATE TABLE notes_fts_archive (id INTEGER);",
      ])
    #expect(script.tables.map(\.name) == ["notes", "notes_fts", "notes_fts_archive"])
    #expect(script.tables.map(\.hasData) == [true, false, true])
    #expect(script.comment.joined().contains("\"notes_fts\""))
  }

  @Test func sqliteShadowTablesFallBackToTheVirtualTableNamePrefix() throws {
    // Without PRAGMA table_list every `<virtual table>_` table is treated as a shadow table
    #expect(SQLDumpDDL.sqliteDumpedTableNames(Self.virtualRows) == ["notes"])
    let script = try SQLDumpDDL.sqlite(
      SQLDumpDDL.SQLiteInput(masterRows: Self.virtualRows, structures: [Self.notesStructure]))
    #expect(script.tables.map(\.name) == ["notes", "notes_fts"])
  }

  @Test func sqliteRestoresAutoincrementCountersAfterData() throws {
    let script = try SQLDumpDDL.sqlite(
      SQLDumpDDL.SQLiteInput(
        masterRows: Self.virtualRows, structures: [Self.notesStructure],
        sequences: [
          SQLDumpDDL.SQLiteSequence(name: "notes", seq: 41),
          SQLDumpDDL.SQLiteSequence(name: "gone", seq: 3),
        ]))
    #expect(
      script.postData == [
        "DELETE FROM sqlite_sequence WHERE name = 'notes';",
        "INSERT INTO sqlite_sequence (name, seq) VALUES ('notes', 41);",
        "CREATE INDEX idx_notes_body ON notes(body);",
      ])
  }
}
