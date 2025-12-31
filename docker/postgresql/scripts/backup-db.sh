#!/bin/bash
# Backup PostgreSQL database

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR/.."

BACKUP_DIR="backups"
mkdir -p "$BACKUP_DIR"

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_FILE="$BACKUP_DIR/sqlnotebook_backup_$TIMESTAMP.sql"

echo "💾 Creating backup..."
docker compose exec postgres pg_dump -U sqlnotebook sqlnotebook > "$BACKUP_FILE"

echo "✅ Backup created: $BACKUP_FILE"
echo "📊 Size: $(du -h "$BACKUP_FILE" | cut -f1)"
echo ""
echo "To restore:"
echo "  docker compose exec -T postgres psql -U sqlnotebook -d sqlnotebook < $BACKUP_FILE"
