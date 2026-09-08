#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP_SQL="/tmp/strom_001_floorplan_v1.sql"

cp "$PROJECT_ROOT/db/migrations/001_floorplan_v1.sql" "$TMP_SQL"
chmod 644 "$TMP_SQL"

sudo -u postgres psql -d strom -f "$TMP_SQL"
sudo -u postgres psql -d strom -c "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO strom_app;"
sudo -u postgres psql -d strom -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO strom_app;"

rm -f "$TMP_SQL"
