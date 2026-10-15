# Dblore Docker Databases

Docker configurations for local development and testing databases.

## 📁 Structure

```
docker/
├── README.md              # This file - complete guide
├── postgresql/            # PostgreSQL setup
│   ├── docker-compose.yml
│   ├── docker-compose.ssh.yml  # SSH test stack (sshd + PostgreSQL, MySQL, MongoDB)
│   ├── .env.example
│   ├── init/             # Schema and sample data (runs on first setup)
│   ├── scripts/          # Helper scripts
│   ├── migrations/       # Incremental schema changes
│   └── backups/          # Database backups (created by backup script)
├── mysql/                # MySQL 8.4 (3307) + MariaDB 11.4 (3308) test servers
│   ├── docker-compose.test.yml
│   ├── init/             # Test users and grants (runs on first start)
│   └── scripts/          # gen-mysql-tls.sh (TLS/mTLS test certificates)
├── mongodb/              # MongoDB 8.0 test servers (27018, TLS-only 27019)
│   ├── docker-compose.test.yml
│   ├── init/             # Test users (runs on first start)
│   └── scripts/          # gen-mongo-tls.sh (TLS test certificates)
└── sqlite/               # Coming soon
```

---

## 🐘 PostgreSQL

### 🚀 First Time Setup (New Machine)

```bash
cd docker/postgresql
cp .env.example .env
docker compose up -d
```

**Connect from Dblore:**
```
Host: localhost
Port: 5433
Database: dblore
User: dblore
Password: dblore123
```

Or connection string: `postgresql://dblore:dblore123@localhost:5433/dblore`

> Port 5433 avoids conflict with local Postgres.app (5432)

---

### 💾 Backup Database (Before Moving to New Machine)

```bash
cd docker/postgresql
./scripts/backup-db.sh
```

Backup file saved in `backups/backup_YYYY-MM-DD_HH-MM-SS.sql`

**Copy the `backups/` folder to your new machine.**

---

### 🔄 Restore Database (On New Machine)

**Option 1: Using Restore Script (Recommended)**

```bash
# 1. Setup fresh database first
cd docker/postgresql
cp .env.example .env
docker compose up -d

# 2. Restore from backup using script
./scripts/restore-db.sh backups/dblore_backup_YYYY-MM-DD_HH-MM-SS.sql
```

The script will:
- Show backup file size and confirm before proceeding
- Automatically drop existing schema to avoid conflicts
- Restore all data from backup
- Verify restored data counts

**Option 2: Manual Restore**

```bash
# 1. Setup fresh database first
cd docker/postgresql
cp .env.example .env
docker compose up -d

# 2. Drop existing schema (to avoid conflicts with init scripts)
docker compose exec -T postgres psql -U dblore -d dblore -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"

# 3. Restore from backup
docker compose exec -T postgres psql -U dblore -d dblore < backups/dblore_backup_YYYY-MM-DD_HH-MM-SS.sql
```

> ⚠️ **Important**: When restoring to a fresh container, you must drop the existing schema first because init scripts automatically create tables when the container starts. This prevents duplicate key errors during restore.

---

### ➕ Add New Table

**Option 1: Fresh Reset (Recommended for development)**

```bash
# 1. Edit schema
nano docker/postgresql/init/01-schema.sql
# Add: CREATE TABLE my_table (...);

# 2. Edit sample data
nano docker/postgresql/init/02-sample-data.sql
# Add: INSERT INTO my_table (...) VALUES (...);

# 3. Reset database
cd docker/postgresql
./scripts/reset-db.sh
```

**Option 2: Migration (Preserve existing data)**

```bash
# 1. Create migration file
cat > docker/postgresql/migrations/001-my-table.sql << 'EOF'
CREATE TABLE IF NOT EXISTS my_table (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100)
);
EOF

# 2. Apply migration
cd docker/postgresql
./scripts/add-data.sh migrations/001-my-table.sql

# 3. (Optional) Copy to init scripts for next reset
# Add the SQL to init/01-schema.sql
```

---

### 📝 Add More Data (Without Changing Schema)

**Option 1: Use Dblore App** (Easiest)
- Connect and run INSERT statements in a cell

