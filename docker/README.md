# SQLNotebook Docker Databases

Docker configurations for local development and testing databases.

## 📁 Structure

```
docker/
├── README.md              # This file - complete guide
├── postgresql/            # PostgreSQL setup
│   ├── docker-compose.yml
│   ├── .env.example
│   ├── init/             # Schema and sample data (runs on first setup)
│   ├── scripts/          # Helper scripts
│   ├── migrations/       # Incremental schema changes
│   └── backups/          # Database backups (created by backup script)
├── mysql/                # Coming soon
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

**Connect from SQLNotebook:**
```
Host: localhost
Port: 5433
Database: sqlnotebook
User: sqlnotebook
Password: sqlnotebook123
```

Or connection string: `postgresql://sqlnotebook:sqlnotebook123@localhost:5433/sqlnotebook`

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
./scripts/restore-db.sh backups/sqlnotebook_backup_YYYY-MM-DD_HH-MM-SS.sql
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
docker compose exec -T postgres psql -U sqlnotebook -d sqlnotebook -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"

# 3. Restore from backup
docker compose exec -T postgres psql -U sqlnotebook -d sqlnotebook < backups/sqlnotebook_backup_YYYY-MM-DD_HH-MM-SS.sql
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

**Option 1: Use SQLNotebook App** (Easiest)
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

Connect from SQLNotebook and try:

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
POSTGRES_DB=sqlnotebook
POSTGRES_USER=sqlnotebook
POSTGRES_PASSWORD=sqlnotebook123
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

## 🔮 Coming Soon

- **MySQL:** Similar Docker setup
- **SQLite:** Portable database files with sample data

---

## 📝 Notes

- Data stored in Docker volumes (persists across restarts)
- Default credentials for **development only**
- Optimized for development, not production
