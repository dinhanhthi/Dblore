#!/bin/bash
# Add data to existing PostgreSQL database without reset

set -e

if [ $# -eq 0 ]; then
    echo "Usage: $0 <sql-file>"
    echo ""
    echo "Example:"
    echo "  $0 my-data.sql"
    echo "  $0 migrations/001-add-reviews.sql"
    exit 1
fi

SQL_FILE="$1"

if [ ! -f "$SQL_FILE" ]; then
    echo "❌ Error: File '$SQL_FILE' not found"
    exit 1
fi

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR/.."

echo "📁 Executing SQL file: $SQL_FILE"
echo ""

docker compose exec -T postgres psql -U dblore -d dblore < "$SQL_FILE"

echo ""
echo "✅ SQL executed successfully!"