**Option 2: SQL File**

```bash
# Create SQL file
cat > docker/postgresql/my-data.sql << 'EOF'
INSERT INTO customers (first_name, last_name, email) VALUES
('John', 'Doe', 'john@example.com');
EOF

# Apply it
cd docker/postgresql
./scripts/add-data.sh my-data.sql
```

**Option 3: Interactive Shell**

```bash
cd docker/postgresql
./scripts/psql.sh
# Type SQL and press Enter
# \q to quit
```

---

### 🔧 Common Commands

```bash
cd docker/postgresql

# Start/Stop
docker compose up -d          # Start
docker compose stop           # Stop (keep data)
docker compose down           # Stop and remove containers (keep data in volume)

# Database Operations
./scripts/backup-db.sh                      # Backup database
./scripts/restore-db.sh backups/file.sql    # Restore from backup
./scripts/reset-db.sh                       # Reset to init scripts (deletes all data!)
./scripts/psql.sh                           # Open interactive shell
./scripts/add-data.sh file.sql              # Apply SQL file

# Debugging
docker compose ps             # Check status
docker compose logs -f        # View logs
```

---

### 📊 Sample Data Included

| Table | Records | Description |
|-------|---------|-------------|
| `customers` | 30 | Customer records with JSONB metadata (4 tiers: platinum, gold, silver, bronze) |
| `products` | 40 | Product catalog across 3 categories (Electronics, Accessories, Furniture) |
| `orders` | 50 | Order tracking with 4 statuses (delivered, pending, shipped, processing) |
| `order_items` | 104 | Order line items with product references |
| `employees` | 25 | Employee hierarchy across 4 departments with manager relationships |
| `analytics_events` | 50 | Time-series analytics data (page views, cart events, purchases) |

**Views:** `customer_order_summary`, `product_inventory`

**Data Highlights:**
- Customer tiers: Silver (9), Gold (8), Bronze (7), Platinum (6)
- Product price range: $9.99 - $1299.99
- Order date range: Feb 2024 - Apr 2024
- Total revenue: $32,505.82 across all orders
- Employee salary range: $65,000 - $125,000

---

### 📚 Example Queries

Connect from Dblore and try:

```sql
-- Customer order summary
SELECT * FROM customer_order_summary ORDER BY total_spent DESC;

-- Top selling products
SELECT p.name, SUM(oi.quantity) as units_sold, SUM(oi.subtotal) as revenue
FROM products p
JOIN order_items oi ON p.product_id = oi.product_id
GROUP BY p.product_id, p.name
ORDER BY revenue DESC LIMIT 10;

-- JSONB query - Gold tier customers
SELECT first_name, last_name, metadata->>'tier' as tier
FROM customers
WHERE metadata->>'tier' = 'gold';
```

---

### ⚙️ Configuration

Edit `.env` to customize database credentials or port:

```bash
POSTGRES_DB=dblore
POSTGRES_USER=dblore
POSTGRES_PASSWORD=dblore123
POSTGRES_PORT=5433
```

After changing, restart: `docker compose down && docker compose up -d`

---

### 🐛 Troubleshooting

**Port conflict:**
```bash
# Edit .env, change POSTGRES_PORT to different port (e.g., 5434)
# Then: docker compose down && docker compose up -d
```

**Can't connect:**
```bash
docker compose ps          # Check if running
docker compose logs -f     # View logs
# Try using 127.0.0.1 instead of localhost
```

**Init scripts not running:**
```bash
# Init scripts only run on fresh volume
docker compose down -v && docker compose up -d
```

---

## 🧪 Integration Test Database

Separate PostgreSQL instance for running integration tests in isolation.

### Test Database Setup

**Start Test Database:**
```bash
cd docker/postgresql
docker compose -f docker-compose.test.yml up -d
```

**Test Database Configuration:**
| Setting | Value |
|---------|-------|
| Host | localhost |
| Port | 5435 |
| Database | dblore_test |
| Username | dblore_test |
| Password | dblore123 |

Connection string: `postgresql://dblore_test:dblore123@localhost:5435/dblore_test`

