#!/bin/bash
# Reset PostgreSQL database with fresh schema and data

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR/.."

echo "⚠️  WARNING: This will DELETE ALL DATA in the database!"
echo "📁 Location: docker/postgresql/"
echo ""
read -p "Are you sure you want to continue? (yes/no): " -r
echo

if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "❌ Cancelled"
    exit 1
fi

echo "🛑 Stopping containers..."
docker compose down -v

echo "🚀 Starting fresh database..."
docker compose up -d

echo "⏳ Waiting for database to be ready..."
sleep 5

echo "✅ Database reset complete!"
echo ""
echo "📊 Connection info:"
echo "   Host: localhost"
echo "   Port: 5432"
echo "   Database: dblore"
echo "   User: dblore"
echo "   Password: dblore123"
echo ""
echo "🔍 Verify tables:"
docker compose exec postgres psql -U dblore -d dblore -c "\dt"
