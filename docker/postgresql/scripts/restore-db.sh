#!/bin/bash
# Restore PostgreSQL database from backup

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR/.."

# Check if backup file is provided
if [ -z "$1" ]; then
    echo "❌ Error: No backup file specified"
    echo ""
    echo "Usage: ./scripts/restore-db.sh <backup_file>"
    echo ""
    echo "Available backups:"
    ls -1t backups/*.sql 2>/dev/null | head -5 || echo "  No backups found"
    exit 1
fi

BACKUP_FILE="$1"

# Check if backup file exists
if [ ! -f "$BACKUP_FILE" ]; then
    echo "❌ Error: Backup file not found: $BACKUP_FILE"
    exit 1
fi

echo "⚠️  WARNING: This will DELETE all existing data in the database!"
echo "📁 Backup file: $BACKUP_FILE"
echo "📊 Size: $(du -h "$BACKUP_FILE" | cut -f1)"
echo ""
read -p "Are you sure you want to continue? (yes/no): " -r
echo

if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "❌ Restore cancelled"
    exit 1
fi

echo "🗑️  Dropping existing schema..."
docker compose exec -T postgres psql -U dblore -d dblore -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" > /dev/null

echo "📥 Restoring from backup..."
docker compose exec -T postgres psql -U dblore -d dblore < "$BACKUP_FILE" > /dev/null 2>&1

echo "✅ Database restored successfully!"
echo ""
echo "📊 Verifying data..."
docker compose exec -T postgres psql -U dblore -d dblore -c "
SELECT
    'customers' as table_name, COUNT(*) as count FROM customers
UNION ALL SELECT 'products', COUNT(*) FROM products
UNION ALL SELECT 'orders', COUNT(*) FROM orders
UNION ALL SELECT 'order_items', COUNT(*) FROM order_items
UNION ALL SELECT 'employees', COUNT(*) FROM employees
UNION ALL SELECT 'analytics_events', COUNT(*) FROM analytics_events;
"