> ⚠️ **Note:** Port 5435 is used to avoid conflicts with:
> - Development database (port 5433)
> - Local PostgreSQL instances (typically port 5432)

### Running Integration Tests

**Option 1: Command Line**

```bash
# Set environment variables for test database
export TEST_DB_HOST=localhost
export TEST_DB_PORT=5435
export TEST_DB_NAME=dblore_test
export TEST_DB_USER=dblore_test
export TEST_DB_PASSWORD=dblore123

# Run all tests, PostgreSQL suites included (opt-in, one test at a time)
TEST_RUNNER_POSTGRES_TESTS=1 xcodebuild test -scheme Dblore -destination 'platform=macOS' \
  -parallel-testing-enabled NO

# Run only integration tests
TEST_RUNNER_POSTGRES_TESTS=1 xcodebuild test -scheme Dblore -destination 'platform=macOS' \
  -parallel-testing-enabled NO -only-testing:DbloreTests/DatabaseIntegrationTests
```

**Option 2: Xcode (Recommended)**

1. **Start test database:**
   ```bash
   cd docker/postgresql
   docker compose -f docker-compose.test.yml up -d
   ```

2. **Configure Xcode scheme:**
   - In Xcode, select menu: **Product → Scheme → Edit Scheme...**
   - Select **Test** in the left sidebar
   - Click the **+** button under **Environment Variables**
   - Add the following environment variables:
     - Name: `TEST_DB_HOST`, Value: `localhost`
     - Name: `TEST_DB_PORT`, Value: `5435`
     - Name: `TEST_DB_NAME`, Value: `dblore_test`
     - Name: `TEST_DB_USER`, Value: `dblore_test`
     - Name: `TEST_DB_PASSWORD`, Value: `dblore123`
     - Name: `POSTGRES_TESTS`, Value: `1` (the PostgreSQL suites are opt-in)

3. **Run tests:**
   - Press **Cmd+U** to run all tests
   - Or use **Test Navigator** (Cmd+6) to run specific tests

**Default: no live database**

Without `TEST_RUNNER_POSTGRES_TESTS=1` (or `TEST_RUNNER_MYSQL_TESTS=1`), every suite that needs
a live database is skipped, so a plain `xcodebuild test` needs no container.

### Test Database vs Development Database

| Feature | Development DB | Test DB |
|---------|----------------|---------|
| **Port** | 5433 | 5435 |
| **Purpose** | Manual testing, development | Automated integration tests |
| **Sample Data** | ✅ Pre-loaded with schemas and data | ❌ Blank (tests create/drop tables) |
| **Initialization** | Runs `init/` scripts on first start | No initialization scripts |
| **Use Case** | Interactive testing in Dblore app | CI/CD, automated testing |
| **Data Persistence** | ✅ Persistent across restarts | ✅ Persistent (but tests clean up) |

### Managing Test Database

```bash
cd docker/postgresql

# Start test database
docker compose -f docker-compose.test.yml up -d

# View logs
docker compose -f docker-compose.test.yml logs -f

# Stop test database
docker compose -f docker-compose.test.yml down

# Check status
docker compose -f docker-compose.test.yml ps

# Connect to test database (for debugging)
PGPASSWORD=dblore123 psql -h localhost -p 5435 -U dblore_test -d dblore_test

# Reset test database (delete all data)
docker compose -f docker-compose.test.yml down -v
docker compose -f docker-compose.test.yml up -d
```

### Integration Test Details

The integration tests (`DbloreTests/DatabaseIntegrationTests.swift`) verify:

- ✅ **NUMERIC type decoding** - PostgreSQL NUMERIC columns correctly decode to Swift Double
- ✅ **NULL value handling** - NULL values decode to `CellValue.null`
- ✅ **Column type enrichment** - Column metadata includes precision, scale, length
- ✅ **Negative numbers** - Negative NUMERIC values decode correctly
- ✅ **Zero values** - Zero values decode accurately
- ✅ **Large numbers** - Very large NUMERIC values (up to 30 digits)
- ✅ **TIMESTAMP columns** - Time zone information preserved
- ✅ **Complex queries** - JOIN queries handle gracefully

Tests create temporary tables, run queries, then clean up automatically.

