#!/bin/bash
# Open interactive psql shell

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR/.."

echo "🔧 Opening psql shell..."
echo "💡 Type \q to quit, \dt to list tables, \d table_name to describe table"
echo ""

docker compose exec postgres psql -U dblore -d dblore
