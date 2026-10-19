// Runs once per fresh volume on mongo-test and mongo-tls-test, as the root user
// from MONGO_INITDB_ROOT_*. Every fixture user lives in admin (authSource=admin),
// so tests can drop dblore_test without losing them. Test-only passwords.
const admin = db.getSiblingDB("admin");

// currentOp({$ownOps: true}) and killOp of its own ops need no extra role;
// clusterMonitor adds read-only serverStatus (metrics.cursor.open). dbAdmin adds collMod
// (hide / unhide an index, validator changes), which readWrite does not grant.
// readWrite + dbAdmin on dblore_test_other: the live tests create and drop that whole
// database (create with its first collection, dropDatabase).
admin.createUser({
  user: "dblore_test",
  pwd: "dblore123",
  roles: [
    { role: "readWrite", db: "dblore_test" },
    { role: "dbAdmin", db: "dblore_test" },
    { role: "readWrite", db: "dblore_test_other" },
    { role: "dbAdmin", db: "dblore_test_other" },
    { role: "clusterMonitor", db: "admin" },
  ],
  mechanisms: ["SCRAM-SHA-256"],
});

admin.createUser({
  user: "dblore_reader",
  pwd: "dblore123",
  roles: [{ role: "read", db: "dblore_test" }],
  mechanisms: ["SCRAM-SHA-256"],
});

admin.createUser({
  user: "dblore_sha1",
  pwd: "dblore123",
  roles: [{ role: "readWrite", db: "dblore_test" }],
  mechanisms: ["SCRAM-SHA-1"],
});