### Troubleshooting Test Database

**Tests failing with connection errors:**
```bash
# Verify test database is running
docker ps | grep dblore-postgres-test

# Check container is healthy (should show "healthy")
docker ps | grep dblore-postgres-test

# View logs for errors
docker compose -f docker-compose.test.yml logs postgres-test
```

**Port 5435 already in use:**
```bash
# Find what's using the port
lsof -i :5435

# Stop the conflicting service, or edit docker-compose.test.yml to use different port
```

**Tests timeout:**
- Ensure test database is healthy: `docker ps` should show `(healthy)` not `(health: starting)`
- Check network connectivity: `PGPASSWORD=dblore123 psql -h localhost -p 5435 -U dblore_test -d dblore_test -c "SELECT 1;"`

---

## MongoDB Test Databases

`docker/mongodb/docker-compose.test.yml` runs MongoDB 8.0 standalone servers for the opt-in
MongoDB suites. Ports are bound to `127.0.0.1` only.

| Service | Port | Gate (via xcodebuild) | Notes |
|---------|------|-----------------------|-------|
| `mongo-test` | 27018 | `TEST_RUNNER_MONGO_TESTS=1` | Plain connections |
| `mongo-tls-test` | 27019 | `TEST_RUNNER_MONGO_TLS_TESTS=1` | `requireTLS`, only with the `tls` profile |

```bash
# Plain server
docker compose -f docker/mongodb/docker-compose.test.yml up -d --wait

# TLS server: generate the certificates (gitignored, docker/mongodb/tls), then start the profile
docker/mongodb/scripts/gen-mongo-tls.sh
docker compose -f docker/mongodb/docker-compose.test.yml --profile tls up -d --wait
```

`gen-mongo-tls.sh` writes a test CA and a server certificate for `localhost` and `127.0.0.1`.
The TLS container copies them when it starts, so after generating new ones recreate it with
`--force-recreate mongo-tls-test`. A plain `up` never starts `mongo-tls-test`, so it never
needs the certificates.

`init/01-users.js` creates the test users in `admin` (connect with `authSource=admin`), all
with the test-only password `dblore123`:

| User | Roles | Login |
|------|-------|-------|
| `dblore_test` | `readWrite` on `dblore_test`, `clusterMonitor` | SCRAM-SHA-256 |
| `dblore_reader` | `read` on `dblore_test` | SCRAM-SHA-256 |
| `dblore_sha1` | `readWrite` on `dblore_test` | SCRAM-SHA-1 |

The root user is `root` / `dblore123`. The tests read `TEST_MONGO_HOST`, `TEST_MONGO_PORT`,
`TEST_MONGO_TLS_PORT`, `TEST_MONGO_DB`, `TEST_MONGO_USER` and `TEST_MONGO_PASSWORD` (defaults
`127.0.0.1`, 27018, 27019, `dblore_test`, `dblore_test`, `dblore123`); pass them to
`xcodebuild` as `TEST_RUNNER_<NAME>`. Remove everything with
`docker compose -f docker/mongodb/docker-compose.test.yml --profile tls down -v`.

---

## SSH Test Stack

`docker/postgresql/docker-compose.ssh.yml` runs an SSH server in front of databases that
publish no port, so they are reachable only through an SSH tunnel. It backs the opt-in SSH
suites (`TEST_RUNNER_SSH_TESTS=1`).

```bash
# Generate the keys and certificates once (gitignored, docker/postgresql/data/ssh)
docker/postgresql/scripts/gen-ssh-fixtures.sh

# No --project-directory: ./data must resolve next to the compose file
docker compose -f docker/postgresql/docker-compose.ssh.yml up -d --wait
```

| Service | Reach | Details |
|---------|-------|---------|
| `sshd` | `127.0.0.1:2222` | ed25519 host key; user `dblore`, password `dblore-ssh-123` or the generated keys |
| `sshd-rsa` | `127.0.0.1:2223` | Same, with an RSA-only host key |
| `postgres` | tunnel target `postgres:5432` | PostgreSQL 16, database and user `dblore_ssh`, password `dblore123`, TLS optional |
| `mysql-ssh` | tunnel target `mysql-ssh:3306` | MySQL 8.4, database and user `dblore_ssh`, password `dblore123`, TLS optional |
| `mongo-ssh` | tunnel target `mongo-ssh:27017` | MongoDB 8.0, user `root`, password `dblore123`, `authSource=admin`, TLS optional (`preferTLS`) |

