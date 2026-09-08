#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
sudo -u postgres psql -d strom -f db/schema.sql
sudo -u postgres psql -d strom -f db/seed.sql
sudo -u postgres psql -d strom -c "GRANT USAGE ON SCHEMA public TO strom_app;"
sudo -u postgres psql -d strom -c "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO strom_app;"
sudo -u postgres psql -d strom -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO strom_app;"