The database certificates name their service (`postgres`, `mysql-ssh`, `mongo-ssh`); the
MySQL and MongoDB ones are issued by `data/ssh/ca.crt`. If certificates are missing or out of
date, delete `data/ssh/ca.*`, `data/ssh/mysql/` and `data/ssh/mongo/` together and run the
script again.

---

## CI Live Databases (`scripts/ci-live-databases.sh`)

The `integration` job of `.github/workflows/ci.yml` runs the PostgreSQL, MySQL/MariaDB and
MongoDB integration suites on the self-hosted `xcode-27` runner, which may be a Mac that also runs the
local test containers. The script starts a separate copy of the test databases next to them:

```bash
scripts/ci-live-databases.sh start postgres mysql mongo   # docker compose -p dblore-ci ... up -d --wait
scripts/ci-live-databases.sh stop postgres mysql mongo    # docker compose -p dblore-ci ... down -v
```

- Compose project `dblore-ci`; containers, volumes and networks are named `dblore-ci-*`
  (`dblore-ci-postgres-test`, `dblore-ci-mysql-test`, `dblore-ci-mariadb-test`,
  `dblore-ci-mongo-test`), so the local
  `dblore-*-test` containers and their data are never touched. `stop` removes the containers,
  networks and volumes.
- `mysql` starts both MySQL 8.4 and MariaDB 11.4 (one compose file); `mongo` starts only the
  plain MongoDB server (no `tls` profile).
- `start` fails with a clear message when Docker is not reachable or a CI port is taken.
- Each service is one `start_<name>` / `stop_<name>` pair in the script plus its name on the
  command line.

| Database | Local port | CI port | Override (compose and script) | Test env (via xcodebuild) |
|----------|------------|---------|-------------------------------|---------------------------|
| PostgreSQL 16 | 5435 | 15435 | `DBLORE_PG_TEST_PORT` | `TEST_RUNNER_TEST_DB_PORT` |
| MySQL 8.4 | 3307 | 13307 | `DBLORE_MYSQL_TEST_PORT` | `TEST_RUNNER_TEST_MYSQL_PORT` |
| MariaDB 11.4 | 3308 | 13308 | `DBLORE_MARIADB_TEST_PORT` | `TEST_RUNNER_TEST_MARIADB_PORT` |
| MongoDB 8.0 | 27018 | 13018 | `DBLORE_MONGO_TEST_PORT` | `TEST_RUNNER_TEST_MONGO_PORT` |

The test compose files read these overrides, plus `DBLORE_TEST_NAME_PREFIX` (default `dblore`)
for the container, volume and network names. Without them nothing changes for local use.

To reproduce the CI job locally (with or without the local containers running):

```bash
scripts/ci-live-databases.sh start postgres mysql mongo
TEST_RUNNER_MYSQL_TESTS=1 TEST_RUNNER_MONGO_TESTS=1 TEST_RUNNER_TEST_DB_PORT=15435 \
  TEST_RUNNER_TEST_MYSQL_PORT=13307 TEST_RUNNER_TEST_MARIADB_PORT=13308 \
  TEST_RUNNER_TEST_MONGO_PORT=13018 \
  xcodebuild test -project Dblore.xcodeproj -scheme Dblore -destination 'platform=macOS,arch=arm64' \
  -skipPackagePluginValidation -skipMacroValidation
scripts/ci-live-databases.sh stop postgres mysql mongo
```

The MySQL TLS, MongoDB TLS, mTLS, SSH and DuckDB plugin suites stay local-only.

---

## 🔮 Coming Soon

- **SQLite:** Portable database files with sample data

---

## 📝 Notes

- Development DB: Port 5433, pre-loaded with sample data
- Test DB: Port 5435, blank database for automated tests
- Data stored in Docker volumes (persists across restarts)
- Default credentials for **development only**
- Optimized for development, not production
